import Foundation

// Wire format shared with the Mac app (mac/SimStream/Server/ViewerProtocol.swift and viewer.html).
// Text frames are JSON; binary frames are video packets.

enum TouchPhase: String, Codable, Sendable {
  case down, move, up
}

/// One finger of a multi-finger touch. `id` stays the same for a finger while it's down.
struct TouchPoint: Equatable, Sendable, Encodable {
  let id: Int
  let x: Double
  let y: Double

  init(id: Int, x: Double, y: Double) {
    self.id = id
    self.x = min(max(x, 0), 1)
    self.y = min(max(y, 0), 1)
  }
}

enum HardwareButton: String, Codable, Sendable {
  case home, lock, siri
}

/// Messages this app sends. Touch coordinates are normalised to 0–1 of the simulator screen.
enum ClientMessage: Equatable, Sendable {
  case hello(h264: Bool)
  case ack
  case keyframe
  /// Milliseconds on a local monotonic clock; echoed back as `pong`.
  case ping(Double)
  case touch(TouchPhase, x: Double, y: Double)
  /// Two or more fingers; only sent when the Mac's state says `multitouch`.
  case touches(TouchPhase, points: [TouchPoint])
  case text(String)
  /// USB HID usage code.
  case key(UInt32)
  case button(HardwareButton)
  case select(udid: String)
  /// Ask for control, or join the line if someone has it.
  case requestControl
  /// Give up control, or leave the line.
  case releaseControl
}

extension ClientMessage: Encodable {
  private enum CodingKeys: String, CodingKey {
    case type, phase, x, y, text, code, name, t, udid, h264, points
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let h264):
      try c.encode("hello", forKey: .type)
      try c.encode(h264, forKey: .h264)
    case .ack:
      try c.encode("ack", forKey: .type)
    case .keyframe:
      try c.encode("keyframe", forKey: .type)
    case .ping(let t):
      try c.encode("ping", forKey: .type)
      try c.encode(t, forKey: .t)
    case .touch(let phase, let x, let y):
      try c.encode("touch", forKey: .type)
      try c.encode(phase, forKey: .phase)
      try c.encode(min(max(x, 0), 1), forKey: .x)
      try c.encode(min(max(y, 0), 1), forKey: .y)
    case .touches(let phase, let points):
      try c.encode("touches", forKey: .type)
      try c.encode(phase, forKey: .phase)
      try c.encode(points, forKey: .points)
    case .text(let text):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
    case .key(let code):
      try c.encode("key", forKey: .type)
      try c.encode(code, forKey: .code)
    case .button(let name):
      try c.encode("button", forKey: .type)
      try c.encode(name, forKey: .name)
    case .select(let udid):
      try c.encode("select", forKey: .type)
      try c.encode(udid, forKey: .udid)
    case .requestControl:
      try c.encode("request", forKey: .type)
    case .releaseControl:
      try c.encode("release", forKey: .type)
    }
  }
}

/// Session state the Mac pushes whenever it changes.
struct ViewerState: Decodable, Equatable, Sendable {
  struct Device: Decodable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let symbol: String
    /// Screen size in points.
    let width: Double
    let height: Double
    let cornerRatio: Double
  }

  struct Choice: Decodable, Equatable, Sendable, Identifiable {
    let udid: String
    let name: String
    let runtime: String
    let symbol: String
    var id: String { udid }
  }

  let device: Device
  /// Milliseconds since 1970.
  let expiresAt: Double
  let viewers: Int
  let controlEnabled: Bool
  let choices: [Choice]
  /// The Mac accepts `touches`. Absent from Macs built before multi-touch.
  var multitouch: Bool? = nil

  var expiryDate: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

/// Decoder setup for the H.264 stream; arrives before the first keyframe and whenever the size changes.
struct CodecConfig: Decodable, Equatable, Sendable {
  let codec: String
  /// avcC record (AVCDecoderConfigurationRecord).
  let description: Data
  let width: Int
  let height: Int

  private enum CodingKeys: String, CodingKey { case codec, description, width, height }

  init(codec: String, description: Data, width: Int, height: Int) {
    self.codec = codec
    self.description = description
    self.width = width
    self.height = height
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    codec = try c.decode(String.self, forKey: .codec)
    let base64 = try c.decode(String.self, forKey: .description)
    guard let bytes = Data(base64Encoded: base64) else {
      throw DecodingError.dataCorruptedError(forKey: .description, in: c, debugDescription: "description is not base64")
    }
    description = bytes
    width = try c.decode(Int.self, forKey: .width)
    height = try c.decode(Int.self, forKey: .height)
  }
}

/// Who drives the simulator. One holder at a time; everyone else watches or waits in line.
struct ControlState: Decodable, Equatable, Sendable {
  struct Person: Decodable, Equatable, Sendable {
    let id: String
    let name: String
  }

  let holder: Person?
  let waiting: [Person]
  /// Milliseconds since 1970; set while someone waits.
  let turnEndsAt: Double?

  var turnEndDate: Date? { turnEndsAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The Mac's name for this viewer, sent once on connect so it can find itself in `ControlState`.
struct Welcome: Decodable, Equatable, Sendable {
  let id: String
  let name: String
}

enum ServerMessage: Equatable, Sendable {
  case state(ViewerState)
  case control(ControlState)
  case welcome(Welcome)
  case codec(CodecConfig)
  case pong(Double)
  case expired
  /// Input was refused because someone else holds control.
  case denied
  /// Newer Mac builds may add messages; ignore them rather than drop the connection.
  case unknown(String)
}

extension ServerMessage: Decodable {
  private enum CodingKeys: String, CodingKey { case type, t }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "state": self = .state(try ViewerState(from: decoder))
    case "codec": self = .codec(try CodecConfig(from: decoder))
    case "control": self = .control(try ControlState(from: decoder))
    case "welcome": self = .welcome(try Welcome(from: decoder))
    case "pong": self = .pong(try c.decode(Double.self, forKey: .t))
    case "expired": self = .expired
    case "denied": self = .denied
    case let other: self = .unknown(other)
    }
  }
}

/// Binary message: one kind byte; for H.264 an 8-byte big-endian timestamp (µs), then AVCC NAL units.
enum VideoPacket: Equatable, Sendable {
  case jpeg(Data)
  case h264(isKeyframe: Bool, timestamp: Int64, payload: Data)

  init?(_ data: Data) {
    guard let kind = data.first else { return nil }
    let body = data.dropFirst()
    switch kind {
    case 1:
      self = .jpeg(Data(body))
    case 2, 3:
      guard body.count > 8 else { return nil }
      let timestamp = body.prefix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
      self = .h264(isKeyframe: kind == 3, timestamp: timestamp, payload: Data(body.dropFirst(8)))
    default:
      return nil
    }
  }
}
