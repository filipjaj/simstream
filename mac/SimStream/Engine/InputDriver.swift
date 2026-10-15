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
  /// Longest `text` event accepted; typing costs a few HID events per character.
  static let maxTextLength = 2_000

  case touch(TouchPhase, x: Double, y: Double)
  /// Two fingers at once (pinch, rotate, two-finger scroll).
  case twoFingers(TouchPhase, CGPoint, CGPoint)
  case text(String)
  case key(UInt32)
  case button(HardwareButton)

  /// A finger leaving the screen.
  var isLift: Bool {
    switch self {
    case .touch(.up, _, _), .twoFingers(.up, _, _): true
    default: false
    }
  }
}

protocol InputDriver: Sendable {
  /// Human-readable transport name shown in the app ("Direct HID", "AXe CLI").
  var name: String { get }
  /// Queues an event. Events are delivered in order.
  func send(_ event: InputEvent)
  /// Drops everything queued so far, including the rest of a long text. Called when control
  /// changes hands or is turned off, so one viewer's backlog can't outlive their turn.
  func discardPending()
  func close()
}

/// A bounded, in-order event queue whose backlog can be discarded. Events beyond `capacity`
/// are dropped: a controller sending faster than the simulator takes input only loses their own input.
final class InputQueue: Sendable {
  /// Tells a running event whether it still belongs to the current generation.
  typealias IsCurrent = @Sendable () -> Bool

  static let capacity = 512

  private let continuation: AsyncStream<(InputEvent, UInt64)>.Continuation
  private let worker: Task<Void, Never>
  private let generation = Counter()

  init(capacity: Int = InputQueue.capacity, perform: @escaping @Sendable (InputEvent, IsCurrent) async -> Void) {
    let (stream, continuation) = AsyncStream.makeStream(of: (InputEvent, UInt64).self, bufferingPolicy: .bufferingOldest(capacity))
    self.continuation = continuation
    worker = Task.detached(priority: .userInitiated) { [generation] in
      for await (event, queued) in stream {
        let isCurrent: IsCurrent = { generation.value == queued }
        guard isCurrent() else { continue }
        await perform(event, isCurrent)
      }
    }
  }

  func send(_ event: InputEvent) { continuation.yield((event, generation.value)) }

  func discardPending() { generation.increment() }

  func close() {
    continuation.finish()
    worker.cancel()
  }
}

private final class Counter: @unchecked Sendable { // `count` is guarded by `lock`.
  private let lock = NSLock()
  private var count: UInt64 = 0

  var value: UInt64 { lock.withLock { count } }
  func increment() { lock.withLock { count &+= 1 } }
}

/// Sends events over one persistent SimulatorKit HID connection: ~1 ms per event.
final class HIDInputDriver: InputDriver {
  let name = "Direct HID"
  private let queue: InputQueue
  private let hid: FBSimulatorHID

  init(hid: FBSimulatorHID, udid: String, points: CGSize) {
    self.hid = hid
    queue = InputQueue { event, isCurrent in
      await Self.perform(event, hid: hid, udid: udid, points: points, isCurrent: isCurrent)
    }
  }

  func send(_ event: InputEvent) { queue.send(event) }

  func discardPending() { queue.discardPending() }

  func close() {
    queue.close()
    hid.disconnect()
  }

  private static func perform(_ event: InputEvent, hid: FBSimulatorHID, udid: String, points: CGSize,
                              isCurrent: InputQueue.IsCurrent) async {
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
          guard isCurrent() else { return }
          switch segment {
          case .keys(let strokes):
            for stroke in strokes {
              guard isCurrent() else { return }
              try await press(stroke, hid: hid)
            }
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
  private let queue: InputQueue

  init?(udid: String, points: CGSize) {
    guard let axe = Tools.path(of: "axe") else { return nil }
    let pending = PendingTouch()
    queue = InputQueue { event, _ in
      let pt = { (v: Double, max: CGFloat) in String(format: "%.1f", clamp(v) * max) }
      var args: [String]?
      switch event {
      case .touch(.down, let x, let y):
        pending.start = (x, y, Date())
      case .touch(.move, _, _), .twoFingers:
        break // The CLI fallback has no live drags or multi-touch.
      case .touch(.up, let x, let y):
        guard let start = pending.start else { break }
        pending.start = nil
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

  func send(_ event: InputEvent) { queue.send(event) }

  func discardPending() { queue.discardPending() }

  func close() { queue.close() }
}

/// Where the current finger went down. Only the queue's single worker touches it.
private final class PendingTouch: @unchecked Sendable {
  var start: (x: Double, y: Double, at: Date)?
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
