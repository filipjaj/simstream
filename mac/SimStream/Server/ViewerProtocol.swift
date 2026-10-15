import CoreGraphics
import Foundation

/// Messages a browser sends over the WebSocket, as JSON text frames.
enum ClientMessage: Equatable, Sendable {
  case input(InputEvent)
  /// Echoed back as `pong` so the viewer can show round-trip latency.
  case ping(Double)
  /// The viewer finished drawing a frame; frees a flow-control slot.
  case ack
  case select(udid: String)
  /// Sent once on connect: whether the browser can decode H.264 with WebCodecs.
  case hello(h264: Bool)
  /// The viewer's decoder lost sync and needs a fresh keyframe.
  case keyframe
  /// Ask for control, or join the line if someone has it.
  case requestControl
  /// Give up control, or leave the line.
  case releaseControl
}

extension ClientMessage: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type, phase, x, y, text, code, name, t, udid, h264, points
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "touch":
      self = .input(.touch(try c.decode(TouchPhase.self, forKey: .phase), x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y)))
    case "touches":
      // Multi-touch form: 1 point is a plain touch, 2+ points use the first two fingers.
      struct Point: Decodable { let id: Int; let x: Double; let y: Double }
      let phase = try c.decode(TouchPhase.self, forKey: .phase)
      let points = try c.decode([Point].self, forKey: .points).sorted { $0.id < $1.id }
      guard let first = points.first else {
        throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "touches needs at least one point")
      }
      if points.count == 1 {
        self = .input(.touch(phase, x: first.x, y: first.y))
      } else {
        self = .input(.twoFingers(phase, CGPoint(x: first.x, y: first.y), CGPoint(x: points[1].x, y: points[1].y)))
      }
    case "text":
      self = .input(.text(try c.decode(String.self, forKey: .text)))
    case "key":
      self = .input(.key(try c.decode(UInt32.self, forKey: .code)))
    case "button":
      self = .input(.button(try c.decode(HardwareButton.self, forKey: .name)))
    case "ping":
      self = .ping(try c.decode(Double.self, forKey: .t))
    case "ack":
      self = .ack
    case "hello":
      self = .hello(h264: try c.decodeIfPresent(Bool.self, forKey: .h264) ?? false)
    case "keyframe":
      self = .keyframe
    case "request":
      self = .requestControl
    case "release":
      self = .releaseControl
    case "select":
      self = .select(udid: try c.decode(String.self, forKey: .udid))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown message type \(other)")
    }
  }
}

/// Session state pushed to every viewer whenever it changes.
struct ViewerState: Encodable, Equatable, Sendable {
  struct Device: Encodable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let symbol: String
    /// Screen size in points.
    let width: Double
    let height: Double
    let cornerRatio: Double
  }

  struct Choice: Encodable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let symbol: String
  }

  let type = "state"
  let device: Device
  /// Milliseconds since 1970.
  let expiresAt: Double
  let viewers: Int
  let controlEnabled: Bool
  /// Booted simulators the viewer may switch to; empty unless the host allows it.
  let choices: [Choice]
  /// The server accepts two-finger `touches` messages.
  let multitouch = true
}

/// Who controls the simulator, broadcast to every viewer whenever it changes.
struct ControlState: Encodable, Equatable, Sendable {
  struct Person: Encodable, Equatable, Sendable {
    let id: String
    let name: String
  }

  let type = "control"
  let holder: Person?
  let waiting: [Person]
  /// Milliseconds since 1970; set while someone waits.
  let turnEndsAt: Double?
}

/// Sent to one viewer on connect so it can recognise itself in `ControlState`.
struct Welcome: Encodable, Sendable {
  let type = "welcome"
  let id: String
  let name: String
}

/// Binary message layout: one kind byte, then for H.264 an 8-byte big-endian timestamp (µs), then the payload.
enum VideoPacket {
  static let kindJPEG: UInt8 = 1
  static let kindDelta: UInt8 = 2
  static let kindKey: UInt8 = 3

  static func jpeg(_ data: Data) -> Data {
    var packet = Data([kindJPEG])
    packet.append(data)
    return packet
  }

  static func h264(_ frame: H264Frame) -> Data {
    var packet = Data([frame.isKeyframe ? kindKey : kindDelta])
    withUnsafeBytes(of: frame.timestamp.bigEndian) { packet.append(contentsOf: $0) }
    packet.append(frame.data)
    return packet
  }

  static func codecMessage(_ config: H264Config) -> Data {
    struct Message: Encodable {
      let type = "codec"
      let codec: String
      let description: String
      let width: Int
      let height: Int
    }
    let message = Message(codec: config.codec, description: config.description.base64EncodedString(), width: config.width, height: config.height)
    return (try? JSONEncoder().encode(message)) ?? Data()
  }
}
