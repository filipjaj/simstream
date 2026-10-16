import CoreGraphics
import Foundation
import Testing
@testable import SimStream

/// Byte layouts are checked against scrcpy 5.0.1's ControlMessageReader.java and Streamer.java.
struct ScrcpyProtocolTests {
  @Test func encodesTouchLikeControlMessageReader() {
    let data = ScrcpyProtocol.touch(.down, pointer: 1, x: 100, y: 200, width: 1080, height: 2400)
    #expect(data.count == 32)
    #expect(Array(data) == [
      2, 0, // type, action
      0, 0, 0, 0, 0, 0, 0, 1, // pointer id
      0, 0, 0, 100, 0, 0, 0, 200, // x, y
      0x04, 0x38, 0x09, 0x60, // width 1080, height 2400
      0xFF, 0xFF, // pressure 1.0
      0, 0, 0, 0, 0, 0, 0, 0, // action button, buttons
    ])
    // A lifted finger has no pressure.
    #expect(Array(ScrcpyProtocol.touch(.up, pointer: 0, x: 0, y: 0, width: 1, height: 1)[22...23]) == [0, 0])
  }

  @Test func encodesKeycodeTextAndClipboard() {
    #expect(Array(ScrcpyProtocol.keycode(.up, keycode: 4)) == [0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(ScrcpyProtocol.injectText("hi")) == [1, 0, 0, 0, 2, 0x68, 0x69])
    #expect(Array(ScrcpyProtocol.setClipboard("ø", paste: true)) == [9, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0xC3, 0xB8])
  }

  @Test func splitsTextAtTheServerLimitWithoutCuttingCharacters() {
    let chunks = ScrcpyProtocol.textChunks(String(repeating: "a", count: 299) + "ø" + "b", maxBytes: 300)
    #expect(chunks.map(\.utf8.count) == [299, 3])
    #expect(chunks.joined() == String(repeating: "a", count: 299) + "øb")
  }

  @Test func parsesSessionAndMediaHeaders() {
    var session = Data([0x80, 0, 0, 0])
    session.appendBigEndian(UInt32(1080))
    session.appendBigEndian(UInt32(2400))
    #expect(ScrcpyProtocol.parseHeader(session) == .session(width: 1080, height: 2400))

    var config = Data()
    config.appendBigEndian(UInt64(1) << 62)
    config.appendBigEndian(UInt32(27))
    #expect(ScrcpyProtocol.parseHeader(config) == .media(size: 27, isConfig: true, isKeyframe: false, pts: 0))

    var key = Data()
    key.appendBigEndian(UInt64(1) << 61 | 123_456)
    key.appendBigEndian(UInt32(5000))
    #expect(ScrcpyProtocol.parseHeader(key) == .media(size: 5000, isConfig: false, isKeyframe: true, pts: 123_456))
    #expect(ScrcpyProtocol.parseHeader(Data([1, 2])) == nil)
  }

  @Test func splitsAnnexBIntoNALUnitsAndBuildsAVCC() {
    let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
    let units = ScrcpyProtocol.nalUnits(stream)
    #expect(units == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])])
    #expect(units.map(ScrcpyProtocol.nalType) == [7, 8, 5])
    #expect(Array(ScrcpyProtocol.avcc([Data([0x65, 4])])) == [0, 0, 0, 2, 0x65, 4])
  }
}

struct FingersTests {
  private func decode(_ data: Data) -> (action: UInt8, pointer: UInt64, x: Int32, y: Int32) {
    (data[1], data.readBigEndian(UInt64.self, at: 2),
     Int32(bitPattern: data.readBigEndian(UInt32.self, at: 10)), Int32(bitPattern: data.readBigEndian(UInt32.self, at: 14)))
  }

  @Test func singleFingerDragIsDownMoveUp() {
    let fingers = Fingers()
    let events: [InputEvent] = [.touch(.down, x: 0, y: 0), .touch(.move, x: 0.5, y: 0.5), .touch(.up, x: 1, y: 1)]
    let messages = events.flatMap { fingers.messages(for: $0, width: 101, height: 201) }.map(decode)
    #expect(messages.map(\.action) == [0, 2, 2, 1])
    #expect(messages.map(\.pointer) == [0, 0, 0, 0])
    #expect(messages.last.map { [$0.x, $0.y] } == [100, 200])
  }

  /// SimulatorKit-style repeated downs move the finger instead of pressing again.
  @Test func repeatedDownMovesTheFinger() {
    let fingers = Fingers()
    let messages = [InputEvent.touch(.down, x: 0.1, y: 0.1), .touch(.down, x: 0.2, y: 0.2)]
      .flatMap { fingers.messages(for: $0, width: 100, height: 100) }.map(decode)
    #expect(messages.map(\.action) == [0, 2])
  }

