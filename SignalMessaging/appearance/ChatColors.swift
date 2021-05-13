//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// We want a color model that...
//
// * ...can be safely, losslessly serialized.
// * ...is Equatable.
public struct OWSColor: Equatable, Codable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red.clamp01()
        self.green = green.clamp01()
        self.blue = blue.clamp01()
    }

    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }

    var description: String {
        "[red: \(red), green: \(green), blue: \(blue)]"
    }
}

// MARK: -

public enum ChatColorAppearance: Equatable, Codable {
    case solidColor(color: OWSColor)
    case gradient(gradientColor1: OWSColor,
                  gradientColor2: OWSColor,
                  angleRadians: CGFloat)

    private enum TypeKey: UInt, Codable {
        case solidColor = 0
        case gradient = 1
    }

    private enum CodingKeys: String, CodingKey {
        case typeKey
        case solidColor
        case gradientColor1
        case gradientColor2
        case angleRadians
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let typeKey = try container.decode(TypeKey.self, forKey: .typeKey)
        switch typeKey {
        case .solidColor:
            let color = try container.decode(OWSColor.self, forKey: .solidColor)
            self = .solidColor(color: color)
        case .gradient:
            let gradientColor1 = try container.decode(OWSColor.self, forKey: .gradientColor1)
            let gradientColor2 = try container.decode(OWSColor.self, forKey: .gradientColor2)
            let angleRadians = try container.decode(CGFloat.self, forKey: .angleRadians)
            self = .gradient(gradientColor1: gradientColor1,
                             gradientColor2: gradientColor2,
                             angleRadians: angleRadians)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .solidColor(let solidColor):
            try container.encode(TypeKey.solidColor, forKey: .typeKey)
            try container.encode(solidColor, forKey: .solidColor)
        case .gradient(let gradientColor1, let gradientColor2, let angleRadians):
            try container.encode(TypeKey.gradient, forKey: .typeKey)
            try container.encode(gradientColor1, forKey: .gradientColor1)
            try container.encode(gradientColor2, forKey: .gradientColor2)
            try container.encode(angleRadians, forKey: .angleRadians)
        }
    }
}

// MARK: -

// TODO: We might end up renaming this to ChatColor
//       depending on how the design shakes out.
public struct ChatColorValue: Equatable, Codable {
    public let id: String
    public let appearance: ChatColorAppearance
    public let creationTimestamp: UInt64

    public init(id: String,
                appearance: ChatColorAppearance,
                creationTimestamp: UInt64 = NSDate.ows_millisecondTimeStamp()) {
        self.id = id
        self.appearance = appearance
        self.creationTimestamp = creationTimestamp
    }

    public static var randomId: String {
        UUID().uuidString
    }

    // MARK: - Equatable

    public static func == (lhs: ChatColorValue, rhs: ChatColorValue) -> Bool {
        // Ignore creationTimestamp.
        (lhs.id == rhs.id) && (lhs.appearance == rhs.appearance)
    }
}

// MARK: -

