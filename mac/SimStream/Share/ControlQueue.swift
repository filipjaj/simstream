import Foundation

/// Who may drive the simulator. One holder at a time; everyone else watches or waits in line.
///
/// Rules:
/// - With nobody waiting, the holder keeps control for as long as they like.
/// - Once someone waits, the holder's turn ends after `turn` seconds, or sooner after
///   `idle` seconds without input. Control then passes to the next in line.
/// - Releasing, leaving or disconnecting passes control on immediately.
struct ControlQueue: Equatable, Sendable {
  var turn: TimeInterval = 60
  var idle: TimeInterval = 20

  private(set) var holder: UUID?
  private(set) var waiting: [UUID] = []
  /// Set only while someone waits.
  private(set) var turnEndsAt: Date?
  private(set) var lastInput = Date.distantPast

  /// Asks for control. Granted at once if nobody holds it, otherwise joins the line.
  /// Returns true if anything changed.
  @discardableResult
  mutating func request(_ id: UUID, now: Date) -> Bool {
    if holder == nil {
      grant(id, now: now)
      return true
    }
    guard holder != id, !waiting.contains(id) else { return false }
    waiting.append(id)
    if turnEndsAt == nil { turnEndsAt = now.addingTimeInterval(turn) }
    return true
  }

  /// Gives up control or leaves the line. Also used when a viewer disconnects.
  @discardableResult
  mutating func release(_ id: UUID, now: Date) -> Bool {
    if holder == id {
      advance(now: now)
      return true
    }
    guard let index = waiting.firstIndex(of: id) else { return false }
    waiting.remove(at: index)
    if waiting.isEmpty { turnEndsAt = nil }
    return true
  }

  /// Whether `id` may send input now. A touch with nobody in control claims it.
  /// `changed` reports whether the claim altered the queue.
  mutating func admit(_ id: UUID, now: Date) -> (allowed: Bool, changed: Bool) {
    if holder == nil {
      waiting.removeAll { $0 == id }
      grant(id, now: now)
      return (true, true)
    }
    guard holder == id else { return (false, false) }
    lastInput = now
    return (true, false)
  }

  /// Ends an expired or idle turn. Returns the previous holder if control moved.
  mutating func tick(now: Date) -> UUID?? {
    guard let current = holder, !waiting.isEmpty else { return nil }
    let expired = turnEndsAt.map { now >= $0 } ?? false
    let idleTooLong = now.timeIntervalSince(lastInput) >= idle
    guard expired || idleTooLong else { return nil }
    advance(now: now)
    return .some(current)
  }

  /// Host override: hands control to the next in line (or to nobody).
  mutating func passOn(now: Date) {
    advance(now: now)
  }

  func position(of id: UUID) -> Int? {
    waiting.firstIndex(of: id).map { $0 + 1 }
  }

  private mutating func grant(_ id: UUID, now: Date) {
    holder = id
    lastInput = now
    turnEndsAt = waiting.isEmpty ? nil : now.addingTimeInterval(turn)
  }

  private mutating func advance(now: Date) {
    if waiting.isEmpty {
      holder = nil
      turnEndsAt = nil
    } else {
      grant(waiting.removeFirst(), now: now)
    }
  }
}
