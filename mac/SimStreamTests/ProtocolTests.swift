import Foundation
import Testing
@testable import SimStream

struct WebSocketFrameTests {
  /// A masked client text frame, as a browser sends it.
  private func clientFrame(_ text: String, mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]) -> [UInt8] {
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
      frame.append(0x80 | UInt8(payload.count))
    } else {
      frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    }
    frame += mask
    frame += payload.enumerated().map { $1 ^ mask[$0 & 3] }
    return frame
  }

  @Test func parsesMaskedTextFrame() throws {
    let bytes = clientFrame(#"{"type":"ack"}"#)
    let (frame, used) = try #require(try WebSocketFrame.parse(bytes[...]))
    #expect(frame.opcode == .text)
    #expect(frame.fin)
    #expect(String(decoding: frame.payload, as: UTF8.self) == #"{"type":"ack"}"#)
    #expect(used == bytes.count)
  }

  @Test func parsesExtendedLengthFrame() throws {
    let text = String(repeating: "a", count: 300)
    let bytes = clientFrame(text)
    let (frame, _) = try #require(try WebSocketFrame.parse(bytes[...]))
    #expect(frame.payload.count == 300)
  }

  @Test func waitsForIncompleteFrame() throws {
    let bytes = clientFrame("hello")
    for cut in 0..<bytes.count {
      #expect(try WebSocketFrame.parse(bytes[0..<cut]) == nil)
    }
  }

  @Test func parsesBackToBackFramesFromASlice() throws {
    let bytes = clientFrame("one") + clientFrame("two")
    let (first, used) = try #require(try WebSocketFrame.parse(bytes[...]))
    let (second, _) = try #require(try WebSocketFrame.parse(bytes[used...]))
    #expect(String(decoding: first.payload, as: UTF8.self) == "one")
    #expect(String(decoding: second.payload, as: UTF8.self) == "two")
  }

  @Test func rejectsOversizedFrame() {
    let bytes: [UInt8] = [0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0x10, 0, 0, 1, 2, 3, 4]
    #expect(throws: WebSocketFrame.ParseError.tooLarge) { try WebSocketFrame.parse(bytes[...]) }
  }

  @Test(arguments: [0, 125, 126, 65_535, 65_536, 200_000])
  func encodesServerFrameLengths(count: Int) throws {
    let frame = [UInt8](WebSocketFrame.encode(.binary, Data(count: count)))
    #expect(frame[0] == 0x82)
    let headerLength = count < 126 ? 2 : count <= 0xFFFF ? 4 : 10
    #expect(frame.count == headerLength + count)
    if count >= 126, count <= 0xFFFF { #expect(Int(frame[2]) << 8 | Int(frame[3]) == count) }
  }

  @Test func acceptKeyMatchesRFCExample() {
    #expect(WebSocketFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }
}

struct HTTPRequestTests {
  @Test func parsesUpgradeRequest() throws {
    let head = "GET /abc/ws?x=1 HTTP/1.1\r\nHost: example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k==\r\n\r\nrest"
    let (request, used) = try #require(HTTPRequest.parse(Array(head.utf8)))
    #expect(request.method == "GET")
    #expect(request.path == "/abc/ws")
    #expect(request.headers["sec-websocket-key"] == "k==")
    #expect(request.isWebSocketUpgrade)
    #expect(used == head.utf8.count - 4)
  }

  @Test func incompleteHeadReturnsNil() {
    #expect(HTTPRequest.parse(Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
  }
}

struct KeymapTests {
  @Test func mapsLettersDigitsAndShift() {
    #expect(Keymap.stroke(for: "a") == KeyStroke(code: 4, shift: false))
    #expect(Keymap.stroke(for: "Z") == KeyStroke(code: 29, shift: true))
    #expect(Keymap.stroke(for: "0") == KeyStroke(code: 39, shift: false))
    #expect(Keymap.stroke(for: "!") == KeyStroke(code: 30, shift: true))
    #expect(Keymap.stroke(for: "?") == KeyStroke(code: 56, shift: true))
    #expect(Keymap.stroke(for: " ") == KeyStroke(code: 44, shift: false))
  }

  @Test func routesNonUSCharactersToPaste() {
    #expect(Keymap.segments(for: "Hei på deg") == [
      .keys([KeyStroke(code: 11, shift: true), KeyStroke(code: 8, shift: false), KeyStroke(code: 12, shift: false), KeyStroke(code: 44, shift: false), KeyStroke(code: 19, shift: false)]),
      .paste("å"),
      .keys([KeyStroke(code: 44, shift: false), KeyStroke(code: 7, shift: false), KeyStroke(code: 8, shift: false), KeyStroke(code: 10, shift: false)]),
    ])
    #expect(Keymap.segments(for: "👍🏽") == [.paste("👍🏽")])
  }
}

