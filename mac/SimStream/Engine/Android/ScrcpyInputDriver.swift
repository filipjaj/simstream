import CoreGraphics
import Foundation

/// Sends viewer input over scrcpy's control socket: touches as real Android pointers (two-finger
/// pinch included), keys and buttons as key events, text typed or pasted.
final class ScrcpyInputDriver: InputDriver {
  let name = "scrcpy"
  private let queue: InputQueue

  init(link: AndroidLink) {
    let fingers = Fingers()
    let lastPaste = PasteClock()
    queue = InputQueue { [weak link] event, isCurrent in
      guard let link else { return }
      let size = link.videoSize
      for message in fingers.messages(for: event, width: size.width, height: size.height) {
        guard isCurrent() else { return }
        // Give the app time to read the clipboard before the next paste replaces it.
        if message.first == 9 {
          let wait = lastPaste.remaining(spacing: 0.25)
          if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
          lastPaste.mark()
        }
        link.send(message)
      }
    }
  }

  func send(_ event: InputEvent) { queue.send(event) }

  func discardPending() { queue.discardPending() }

  func close() { queue.close() }
}

/// When the last clipboard paste went out. Only the input queue's single worker uses it.
private final class PasteClock: @unchecked Sendable {
  private var last = Date.distantPast

  func remaining(spacing: TimeInterval) -> TimeInterval { spacing - Date().timeIntervalSince(last) }
  func mark() { last = Date() }
}

/// Turns SimStream input events into scrcpy control messages. Tracks which pointers are down, since
/// SimStream's events describe whole gestures (a down at a new point moves the finger, a two-finger
/// event may follow a one-finger one) while Android needs explicit DOWN/MOVE/UP per pointer.
/// Only the input queue's single worker uses it.
final class Fingers: @unchecked Sendable {
  private var down: [UInt64: CGPoint] = [:]

  func messages(for event: InputEvent, width: Int, height: Int) -> [Data] {
    // Before the first frame the video size is unknown and the server would drop touches anyway.
    let hasSize = width > 1 && height > 1
    switch event {
    case .touch, .twoFingers:
      guard hasSize else { return [] }
    default:
      break
    }
    switch event {
    case .touch(let phase, let x, let y):
      let point = CGPoint(x: x, y: y)
      var out = lift(1, width: width, height: height)
      switch phase {
      case .down, .move: out += place(0, at: point, width: width, height: height)
      case .up: out += place(0, at: point, width: width, height: height) + lift(0, width: width, height: height)
      }
      return out
    case .twoFingers(let phase, let a, let b):
      switch phase {
      case .down, .move:
        return place(0, at: a, width: width, height: height) + place(1, at: b, width: width, height: height)
      case .up:
        return place(1, at: b, width: width, height: height) + lift(1, width: width, height: height)
          + place(0, at: a, width: width, height: height) + lift(0, width: width, height: height)
      }
    case .key(let usage):
      guard let code = AndroidKeys.keycode(forHIDUsage: usage) else { return [] }
      return press(code)
    case .button(let button):
      return press(AndroidKeys.keycode(for: button))
    case .text(let text):
      return AndroidKeys.segments(for: text).flatMap { segment -> [Data] in
        switch segment {
        case .type(let typed): ScrcpyProtocol.textChunks(typed).map(ScrcpyProtocol.injectText)
        case .enter: press(AndroidKeys.enter)
        case .paste(let pasted): [ScrcpyProtocol.setClipboard(pasted, paste: true)]
        }
      }
    }
  }

  private func press(_ keycode: UInt32) -> [Data] {
    [ScrcpyProtocol.keycode(.down, keycode: keycode), ScrcpyProtocol.keycode(.up, keycode: keycode)]
  }

  /// DOWN for a new pointer, MOVE for one already down (skipped if it hasn't moved).
  private func place(_ pointer: UInt64, at point: CGPoint, width: Int, height: Int) -> [Data] {
    let previous = down[pointer]
    if previous == point { return [] }
    down[pointer] = point
    return [touch(previous == nil ? .down : .move, pointer, point, width, height)]
  }

  private func lift(_ pointer: UInt64, width: Int, height: Int) -> [Data] {
    guard let point = down.removeValue(forKey: pointer) else { return [] }
    return [touch(.up, pointer, point, width, height)]
  }

  private func touch(_ action: ScrcpyProtocol.TouchAction, _ pointer: UInt64, _ point: CGPoint, _ width: Int, _ height: Int) -> Data {
    let clamp = { (v: Double) in min(max(v, 0), 1) }
    return ScrcpyProtocol.touch(action, pointer: pointer,
                                x: Int32((clamp(point.x) * Double(width - 1)).rounded()),
                                y: Int32((clamp(point.y) * Double(height - 1)).rounded()),
                                width: UInt16(clamping: width), height: UInt16(clamping: height))
  }
}
