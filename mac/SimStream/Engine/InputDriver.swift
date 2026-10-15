import CoreGraphics
import FBControlCore
import FBSimulatorControl
import Foundation

enum TouchPhase: String, Codable, Sendable {
  case down, move, up
}

enum HardwareButton: String, Codable, Sendable {
  case home, lock, siri
}

/// Viewer input. Touch coordinates are normalised to 0–1 of the screen.
enum InputEvent: Equatable, Sendable {
  case touch(TouchPhase, x: Double, y: Double)
  /// Two fingers at once (pinch, rotate, two-finger scroll).
  case twoFingers(TouchPhase, CGPoint, CGPoint)
  case text(String)
  case key(UInt32)
  case button(HardwareButton)
}

protocol InputDriver: Sendable {
  /// Human-readable transport name shown in the app ("Direct HID", "AXe CLI").
  var name: String { get }
  /// Queues an event. Events are delivered in order.
  func send(_ event: InputEvent)
  func close()
}

/// Sends events over one persistent SimulatorKit HID connection: ~1 ms per event.
final class HIDInputDriver: InputDriver {
  let name = "Direct HID"
  private let continuation: AsyncStream<InputEvent>.Continuation
  private let worker: Task<Void, Never>
  private let hid: FBSimulatorHID

  init(hid: FBSimulatorHID, udid: String, points: CGSize) {
    self.hid = hid
    let (stream, continuation) = AsyncStream.makeStream(of: InputEvent.self)
    self.continuation = continuation
    worker = Task.detached(priority: .userInitiated) {
      for await event in stream {
        await Self.perform(event, hid: hid, udid: udid, points: points)
      }
    }
  }

  func send(_ event: InputEvent) { continuation.yield(event) }

  func close() {
    continuation.finish()
    worker.cancel()
    hid.disconnect()
  }

  private static func perform(_ event: InputEvent, hid: FBSimulatorHID, udid: String, points: CGSize) async {
    do {
      switch event {
      case .touch(let phase, let x, let y):
        let px = clamp(x) * points.width
        let py = clamp(y) * points.height
        // SimulatorKit has no separate "moved" event: a down at a new point moves the finger.
        try await FBSimulatorHIDEvent.touch(direction: phase == .up ? .up : .down, x: px, y: py).sendAsync(on: hid)
      case .twoFingers(let phase, let a, let b):
        let scale = { (p: CGPoint) in CGPoint(x: clamp(p.x) * points.width, y: clamp(p.y) * points.height) }
        try await FBSimulatorHIDEvent.twoFingerTouch(direction: phase == .up ? .up : .down, finger1: scale(a), finger2: scale(b)).sendAsync(on: hid)
      case .key(let code):
        try await FBSimulatorHIDEvent.shortKeyPress(code).sendAsync(on: hid)
      case .button(let button):
        try await FBSimulatorHIDEvent.shortButtonPress(button.hidButton).sendAsync(on: hid)
      case .text(let text):
        for segment in Keymap.segments(for: text) {
          switch segment {
          case .keys(let strokes):
            for stroke in strokes { try await press(stroke, hid: hid) }
          case .paste(let chunk):
            try await paste(chunk, hid: hid, udid: udid)
          }
        }
      }
    } catch {
      NSLog("SimStream: HID event failed: \(error)")
    }
  }

  private static func press(_ stroke: KeyStroke, hid: FBSimulatorHID) async throws {
    if stroke.shift { try await FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: Keymap.shiftCode).sendAsync(on: hid) }
    try await FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: stroke.code).sendAsync(on: hid)
    try await FBSimulatorHIDEvent.keyboard(direction: .up, keyCode: stroke.code).sendAsync(on: hid)
    if stroke.shift { try await FBSimulatorHIDEvent.keyboard(direction: .up, keyCode: Keymap.shiftCode).sendAsync(on: hid) }
  }

  /// Text a US key layout can't produce goes through the pasteboard and ⌘V.
  private static func paste(_ text: String, hid: FBSimulatorHID, udid: String) async throws {
    _ = try await ProcessRunner.run(Tools.xcrun, ["simctl", "pbcopy", udid], input: Data(text.utf8))
    try await FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: Keymap.commandCode).sendAsync(on: hid)
    try await FBSimulatorHIDEvent.shortKeyPress(Keymap.vCode).sendAsync(on: hid)
    try await FBSimulatorHIDEvent.keyboard(direction: .up, keyCode: Keymap.commandCode).sendAsync(on: hid)
  }
}

/// Fallback when the direct HID connection is unavailable (for example after an AXe or
/// Xcode update changes SimulatorKit). Each event spawns `axe`, so it costs ~0.5 s.
final class AXeCLIInputDriver: InputDriver {
  let name = "AXe CLI (slow)"
  private let continuation: AsyncStream<InputEvent>.Continuation
  private let worker: Task<Void, Never>

  init?(udid: String, points: CGSize) {
    guard let axe = Tools.path(of: "axe") else { return nil }
    let (stream, continuation) = AsyncStream.makeStream(of: InputEvent.self)
    self.continuation = continuation
    worker = Task.detached(priority: .userInitiated) {
      var touchStart: (x: Double, y: Double, at: Date)?
      for await event in stream {
        let pt = { (v: Double, max: CGFloat) in String(format: "%.1f", clamp(v) * max) }
        var args: [String]?
        switch event {
        case .touch(.down, let x, let y):
          touchStart = (x, y, Date())
        case .touch(.move, _, _), .twoFingers:
          break // The CLI fallback has no live drags or multi-touch.
        case .touch(.up, let x, let y):
          guard let start = touchStart else { break }
          touchStart = nil
          if hypot(x - start.x, y - start.y) < 0.01 {
            args = ["tap", "-x", pt(x, points.width), "-y", pt(y, points.height)]
          } else {
            let duration = min(max(Date().timeIntervalSince(start.at), 0.1), 2)
            args = ["swipe", "--start-x", pt(start.x, points.width), "--start-y", pt(start.y, points.height),
                    "--end-x", pt(x, points.width), "--end-y", pt(y, points.height),
                    "--duration", String(format: "%.2f", duration)]
          }
        case .text(let text): args = ["type", text]
        case .key(let code): args = ["key", String(code)]
        case .button(let button): args = ["button", button.rawValue]
        }
        if let args { _ = try? await ProcessRunner.run(axe, args + ["--udid", udid]) }
      }
    }
  }

  func send(_ event: InputEvent) { continuation.yield(event) }

  func close() {
    continuation.finish()
    worker.cancel()
  }
}

private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

private extension HardwareButton {
  var hidButton: FBSimulatorHIDButton {
    switch self {
    case .home: .homeButton
    case .lock: .lock
    case .siri: .siri
    }
  }
}