@objc
public class ChatColors: NSObject, Dependencies {
    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(warmCaches),
            name: .WarmCaches,
            object: nil
        )
    }

    // The cache should contain all current values at all times.
    @objc
    private func warmCaches() {
        var valueCache = [String: ChatColorValue]()

        // Load built-in colors.
        for value in Self.builtInValues {
            guard valueCache[value.id] == nil else {
                owsFailDebug("Duplicate value: \(value.id).")
                continue
            }
            valueCache[value.id] = value
        }

        // Load custom colors.
        Self.databaseStorage.read { transaction in
            let keys = Self.customColorsStore.allKeys(transaction: transaction)
            for key in keys {
                func loadValue() -> ChatColorValue? {
                    do {
                        return try Self.customColorsStore.getCodableValue(forKey: key, transaction: transaction)
                    } catch {
                        owsFailDebug("Error: \(error)")
                        return nil
                    }
                }
                guard let value = loadValue() else {
                    owsFailDebug("Missing value: \(key)")
                    continue
                }
                guard valueCache[value.id] == nil else {
                    owsFailDebug("Duplicate value: \(value.id).")
                    continue
                }
                valueCache[value.id] = value
            }
        }

        Self.unfairLock.withLock {
            self.valueCache = valueCache
        }
    }

    // Represents the current "chat color" setting for a given thread
    // or the default.  "Custom chat colors" have a lifecycle independent
    // from the conversations/global defaults which use them.
    //
    // The keys in this store are thread unique ids _OR_ defaultKey (String).
    // The values are ChatColorValue.id (String).
    private static let chatColorSettingStore = SDSKeyValueStore(collection: "chatColorSettingStore")

    // The keys in this store are ChatColorValue.id (String).
    // The values are ChatColorValues.
    private static let customColorsStore = SDSKeyValueStore(collection: "customColorsStore")

    private static let defaultKey = "defaultKey"

    private static let unfairLock = UnfairLock()
    private var valueCache = [String: ChatColorValue]()

    public func upsertCustomValue(_ value: ChatColorValue, transaction: SDSAnyWriteTransaction) {
        Self.unfairLock.withLock {
            self.valueCache[value.id] = value
            do {
                try Self.customColorsStore.setCodable(value, key: value.id, transaction: transaction)
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }
        fireCustomChatColorValueDidChange()
    }

    public func deleteCustomValue(_ value: ChatColorValue, transaction: SDSAnyWriteTransaction) {
        Self.unfairLock.withLock {
            self.valueCache.removeValue(forKey: value.id)
            Self.customColorsStore.removeValue(forKey: value.id, transaction: transaction)
        }
        fireCustomChatColorValueDidChange()
    }

    private func fireCustomChatColorValueDidChange() {
        NotificationCenter.default.postNotificationNameAsync(
            Self.customChatColorValueDidChange,
            object: nil,
            userInfo: nil
        )
    }

    private func value(forValueId valueId: String) -> ChatColorValue? {
        Self.unfairLock.withLock {
            self.valueCache[valueId]
        }
    }

    private var allValues: [ChatColorValue] {
        Self.unfairLock.withLock {
            Array(self.valueCache.values)
        }
    }

    public var allValuesSorted: [ChatColorValue] {
        allValues.sorted { (left, right) -> Bool in
            left.creationTimestamp < right.creationTimestamp
        }
    }
    public static var allValuesSorted: [ChatColorValue] { Self.chatColors.allValuesSorted }

    private static let noWallpaperAutoChatColor: ChatColorValue = {
        // UIColor.ows_accentBlue = 0x2C6BED
        let color = OWSColor(red: CGFloat(0x2C) / CGFloat(0xff),
                             green: CGFloat(0x6B) / CGFloat(0xff),
                             blue: CGFloat(0xED) / CGFloat(0xff))
        return ChatColorValue(id: "noWallpaperAuto", appearance: .solidColor(color: color))
    }()

    public static func autoChatColor(forThread thread: TSThread?,
                                     transaction: SDSAnyReadTransaction) -> ChatColorValue {
        if let wallpaper = Wallpaper.get(for: thread, transaction: transaction) {
            return autoChatColor(forWallpaper: wallpaper)
        } else {
            return Self.noWallpaperAutoChatColor
        }
    }

    public static func autoChatColor(forWallpaper wallpaper: Wallpaper) -> ChatColorValue {
        // TODO:
        let color = OWSColor(red: 1, green: 0, blue: 0)
        return ChatColorValue(id: wallpaper.rawValue, appearance: .solidColor(color: color))
    }

    // Returns nil for default/auto.
    public static func defaultChatColorSetting(transaction: SDSAnyReadTransaction) -> ChatColorValue? {
        chatColorSetting(key: defaultKey, transaction: transaction)
    }

    // TODO: When is this applied? Lazily?
    public static func defaultChatColorForRendering(transaction: SDSAnyReadTransaction) -> ChatColorValue {
        if let value = defaultChatColorSetting(transaction: transaction) {
            return value
        } else {
            return autoChatColor(forThread: nil, transaction: transaction)
        }
    }

    public static func setDefaultChatColorSetting(_ value: ChatColorValue?,
                                           transaction: SDSAnyWriteTransaction) {
        setChatColorSetting(key: defaultKey, value: value, transaction: transaction)
    }

    // Returns nil for default/auto.
    public static func chatColorSetting(thread: TSThread,
                                        transaction: SDSAnyReadTransaction) -> ChatColorValue? {
        chatColorSetting(key: thread.uniqueId, transaction: transaction)
    }

    public static func chatColorForRendering(thread: TSThread,
                                             transaction: SDSAnyReadTransaction) -> ChatColorValue {
        if let value = chatColorSetting(thread: thread, transaction: transaction) {
            return value
        } else {
            return autoChatColor(forThread: thread, transaction: transaction)
        }
    }

    public static func setChatColorSetting(_ value: ChatColorValue?,
                                           thread: TSThread,
                                           transaction: SDSAnyWriteTransaction) {
        setChatColorSetting(key: thread.uniqueId, value: value, transaction: transaction)
    }

    // Returns nil for default/auto.
    private static func chatColorSetting(key: String,
                                         transaction: SDSAnyReadTransaction) -> ChatColorValue? {
        guard let valueId = Self.chatColorSettingStore.getString(key, transaction: transaction) else {
            return nil
        }
        guard let value = Self.chatColors.value(forValueId: valueId) else {
            // This isn't necessarily an error.  A user might apply a custom
            // chat color value to a conversation (or the global default),
            // then delete the custom chat color value.  In that case, all
            // references to the value should behave as "auto" (the default).
            Logger.warn("Missing value: \(valueId).")
            return nil
        }
        return value
    }

    public static let defaultChatColorSettingDidChange = NSNotification.Name("defaultChatColorSettingDidChange")
    public static let chatColorSettingDidChange = NSNotification.Name("chatColorSettingDidChange")
    public static let chatColorSettingDidChangeThreadUniqueIdKey = "chatColorSettingDidChangeThreadUniqueIdKey"
    public static let customChatColorValueDidChange = NSNotification.Name("customChatColorValueDidChange")

    private static func setChatColorSetting(key: String,
                                            value: ChatColorValue?,
                                            transaction: SDSAnyWriteTransaction) {
        if let value = value {
            // Ensure the value is already in the cache.
            if nil == Self.chatColors.value(forValueId: value.id) {
                owsFailDebug("Unknown value: \(value.id).")
            }

            Self.chatColorSettingStore.setString(value.id, key: key, transaction: transaction)
        } else {
            Self.chatColorSettingStore.removeValue(forKey: key, transaction: transaction)
        }

        if key == defaultKey {
            NotificationCenter.default.postNotificationNameAsync(
                Self.defaultChatColorSettingDidChange,
                object: nil,
                userInfo: nil
            )
        } else {
            NotificationCenter.default.postNotificationNameAsync(
                Self.chatColorSettingDidChange,
                object: nil,
                userInfo: [
                    chatColorSettingDidChangeThreadUniqueIdKey: key
                ]
            )
        }
    }

    // MARK: -

    private static var builtInValues: [ChatColorValue] {
        // TODO:
        return [
            // We use fixed timestamps to ensure that built-in values
            // appear before custom values and to control their relative ordering.
            ChatColorValue(id: "a",
                           appearance: .solidColor(color: OWSColor(red: 0.5, green: 0.5, blue: 0.5)),
                           creationTimestamp: 1),
            ChatColorValue(id: "b",
                           appearance: .solidColor(color: OWSColor(red: 0, green: 0, blue: 1)),
                           creationTimestamp: 2),
            ChatColorValue(id: "c",
                           appearance: .solidColor(color: OWSColor(red: 0, green: 1, blue: 0)),
                           creationTimestamp: 3),
            ChatColorValue(id: "d",
                           appearance: .solidColor(color: OWSColor(red: 0, green: 1, blue: 0.5)),
                           creationTimestamp: 4),
            ChatColorValue(id: "e",
                           appearance: .gradient(gradientColor1: OWSColor(red: 0, green: 1, blue: 0),
                                                 gradientColor2: OWSColor(red: 0, green: 1, blue: 0.5),
                                                 angleRadians: CGFloat.pi * 0.25),
                           creationTimestamp: 5)
        ]
    }

//    public static func customValues(transaction: SDSAnyReadTransaction) -> [ChatColorValue] {
//        // TODO:
//        [
//            .solidColor(color: OWSColor(red: 0, green: 0, blue: 0))
//        ]
//    }
}