struct SimulatorListTests {
  @Test func describesRuntimes() {
    #expect(SimulatorDevice.describeRuntime("com.apple.CoreSimulator.SimRuntime.iOS-27-0") == ("iOS 27.0", [27, 0]))
    #expect(SimulatorDevice.describeRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-11-2") == ("watchOS 11.2", [11, 2]))
  }

  @Test func parsesSimctlJSONAndDropsUnavailable() throws {
    let json = """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
      {"udid":"A","name":"iPhone Air","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Air"},
      {"udid":"B","name":"iPad Pro","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"},
      {"udid":"C","name":"Old","state":"Shutdown","isAvailable":false}
    ]}}
    """
    let devices = try SimulatorDevice.parseList(Data(json.utf8)).sorted { $0.udid < $1.udid }
    #expect(devices.map(\.udid) == ["A", "B"])
    #expect(devices[0].isBooted)
    #expect(devices[0].family == .iPhone)
    #expect(devices[1].family == .iPad)
    #expect(devices[1].runtime == "iOS 27.0")
  }
}

struct ClientMessageTests {
  private func decode(_ json: String) throws -> ClientMessage {
    try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
  }

  @Test func decodesViewerMessages() throws {
    #expect(try decode(#"{"type":"touch","phase":"move","x":0.25,"y":0.5}"#) == .input(.touch(.move, x: 0.25, y: 0.5)))
    #expect(try decode(#"{"type":"text","text":"hi"}"#) == .input(.text("hi")))
    #expect(try decode(#"{"type":"key","code":40}"#) == .input(.key(40)))
    #expect(try decode(#"{"type":"button","name":"home"}"#) == .input(.button(.home)))
    #expect(try decode(#"{"type":"hello","h264":true}"#) == .hello(h264: true))
    #expect(try decode(#"{"type":"hello"}"#) == .hello(h264: false))
    #expect(try decode(#"{"type":"ack"}"#) == .ack)
  }

  @Test func decodesMultiTouch() throws {
    #expect(try decode(#"{"type":"touches","phase":"down","points":[{"id":0,"x":0.3,"y":0.4}]}"#) == .input(.touch(.down, x: 0.3, y: 0.4)))
    // Sorted by finger id, so a stable first finger maps to finger1.
    #expect(try decode(#"{"type":"touches","phase":"move","points":[{"id":1,"x":0.6,"y":0.5},{"id":0,"x":0.4,"y":0.5}]}"#)
      == .input(.twoFingers(.move, CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5))))
    #expect(throws: DecodingError.self) { try decode(#"{"type":"touches","phase":"up","points":[]}"#) }
  }

  @Test func rejectsUnknownTypesAndButtons() {
    #expect(throws: DecodingError.self) { try decode(#"{"type":"rm -rf"}"#) }
    #expect(throws: DecodingError.self) { try decode(#"{"type":"button","name":"power"}"#) }
  }
}

struct H264ConfigTests {
  @Test func buildsAvcCRecordAndCodecString() throws {
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
    let pps: [UInt8] = [0x68, 0xEE, 0x3C]
    let config = try #require(H264Config.make(sps: sps, pps: pps, width: 630, height: 1368))
    #expect(config.codec == "avc1.64001f")
    #expect([UInt8](config.description) == [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0, 5] + sps + [1, 0, 3] + pps)
  }

  @Test func packetsCarryKindAndTimestamp() {
    let packet = [UInt8](VideoPacket.h264(H264Frame(data: Data([9, 9]), isKeyframe: true, timestamp: 0x0102)))
    #expect(packet == [3, 0, 0, 0, 0, 0, 0, 1, 2, 9, 9])
    #expect([UInt8](VideoPacket.jpeg(Data([0xFF]))) == [1, 0xFF])
  }
}