  @Test func pinchAddsAndLiftsTheSecondPointer() {
    let fingers = Fingers()
    let a = CGPoint(x: 0.4, y: 0.5), b = CGPoint(x: 0.6, y: 0.5), b2 = CGPoint(x: 0.8, y: 0.5)
    let events: [InputEvent] = [.touch(.down, x: 0.4, y: 0.5), .twoFingers(.down, a, b), .twoFingers(.move, a, b2), .twoFingers(.up, a, b2)]
    let messages = events.flatMap { fingers.messages(for: $0, width: 100, height: 100) }.map(decode)
    #expect(messages.map { "\($0.action)/\($0.pointer)" } == ["0/0", "0/1", "2/1", "1/1", "1/0"])
  }

  @Test func droppingToOneFingerLiftsTheSecond() {
    let fingers = Fingers()
    _ = fingers.messages(for: .twoFingers(.down, CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)), width: 100, height: 100)
    let messages = fingers.messages(for: .touch(.move, x: 0.45, y: 0.4), width: 100, height: 100).map(decode)
    #expect(messages.map { "\($0.action)/\($0.pointer)" } == ["1/1", "2/0"])
  }

  @Test func ignoresTouchesBeforeTheFirstFrame() {
    #expect(Fingers().messages(for: .touch(.down, x: 0.5, y: 0.5), width: 1, height: 1).isEmpty)
  }

  @Test func typesASCIIWithEnterKeys() {
    let messages = Fingers().messages(for: .text("hei\nsann"), width: 100, height: 100)
    #expect(messages == [ScrcpyProtocol.injectText("hei"), ScrcpyProtocol.keycode(.down, keycode: 66),
                         ScrcpyProtocol.keycode(.up, keycode: 66), ScrcpyProtocol.injectText("sann")])
  }

  /// Several pastes in a row race on the device clipboard, so mixed text goes as one paste.
  @Test func pastesMixedTextInOnePiece() {
    #expect(Fingers().messages(for: .text("wi-fi blåbær"), width: 100, height: 100) == [ScrcpyProtocol.setClipboard("wi-fi blåbær", paste: true)])
  }

  @Test func mapsButtonsAndKeys() {
    let fingers = Fingers()
    #expect(fingers.messages(for: .button(.back), width: 1, height: 1) == [
      ScrcpyProtocol.keycode(.down, keycode: 4), ScrcpyProtocol.keycode(.up, keycode: 4),
    ])
    #expect(fingers.messages(for: .button(.lock), width: 1, height: 1).first == ScrcpyProtocol.keycode(.down, keycode: 26))
    #expect(fingers.messages(for: .key(42), width: 1, height: 1).first == ScrcpyProtocol.keycode(.down, keycode: 67))
    #expect(fingers.messages(for: .key(999), width: 1, height: 1).isEmpty)
  }
}

struct AndroidDiscoveryTests {
  @Test func parsesADBDevices() {
    let output = """
    * daemon started successfully
    List of devices attached
    emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    R58M12ABCDE            unauthorized usb:1-1 transport_id:2
    192.168.1.20:5555      device product:husky model:Pixel_8_Pro device:husky transport_id:3

    """
    let devices = ADBDevice.parseList(output)
    #expect(devices.map(\.serial) == ["emulator-5554", "R58M12ABCDE", "192.168.1.20:5555"])
    #expect(devices.map(\.isOnline) == [true, false, true])
    #expect(devices[0].isEmulator && !devices[2].isEmulator)
    #expect(devices[2].model == "Pixel 8 Pro")
  }

