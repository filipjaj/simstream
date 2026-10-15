import CryptoKit
import Foundation

/// RFC 6455 framing. Browsers mask client frames; the server sends unmasked frames.
struct WebSocketFrame: Equatable {
  enum Opcode: UInt8 {
    case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
  }

  enum ParseError: Error, Equatable {
    case unknownOpcode(UInt8)
    case tooLarge
  }

  let fin: Bool
  let opcode: Opcode
  let payload: [UInt8]

  /// Viewer messages are small JSON; anything larger is a misbehaving client.
  static let maxClientPayload = 1 << 16

  /// Returns the first complete frame and how many bytes it used, or nil if more bytes are needed.
  static func parse(_ bytes: ArraySlice<UInt8>) throws -> (WebSocketFrame, Int)? {
    let start = bytes.startIndex
    guard bytes.count >= 2 else { return nil }
    let first = bytes[start], second = bytes[start + 1]
    guard let opcode = Opcode(rawValue: first & 0x0F) else { throw ParseError.unknownOpcode(first & 0x0F) }
    let masked = second & 0x80 != 0
    var length = Int(second & 0x7F)
    var offset = 2

    if length == 126 {
      guard bytes.count >= offset + 2 else { return nil }
      length = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
      offset += 2
    } else if length == 127 {
      guard bytes.count >= offset + 8 else { return nil }
      var value: UInt64 = 0
      for i in 0..<8 { value = value << 8 | UInt64(bytes[start + 2 + i]) }
      guard value <= UInt64(maxClientPayload) else { throw ParseError.tooLarge }
      length = Int(value)
      offset += 8
    }
    guard length <= maxClientPayload else { throw ParseError.tooLarge }

    var mask: [UInt8] = []
    if masked {
      guard bytes.count >= offset + 4 else { return nil }
      mask = Array(bytes[(start + offset)..<(start + offset + 4)])
      offset += 4
    }
    guard bytes.count >= offset + length else { return nil }

    var payload = Array(bytes[(start + offset)..<(start + offset + length)])
    if masked {
      for i in payload.indices { payload[i] ^= mask[i & 3] }
    }
    return (WebSocketFrame(fin: first & 0x80 != 0, opcode: opcode, payload: payload), offset + length)
  }

  /// Encodes a single unmasked, final frame.
  static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
    var header: [UInt8] = [0x80 | opcode.rawValue]
    let count = payload.count
    if count < 126 {
      header.append(UInt8(count))
    } else if count <= 0xFFFF {
      header.append(126)
      header.append(UInt8(count >> 8))
      header.append(UInt8(count & 0xFF))
    } else {
      header.append(127)
      for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
    }
    var frame = Data(header)
    frame.append(payload)
    return frame
  }

  /// The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`.
  static func acceptKey(for key: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    return Data(digest).base64EncodedString()
  }
}

/// A parsed HTTP/1.1 request head.
struct HTTPRequest: Equatable {
  let method: String
  let path: String
  /// Header names are lowercased.
  let headers: [String: String]

  /// Parses the bytes before the blank line. Returns nil if the head is incomplete.
  static func parse(_ bytes: [UInt8]) -> (HTTPRequest, Int)? {
    let terminator: [UInt8] = [13, 10, 13, 10]
    guard bytes.count >= 4,
          let end = (0...(bytes.count - 4)).first(where: { bytes[$0..<($0 + 4)].elementsEqual(terminator) }),
          let head = String(bytes: bytes[0..<end], encoding: .utf8) else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    return (HTTPRequest(method: String(requestLine[0]), path: path, headers: headers), end + 4)
  }

  var isWebSocketUpgrade: Bool {
    headers["upgrade"]?.lowercased() == "websocket" && headers["sec-websocket-key"] != nil
  }
}

/// Joins fragmented WebSocket messages. The size limit applies to the whole message, not just
/// each frame, so a viewer can't grow one message without bound through continuation frames.
struct MessageAssembler: Sendable {
  enum Failure: Error, Equatable { case tooLarge, unexpectedContinuation, interleaved }

  static let maxMessage = WebSocketFrame.maxClientPayload

  private var partial: [UInt8]?

  /// The complete message once its final frame arrives; nil while more fragments are due.
  mutating func add(_ frame: WebSocketFrame) throws -> [UInt8]? {
    switch frame.opcode {
    case .text, .binary:
      guard partial == nil else { throw Failure.interleaved }
      if frame.fin { return frame.payload }
      partial = frame.payload
      return nil
    case .continuation:
      guard var message = partial else { throw Failure.unexpectedContinuation }
      guard message.count + frame.payload.count <= Self.maxMessage else {
        partial = nil
        throw Failure.tooLarge
      }
      message += frame.payload
      if frame.fin {
        partial = nil
        return message
      }
      partial = message
      return nil
    case .close, .ping, .pong:
      return nil
    }
  }
}
