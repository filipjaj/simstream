import Foundation

/// The scrcpy-server wire format SimStream speaks, matching scrcpy 5.x
/// (server/…/control/ControlMessageReader.java and device/Streamer.java). The server and the
/// client must come from the same scrcpy release; `ScrcpyServer` passes the installed version.
enum ScrcpyProtocol {
  /// Android MotionEvent actions. The server turns a second finger's DOWN/UP into POINTER_DOWN/UP.
  enum TouchAction: UInt8 {
    case down = 0, up = 1, move = 2
  }

  /// Android KeyEvent actions.
  enum KeyAction: UInt8 {
    case down = 0, up = 1
  }

  /// The server injects at most this many UTF-8 bytes per text message.
  static let maxInjectTextBytes = 300
  /// "h264" as a big-endian u32.
  static let codecH264: UInt32 = 0x6832_3634

  // MARK: Control messages (client → device)

  /// Type 2. `x`/`y` are video pixels and `width`/`height` the current video size: the server
  /// drops events whose size doesn't match the frame it last sent.
  static func touch(_ action: TouchAction, pointer: UInt64, x: Int32, y: Int32, width: UInt16, height: UInt16) -> Data {
    var data = Data([2, action.rawValue])
    data.appendBigEndian(pointer)
    data.appendBigEndian(UInt32(bitPattern: x))
    data.appendBigEndian(UInt32(bitPattern: y))
    data.appendBigEndian(width)
    data.appendBigEndian(height)
    // Pressure as u16 fixed point: 0xFFFF is 1.0, and lifting a finger reports 0.
    data.appendBigEndian(action == .up ? UInt16(0) : UInt16.max)
    data.appendBigEndian(UInt32(0)) // action button
    data.appendBigEndian(UInt32(0)) // buttons
    return data
  }

  /// Type 0.
  static func keycode(_ action: KeyAction, keycode: UInt32, metaState: UInt32 = 0) -> Data {
    var data = Data([0, action.rawValue])
    data.appendBigEndian(keycode)
    data.appendBigEndian(UInt32(0)) // repeat
    data.appendBigEndian(metaState)
    return data
  }

  /// Type 1. The server types each character through the device key map, so only characters
  /// that map have an effect; `textChunks` splits text at the server's limit.
  static func injectText(_ text: String) -> Data {
    let bytes = Data(text.utf8)
    var data = Data([1])
    data.appendBigEndian(UInt32(bytes.count))
    data.append(bytes)
    return data
  }

  /// Type 9. With `paste` the server also presses KEYCODE_PASTE (Android 7+). Sequence 0 asks for no acknowledgement.
  static func setClipboard(_ text: String, paste: Bool) -> Data {
    let bytes = Data(text.utf8)
    var data = Data([9])
    data.appendBigEndian(UInt64(0))
    data.append(paste ? 1 : 0)
    data.appendBigEndian(UInt32(bytes.count))
    data.append(bytes)
    return data
  }

  /// Type 17: the server restarts the encoder, so the next frame is a keyframe.
  static let resetVideo = Data([17])

  /// Splits text into pieces of at most `maxBytes` UTF-8 bytes without cutting a character.
  static func textChunks(_ text: String, maxBytes: Int = maxInjectTextBytes) -> [String] {
    var chunks: [String] = []
    var current = ""
    var currentBytes = 0
    for character in text {
      let size = character.utf8.count
      if currentBytes + size > maxBytes, !current.isEmpty {
        chunks.append(current)
        current = ""
        currentBytes = 0
      }
      current.append(character)
      currentBytes += size
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  // MARK: Video stream (device → client)

  /// The 12-byte header in front of every video packet.
  enum PacketHeader: Equatable {
    /// A new capture session (first frame, rotation): the video is now this size.
    case session(width: Int, height: Int)
    /// A media packet of `size` bytes follows. Config packets carry SPS/PPS.
    case media(size: Int, isConfig: Bool, isKeyframe: Bool, pts: UInt64)
  }

  static let headerSize = 12

  static func parseHeader(_ bytes: Data) -> PacketHeader? {
    guard bytes.count >= headerSize else { return nil }
    let start = bytes.startIndex
    let first = bytes.readBigEndian(UInt64.self, at: start)
    let size = Int(bytes.readBigEndian(UInt32.self, at: start + 8))
    if first & (1 << 63) != 0 {
      // Session packet: flags (u32), width (u32), height (u32).
      let width = Int(bytes.readBigEndian(UInt32.self, at: start + 4))
      return .session(width: width, height: size)
    }
    let isConfig = first & (1 << 62) != 0
    let isKeyframe = first & (1 << 61) != 0
    return .media(size: size, isConfig: isConfig, isKeyframe: isKeyframe, pts: first & ((1 << 61) - 1))
  }

  /// Splits an Annex B byte stream (00 00 01 / 00 00 00 01 start codes) into NAL units.
  static func nalUnits(_ data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var units: [Data] = []
    var unitStart: Int?
    var index = 0
    while index + 2 < bytes.count {
      if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
        if let start = unitStart {
          // A 4-byte start code leaves one trailing zero on the previous unit.
          var end = index
          while end > start, bytes[end - 1] == 0 { end -= 1 }
          units.append(Data(bytes[start..<end]))
        }
        index += 3
        unitStart = index
      } else {
        index += 1
      }
    }
    if let start = unitStart, start < bytes.count { units.append(Data(bytes[start...])) }
    return units
  }

  /// Replaces start codes with 4-byte big-endian lengths, the layout VideoToolbox decodes.
  static func avcc(_ units: [Data]) -> Data {
    var data = Data()
    for unit in units {
      data.appendBigEndian(UInt32(unit.count))
      data.append(unit)
    }
    return data
  }

  /// H.264 NAL unit type (low five bits of the first byte): 7 is SPS, 8 is PPS.
  static func nalType(_ unit: Data) -> UInt8 { (unit.first ?? 0) & 0x1F }
}

extension Data {
  mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }

  func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Index) -> T {
    var value: T = 0
    for byte in self[offset..<(offset + MemoryLayout<T>.size)] { value = value << 8 | T(byte) }
    return value
  }
}
