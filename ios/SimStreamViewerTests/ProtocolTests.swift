import CoreMedia
import Foundation
import Testing
@testable import SimStreamViewer

struct StreamLinkTests {
  @Test(arguments: [
    "https://quiet-river.trycloudflare.com/k3x9/",
    "https://quiet-river.trycloudflare.com/k3x9",
    "quiet-river.trycloudflare.com/k3x9",
    "  https://quiet-river.trycloudflare.com/k3x9/ \n",
    "https://quiet-river.trycloudflare.com/k3x9/ws",
    "https://quiet-river.trycloudflare.com/k3x9/?utm=1#x",
    "simstream://quiet-river.trycloudflare.com/k3x9/",
  ])
  func normalisesPastedLinks(raw: String) throws {
    let link = try #require(StreamLink(raw))
    #expect(link.pageURL.absoluteString == "https://quiet-river.trycloudflare.com/k3x9/")
    #expect(link.webSocketURL.absoluteString == "wss://quiet-river.trycloudflare.com/k3x9/ws")
  }

  @Test func localSimstreamLinkUsesPlainWebSocket() throws {
    let link = try #require(StreamLink("simstream://192.168.1.20:8080/k3x9/"))
    #expect(link.webSocketURL.absoluteString == "ws://192.168.1.20:8080/k3x9/ws")
  }

  @Test(arguments: ["", "https://quiet-river.trycloudflare.com/", "ftp://host/k3x9/", "not a link"])
  func rejectsLinksWithoutToken(raw: String) {
    #expect(StreamLink(raw) == nil)
  }
}

struct MessageTests {
  private func json(_ message: ClientMessage) throws -> [String: AnyHashable] {
    let data = try JSONEncoder().encode(message)
    // Heterogeneous JSON object; values are compared as plain Foundation types.
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
  }

  /// Field names must match what mac/SimStream/Server/ViewerProtocol.swift decodes.
  @Test func encodesMessagesTheMacDecodes() throws {
    #expect(try json(.hello(h264: true)) == ["type": "hello", "h264": true])
    #expect(try json(.ack) == ["type": "ack"])
    #expect(try json(.keyframe) == ["type": "keyframe"])
    #expect(try json(.touch(.move, x: 0.25, y: 0.5)) == ["type": "touch", "phase": "move", "x": 0.25, "y": 0.5])
    #expect(try json(.text("hi")) == ["type": "text", "text": "hi"])
    #expect(try json(.key(42)) == ["type": "key", "code": 42])
    #expect(try json(.button(.home)) == ["type": "button", "name": "home"])
    #expect(try json(.button(.back)) == ["type": "button", "name": "back"])
    #expect(try json(.button(.recents)) == ["type": "button", "name": "recents"])
    #expect(try json(.ping(12.5)) == ["type": "ping", "t": 12.5])
  }

  @Test func clampsTouchToScreen() throws {
    #expect(try json(.touch(.down, x: -0.2, y: 1.4)) == ["type": "touch", "phase": "down", "x": 0, "y": 1])
  }

