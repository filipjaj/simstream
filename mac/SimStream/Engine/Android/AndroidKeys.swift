import Foundation

/// Maps SimStream's input vocabulary (USB HID usages, hardware buttons, text) to Android key events.
enum AndroidKeys {
  static let enter: UInt32 = 66
  static let home: UInt32 = 3
  static let back: UInt32 = 4
  static let power: UInt32 = 26
  static let appSwitch: UInt32 = 187
  static let assist: UInt32 = 219

  /// How `text` reaches the device.
  enum Segment: Equatable, Sendable {
    /// ASCII the device key map can type.
    case type(String)
    case enter
    /// Everything else (æøå, emoji) goes through the clipboard and KEYCODE_PASTE.
    case paste(String)
  }

  static func keycode(for button: HardwareButton) -> UInt32 {
    switch button {
    case .home: home
    case .lock: power
    case .siri: assist
    case .back: back
    case .recents: appSwitch
    }
  }

  /// USB HID usage (what viewers send for special keys) → Android KEYCODE_*.
  static func keycode(forHIDUsage usage: UInt32) -> UInt32? {
    switch usage {
    case 4...29: 29 + (usage - 4) // a–z
    case 30...38: 8 + (usage - 30) // 1–9
    case 39: 7 // 0
    case 40: enter
    case 41: 111 // Escape
    case 42: 67 // Backspace (KEYCODE_DEL)
    case 43: 61 // Tab
    case 44: 62 // Space
    case 74: 122 // Home (move to line start)
    case 75: 92 // Page Up
    case 76: 112 // Delete forward
    case 77: 123 // End
    case 78: 93 // Page Down
    case 79: 22 // Right
    case 80: 21 // Left
    case 81: 20 // Down
    case 82: 19 // Up
    default: nil
    }
  }

  /// Text the device key map can't type is pasted, and then the whole event goes as one paste:
  /// back-to-back pastes race (the second clipboard write can land before the app handles the
  /// first PASTE key), and typing around a paste could reorder against it.
  static func segments(for text: String) -> [Segment] {
    let typeable = text.allSatisfy { $0 == "\n" || $0 == "\r\n" || isTypeable($0) }
    guard typeable else { return [.paste(text)] }
    var result: [Segment] = []
    for character in text {
      if character == "\n" || character == "\r\n" {
        result.append(.enter)
      } else if case .type(let existing)? = result.last {
        result[result.count - 1] = .type(existing + String(character))
      } else {
        result.append(.type(String(character)))
      }
    }
    return result
  }

  private static func isTypeable(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
    return scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7F
  }
}