  @Test func parsesProperties() {
    let props = AndroidProperties.parse("15\r\n35\r\nGoogle\r\nsdk_gphone64_arm64\r\nPixel_8\r\nemulator,default\r\n1\r\n")
    #expect(props == AndroidProperties(release: "15", sdk: 35, manufacturer: "Google", model: "sdk_gphone64_arm64",
                                       avdName: "Pixel_8", characteristics: "emulator,default", bootCompleted: true))
    #expect(AndroidProperties.parse("14\n34\nsamsung\nSM-X710\n\ntablet\n1\n").isTablet)
  }

  @Test func parsesAVDConfig() {
    let avd = AVD.parse(name: "Pixel_8_API_35", config: """
    avd.ini.displayname=Pixel 8 API 35
    hw.device.name=pixel_8
    image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/
    """)
    #expect(avd == AVD(name: "Pixel_8_API_35", displayName: "Pixel 8 API 35", apiLevel: 35, isTablet: false))
    #expect(AVD.parse(name: "Tab", config: "hw.device.name=pixel_tablet").isTablet)
    #expect(AVD.parse(name: "My_Phone", config: "").displayName == "My Phone")
  }

  @Test func runningEmulatorKeepsItsAVDIdentity() {
    let avd = AVD(name: "Pixel_8", displayName: "Pixel 8", apiLevel: 35, isTablet: false)
    let emulator = ADBDevice(serial: "emulator-5554", state: "device", model: nil)
    let phone = ADBDevice(serial: "R58M", state: "device", model: "SM G991B")
    var props = AndroidProperties(release: "15", avdName: "Pixel_8", bootCompleted: true)
    let devices = AndroidDiscovery.merge(avds: [avd], running: [(emulator, props), (phone, AndroidProperties(release: "14", manufacturer: "samsung", model: "SM-G991B", bootCompleted: true))])
      .sorted { $0.udid < $1.udid }
    #expect(devices.map(\.udid) == ["adb:R58M", "avd:Pixel_8"])
    #expect(devices[1].isBooted && devices[1].adbSerial == "emulator-5554" && !devices[1].isPhysical && devices[1].name == "Pixel 8")
    #expect(devices[0].isPhysical && !devices[0].canShutDown && devices[0].name == "samsung SM-G991B" && devices[0].runtime == "Android 14")

    props.bootCompleted = false
    let booting = AndroidDiscovery.merge(avds: [avd], running: [(emulator, props)])
    #expect(booting.first?.state == .booting)
    #expect(AndroidDiscovery.merge(avds: [avd], running: []).first?.state == .shutdown)
  }

  @Test func namesAndroidVersions() {
    #expect(AndroidVersion.release(forAPI: 35) == "15")
    #expect(AndroidVersion.release(forAPI: 32) == "12L")
    #expect(AndroidVersion.components("12L") == [12])
    #expect(AndroidVersion.components("8.1.0") == [8, 1, 0])
  }

  @Test func readsScrcpyVersion() {
    #expect(ScrcpyServerJar.version(fromCellarPath: "/opt/homebrew/Cellar/scrcpy/5.0.1_1/share/scrcpy/scrcpy-server") == "5.0.1")
    #expect(ScrcpyServerJar.version(fromCellarPath: "/usr/local/share/scrcpy/scrcpy-server") == nil)
    #expect(ScrcpyServerJar.version(fromVersionOutput: "scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>\n") == "5.0.1")
  }

  @Test func readsDisplaySizeAndDensityPreferringOverrides() {
    let display = AndroidLink.parseDisplay("Physical size: 1080x2400\nOverride size: 720x1600\nPhysical density: 420\n")
    #expect(display.width == 720 && display.density == 420)
  }

  @Test func extractsEmulatorBootFailure() {
    let log = """
    INFO         | Android emulator version 37.2.12.0
    FATAL        | Not enough space to create userdata partition. Available: 5957.85 MB, need 7372.80 MB.
    """
    #expect(ADB.bootFailure(fromLog: log) == "Not enough space to create userdata partition. Available: 5957.85 MB, need 7372.80 MB.")
  }

  @Test func parsesThirdPartyPackages() {
    let apps = InstalledApps.parsePackages("package:com.example.notes\r\npackage:no.ruter.reise_app\npackage:bad name\n")
    #expect(apps.map(\.bundleID) == ["com.example.notes", "no.ruter.reise_app"])
  }
}

struct AndroidEdgeGuardTests {
  @Test func blocksTheBackGestureFromEitherSide() {
    var edges = EdgeGuard(guardsSides: true)
    let swipe: [InputEvent] = [.touch(.down, x: 0.01, y: 0.5), .touch(.move, x: 0.3, y: 0.5), .touch(.up, x: 0.3, y: 0.5)]
    #expect(swipe.flatMap { edges.filter($0) }.isEmpty)
    #expect(edges.filter(.touch(.down, x: 0.99, y: 0.5)).isEmpty)
  }

  @Test func iOSLeavesSideEdgesAlone() {
    var edges = EdgeGuard()
    #expect(edges.filter(.touch(.down, x: 0.01, y: 0.5)) == [.touch(.down, x: 0.01, y: 0.5)])
  }
}

struct AndroidViewerProtocolTests {
  @Test func decodesAndroidButtons() throws {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"button","name":"recents"}"#.utf8))
    #expect(message == .input(.button(.recents)))
  }

  @Test func statesThePlatform() throws {
    let device = ViewerState.Device(udid: "avd:P", name: "P", runtime: "Android 15", symbol: "smartphone",
                                    width: 412, height: 915, cornerRatio: 0.09, platform: .android)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any] // Heterogeneous JSON object.
    #expect(json?["platform"] as? String == "android")
  }
}
