import AppKit
import Carbon

/// A key press that confirms a capture, with or without modifiers.
///
/// Unlike `NativeShortcut` (a system-wide hotkey, which must carry a real
/// modifier so it cannot swallow ordinary typing), an action key is read only
/// while the capture overlay owns the keyboard, so plain `Return` and `Space`
/// are both legal and are the defaults.
public struct ActionKey: Codable, Hashable {
    public let keyCode: Int
    public let modifiers: Int

    public static let imageDefault = ActionKey(keyCode: 36, modifiers: 0) // Return
    public static let textDefault = ActionKey(keyCode: 49, modifiers: 0)  // Space

    /// Key codes that only exist to modify other keys.
    private static let modifierKeyCodes: Set<Int> = [55, 56, 57, 58, 59, 60, 61, 62, 63]

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        var carbon = 0
        if modifierFlags.contains(.command) { carbon |= 256 }
        if modifierFlags.contains(.shift) { carbon |= 512 }
        if modifierFlags.contains(.option) { carbon |= 2048 }
        if modifierFlags.contains(.control) { carbon |= 4096 }
        self.keyCode = keyCode
        self.modifiers = carbon
    }

    public func validate() throws {
        guard (0...127).contains(keyCode), modifiers >= 0, modifiers & ~6912 == 0,
              !Self.modifierKeyCodes.contains(keyCode) else {
            throw ActionKeyError.invalidKey
        }
    }

    public func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        var bits = 0
        if flags.contains(.command) { bits |= 256 }
        if flags.contains(.shift) { bits |= 512 }
        if flags.contains(.option) { bits |= 2048 }
        if flags.contains(.control) { bits |= 4096 }
        guard bits == modifiers else { return false }
        let pressed = Int(event.keyCode)
        if pressed == keyCode { return true }
        // Return and keypad Enter are the same physical intention.
        return (keyCode == 36 && pressed == 76) || (keyCode == 76 && pressed == 36)
    }

    public var displayString: String {
        var parts = ""
        if modifiers & 4096 != 0 { parts += "⌃" }
        if modifiers & 2048 != 0 { parts += "⌥" }
        if modifiers & 512 != 0 { parts += "⇧" }
        if modifiers & 256 != 0 { parts += "⌘" }
        let names: [Int: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 76: "⌤"
        ]
        if let name = names[keyCode] { return parts + name }
        if let scalar = UnicodeScalar(keyCodeToCharacter(keyCode)) {
            return parts + String(scalar).uppercased()
        }
        return parts + "键\(keyCode)"
    }

    private func keyCodeToCharacter(_ code: Int) -> Int {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return 0
        }
        let data = unsafeBitCast(property, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKey: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return 0 }
        return Int(characters[0])
    }
}

public enum ActionKeyError: LocalizedError {
    case invalidKey

    public var errorDescription: String? {
        "请按下任意普通按键（可加修饰键），不要只用 Command / Option / Control / Shift 本身。"
    }
}
