import Foundation

/// One key press on a US hardware keyboard, as a USB HID usage code.
struct KeyStroke: Equatable, Sendable {
  let code: UInt32
  let shift: Bool
}

/// Maps text to HID key strokes. Characters a US layout can't produce (æøå, emoji)
/// come back as paste segments, which go through the simulator pasteboard instead.
enum Keymap {
  enum Segment: Equatable, Sendable {
    case keys([KeyStroke])
    case paste(String)
  }

  static let shiftCode: UInt32 = 225
  static let commandCode: UInt32 = 227
  static let vCode: UInt32 = 25

  static func segments(for text: String) -> [Segment] {
    var result: [Segment] = []
    for character in text {
      if let stroke = stroke(for: character) {
        if case .keys(let existing) = result.last {
          result[result.count - 1] = .keys(existing + [stroke])
        } else {
          result.append(.keys([stroke]))
        }
      } else if case .paste(let existing) = result.last {
        result[result.count - 1] = .paste(existing + String(character))
      } else {
        result.append(.paste(String(character)))
      }
    }
    return result
  }

  static func stroke(for character: Character) -> KeyStroke? {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return nil }
    let value = scalar.value
    switch value {
    case 0x61...0x7A: return KeyStroke(code: 4 + value - 0x61, shift: false) // a–z
    case 0x41...0x5A: return KeyStroke(code: 4 + value - 0x41, shift: true) // A–Z
    case 0x31...0x39: return KeyStroke(code: 30 + value - 0x31, shift: false) // 1–9
    case 0x30: return KeyStroke(code: 39, shift: false) // 0
    default: return punctuation[character]
    }
  }

  private static let punctuation: [Character: KeyStroke] = {
    var map: [Character: KeyStroke] = [
      "\n": KeyStroke(code: 40, shift: false),
      "\t": KeyStroke(code: 43, shift: false),
      " ": KeyStroke(code: 44, shift: false),
    ]
    // Shifted digit row.
    for (index, character) in "!@#$%^&*()".enumerated() {
      map[character] = KeyStroke(code: 30 + UInt32(index), shift: true)
    }
    let pairs: [(UInt32, Character, Character)] = [
      (45, "-", "_"), (46, "=", "+"), (47, "[", "{"), (48, "]", "}"), (49, "\\", "|"),
      (51, ";", ":"), (52, "'", "\""), (53, "`", "~"), (54, ",", "<"), (55, ".", ">"), (56, "/", "?"),
    ]
    for (code, plain, shifted) in pairs {
      map[plain] = KeyStroke(code: code, shift: false)
      map[shifted] = KeyStroke(code: code, shift: true)
    }
    return map
  }()
}