  @Test func decodesStateFromMac() throws {
    let text = #"""
    {"type":"state","device":{"udid":"U","name":"iPhone 17 Pro","runtime":"iOS 26.1","symbol":"iphone",
    "width":402,"height":874,"cornerRatio":0.14},"expiresAt":1760536800000,"viewers":1,"controlEnabled":true,"choices":[]}
    """#
    guard case .state(let state) = try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) else {
      Issue.record("expected state")
      return
    }
    #expect(state.device.name == "iPhone 17 Pro")
    #expect(state.controlEnabled)
    #expect(state.expiryDate == Date(timeIntervalSince1970: 1_760_536_800))
  }

  @Test func decodesCodecDescriptionFromBase64() throws {
    let text = #"{"type":"codec","codec":"avc1.64001f","description":"AWQAH//hAAA=","width":1206,"height":2622}"#
    let message = try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    #expect(message == .codec(CodecConfig(codec: "avc1.64001f", description: Data([1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 0]),
                                          width: 1206, height: 2622)))
  }

  @Test func toleratesUnknownMessages() throws {
    let message = try JSONDecoder().decode(ServerMessage.self, from: Data(#"{"type":"future","x":1}"#.utf8))
    #expect(message == .unknown("future"))
  }
}

struct VideoPacketTests {
  @Test func parsesH264PacketWithBigEndianTimestamp() throws {
    var bytes: [UInt8] = [3]
    withUnsafeBytes(of: Int64(1_234_567_890_123).bigEndian) { bytes += $0 }
    bytes += [0, 0, 0, 2, 0x65, 0x88]
    // Slice with a non-zero start index, like a Data the socket hands over can be.
    let data = Data([9, 9] + bytes).dropFirst(2)
    #expect(VideoPacket(data) == .h264(isKeyframe: true, timestamp: 1_234_567_890_123, payload: Data([0, 0, 0, 2, 0x65, 0x88])))
  }

  @Test func parsesDeltaAndJPEG() {
    let delta = Data([2, 0, 0, 0, 0, 0, 0, 0, 7, 0xAA])
    #expect(VideoPacket(delta) == .h264(isKeyframe: false, timestamp: 7, payload: Data([0xAA])))
    #expect(VideoPacket(Data([1, 0xFF, 0xD8])) == .jpeg(Data([0xFF, 0xD8])))
  }

  @Test func rejectsTruncatedAndUnknownPackets() {
    #expect(VideoPacket(Data()) == nil)
    #expect(VideoPacket(Data([3, 0, 0, 0])) == nil)
    #expect(VideoPacket(Data([9, 1, 2])) == nil)
  }
}

struct H264SampleFactoryTests {
  /// SPS/PPS from a real 1206×2622 High-profile VideoToolbox stream, wrapped in an avcC record.
  private static let config: CodecConfig = {
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x2A, 0xAC, 0x2B, 0x40, 0x4B, 0x60, 0xA4, 0xD8, 0x08, 0x80, 0x00, 0x00, 0x03,
                        0x00, 0x80, 0x00, 0x00, 0x1E, 0x07, 0x8C, 0x19, 0x50]
    let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]
    var record: [UInt8] = [1, sps[1], sps[2], sps[3], 0xFF, 0xE1, 0, UInt8(sps.count)] + sps
    record += [1, 0, UInt8(pps.count)] + pps
    return CodecConfig(codec: "avc1.64002a", description: Data(record), width: 1206, height: 2622)
  }()

  @Test func buildsDisplayImmediatelySamples() throws {
    var factory = H264SampleFactory()
    try factory.configure(Self.config)
    let sample = try factory.sample(payload: Data([0, 0, 0, 2, 0x41, 0x9A]), timestamp: 500, isKeyframe: false)

    #expect(CMSampleBufferGetTotalSampleSize(sample) == 6)
    let dimensions = try #require(sample.formatDescription.map(CMVideoFormatDescriptionGetDimensions))
    #expect(dimensions.width == 1206 && dimensions.height == 2622)
    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
    #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    #expect(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true)
  }

  @Test func reportsFormatChangeOnlyWhenConfigDiffers() throws {
    var factory = H264SampleFactory()
    #expect(try factory.configure(Self.config) == false) // first config: nothing to flush
    #expect(try factory.configure(Self.config) == false)
    let rotated = CodecConfig(codec: Self.config.codec, description: Self.config.description, width: 2622, height: 1206)
    #expect(try factory.configure(rotated) == true)
  }

  @Test func refusesSamplesBeforeConfig() {
    #expect(throws: H264SampleFactory.Failure.notConfigured) {
      try H264SampleFactory().sample(payload: Data([0]), timestamp: 0, isKeyframe: true)
    }
  }
}

@MainActor
struct RecentLinksTests {
  private func store() -> RecentLinks {
    let name = "test-\(UUID().uuidString)"
    return RecentLinks(defaults: UserDefaults(suiteName: name)!)
  }

  @Test func prunesExpiredLinks() throws {
    let recents = store()
    let link = try #require(StreamLink("https://a.trycloudflare.com/t1/"))
    recents.opened(link)
    recents.update(link, with: .preview)
    recents.prune(now: Date.now.addingTimeInterval(3_600))
    #expect(recents.entries.isEmpty)
  }

  @Test func reopeningMovesLinkToTop() throws {
    let recents = store()
    let first = try #require(StreamLink("https://a.trycloudflare.com/t1/"))
    let second = try #require(StreamLink("https://b.trycloudflare.com/t2/"))
    recents.opened(first)
    recents.opened(second)
    recents.opened(first)
    #expect(recents.entries.map(\.link) == [first, second])
  }
}

struct ControlQueueTests {
  @Test func encodesQueueRequests() throws {
    let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.requestControl)) as? [String: String]
    let release = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.releaseControl)) as? [String: String]
    #expect(request == ["type": "request"])
    #expect(release == ["type": "release"])
  }

  @Test func decodesControlAndWelcome() throws {
    let control = #"{"type":"control","holder":{"id":"A","name":"Brave Otter"},"waiting":[{"id":"B","name":"Calm Heron"}],"turnEndsAt":1760536800000}"#
    let message = try JSONDecoder().decode(ServerMessage.self, from: Data(control.utf8))
    #expect(message == .control(ControlState(holder: .init(id: "A", name: "Brave Otter"), waiting: [.init(id: "B", name: "Calm Heron")],
                                             turnEndsAt: 1_760_536_800_000)))
    let free = #"{"type":"control","holder":null,"waiting":[]}"#
    #expect(try JSONDecoder().decode(ServerMessage.self, from: Data(free.utf8)) == .control(ControlState(holder: nil, waiting: [], turnEndsAt: nil)))
    let welcome = try JSONDecoder().decode(ServerMessage.self, from: Data(#"{"type":"welcome","id":"me","name":"iPhone"}"#.utf8))
    #expect(welcome == .welcome(Welcome(id: "me", name: "iPhone")))
  }
}

/// Preview sessions identify as viewer "me".
@MainActor
struct SessionRoleTests {
  private func session(holder: String?, waiting: [String] = []) -> StreamSession {
    let control = ControlState(holder: holder.map { .init(id: $0, name: $0) }, waiting: waiting.map { .init(id: $0, name: $0) }, turnEndsAt: nil)
    return StreamSession(preview: .live, state: .preview, control: control)
  }

  @Test func anyoneMayTouchWhenControlIsFree() {
    #expect(session(holder: nil).role == .open)
    #expect(session(holder: nil).canControl)
    #expect(StreamSession(preview: .live, state: .preview).canControl) // Mac without a control queue
  }

  @Test func onlyTheHolderMayTouch() {
    #expect(session(holder: "me").role == .driving)
    #expect(session(holder: "me").canControl)
    #expect(session(holder: "other").role == .watching(holder: "other"))
    #expect(!session(holder: "other").canControl)
    #expect(session(holder: "other", waiting: ["x", "me"]).role == .waiting(position: 2))
  }

  @Test func nothingIsControllableUntilLive() {
    #expect(!StreamSession(preview: .connecting, state: .preview).canControl)
  }
}

struct TouchTrackerTests {
  private let a = CGPoint(x: 0.2, y: 0.3), b = CGPoint(x: 0.6, y: 0.7), c = CGPoint(x: 0.5, y: 0.5)

  private func tracker(multitouch: Bool = true) -> TouchTracker<Int> {
    var tracker = TouchTracker<Int>()
    tracker.multitouch = multitouch
    return tracker
  }

  @Test func singleFingerIsPlainTouch() {
    var t = tracker()
    #expect(t.began([(1, a)]) == [.touch(.down, x: 0.2, y: 0.3)])
    #expect(t.moved([(1, b)]) == [.touch(.move, x: 0.6, y: 0.7)])
    #expect(t.ended([(1, b)]) == [.touch(.up, x: 0.6, y: 0.7)])
  }

  @Test func secondFingerLiftsFirstAndStartsPair() {
    var t = tracker()
    _ = t.began([(1, a)])
    #expect(t.began([(2, b)]) == [
      .touch(.up, x: 0.2, y: 0.3),
      .touches(.down, points: [TouchPoint(id: 0, x: 0.2, y: 0.3), TouchPoint(id: 1, x: 0.6, y: 0.7)]),
    ])
    #expect(t.moved([(2, c)]) == [.touches(.move, points: [TouchPoint(id: 0, x: 0.2, y: 0.3), TouchPoint(id: 1, x: 0.5, y: 0.5)])])
  }

  @Test func fingersLandingTogetherSkipTheTap() {
    var t = tracker()
    let messages = t.began([(1, a), (2, b)])
    #expect(messages.count == 1)
    guard case .touches(.down, let points) = messages.first else { Issue.record("expected pair down"); return }
    #expect(points.count == 2)
  }

  @Test func pairEndsWhenEitherFingerLiftsAndRemainderIsIgnored() {
    var t = tracker()
    _ = t.began([(1, a), (2, b)])
    let up = t.ended([(1, a)])
    guard case .touches(.up, _) = up.first else { Issue.record("expected pair up"); return }
    #expect(t.moved([(2, c)]).isEmpty)
    #expect(t.ended([(2, c)]).isEmpty)
    // Fresh gesture works again.
    #expect(t.began([(3, a)]) == [.touch(.down, x: 0.2, y: 0.3)])
  }

  @Test func withoutMultitouchSecondFingerIsIgnored() {
    var t = tracker(multitouch: false)
    _ = t.began([(1, a)])
    #expect(t.began([(2, b)]).isEmpty)
    #expect(t.moved([(2, c)]).isEmpty)
    #expect(t.ended([(1, a)]) == [.touch(.up, x: 0.2, y: 0.3)])
    // Leftover finger can't start a new touch until it lifts.
    #expect(t.began([(3, a)]).isEmpty)
    _ = t.ended([(2, c)])
    _ = t.ended([(3, a)])
    #expect(t.began([(4, a)]) == [.touch(.down, x: 0.2, y: 0.3)])
  }

  @Test func thirdFingerIsIgnored() {
    var t = tracker()
    _ = t.began([(1, a), (2, b)])
    #expect(t.began([(3, c)]).isEmpty)
    #expect(t.moved([(3, a)]).isEmpty)
  }

  @Test func encodesTouchesForTheMac() throws {
    let message = ClientMessage.touches(.move, points: [TouchPoint(id: 0, x: -1, y: 0.5), TouchPoint(id: 1, x: 0.25, y: 2)])
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    #expect(object["type"] as? String == "touches")
    #expect(object["phase"] as? String == "move")
    let points = try #require(object["points"] as? [[String: Double]])
    #expect(points == [["id": 0, "x": 0, "y": 0.5], ["id": 1, "x": 0.25, "y": 1]])
  }

  @Test func readsLockedApp() throws {
    let text = #"{"type":"state","device":{"udid":"U","name":"n","runtime":"r","symbol":"iphone","width":1,"height":2,"cornerRatio":0},"expiresAt":0,"viewers":1,"controlEnabled":true,"choices":[],"multitouch":true,"lockedApp":"Kupp"}"#
    guard case .state(let state) = try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) else { Issue.record("expected state"); return }
    #expect(state.lockedApp == "Kupp")
  }

  @Test func readsMultitouchCapability() throws {
    let text = #"{"type":"state","device":{"udid":"U","name":"n","runtime":"r","symbol":"iphone","width":1,"height":2,"cornerRatio":0},"expiresAt":0,"viewers":1,"controlEnabled":true,"choices":[],"multitouch":true}"#
    guard case .state(let state) = try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) else { Issue.record("expected state"); return }
    #expect(state.multitouch == true)
    #expect(state.lockedApp == nil)
    #expect(try JSONDecoder().decode(ServerMessage.self, from: Data(#"{"type":"denied"}"#.utf8)) == .denied)
  }
}

struct AndroidStateTests {
  @Test func decodesAndroidPlatform() throws {
    let text = #"{"type":"state","device":{"udid":"avd:P","name":"Pixel 8","runtime":"Android 15","symbol":"smartphone","width":412,"height":915,"cornerRatio":0.09,"platform":"android"},"expiresAt":0,"viewers":1,"controlEnabled":true,"choices":[]}"#
    let state = try JSONDecoder().decode(ViewerState.self, from: Data(text.utf8))
    #expect(state.device.isAndroid)
  }

  @Test func olderMacsDecodeAsIOS() throws {
    let text = #"{"type":"state","device":{"udid":"U","name":"n","runtime":"r","symbol":"iphone","width":1,"height":2,"cornerRatio":0},"expiresAt":0,"viewers":1,"controlEnabled":true,"choices":[]}"#
    #expect(try !JSONDecoder().decode(ViewerState.self, from: Data(text.utf8)).device.isAndroid)
  }
}
