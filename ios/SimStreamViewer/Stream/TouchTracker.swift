import CoreGraphics

/// Turns this device's fingers into SimStream touch messages. The simulator takes one finger or two,
/// so a third is ignored, and a two-finger gesture ends as soon as either finger lifts (the remaining
/// finger is ignored until it lifts too, so it can't turn into a stray drag).
///
/// Going from one finger to two lifts the first (`touch` up) and starts a pair (`touches` down),
/// the transition the Mac expects. Fingers that land together start the pair directly, so a pinch
/// doesn't tap whatever is under the first finger.
struct TouchTracker<Key: Hashable> {
  /// Set from the Mac's `multitouch` capability. Off: second fingers are ignored.
  var multitouch = false

  private enum Mode { case idle, one, two }
  private var mode = Mode.idle
  /// Tracked fingers, first down first; at most two.
  private var order: [Key] = []
  private var points: [Key: CGPoint] = [:]
  /// Fingers still on the glass that the simulator doesn't know about.
  private var ignored: Set<Key> = []

  mutating func began(_ touches: [(Key, CGPoint)]) -> [ClientMessage] {
    if mode == .idle, ignored.isEmpty, multitouch, touches.count >= 2 {
      for (key, point) in touches.prefix(2) { track(key, point) }
      ignored.formUnion(touches.dropFirst(2).map(\.0))
      mode = .two
      return [pair(.down)]
    }
    var messages: [ClientMessage] = []
    for (key, point) in touches {
      switch mode {
      case .idle where ignored.isEmpty:
        track(key, point)
        mode = .one
        messages.append(.touch(.down, x: point.x, y: point.y))
      case .one where multitouch:
        let first = points[order[0]] ?? point
        track(key, point)
        mode = .two
        messages += [.touch(.up, x: first.x, y: first.y), pair(.down)]
      default:
        ignored.insert(key)
      }
    }
    return messages
  }

  mutating func moved(_ touches: [(Key, CGPoint)]) -> [ClientMessage] {
    var changed = false
    for (key, point) in touches where points[key] != nil {
      points[key] = point
      changed = true
    }
    guard changed else { return [] }
    switch mode {
    case .one:
      let point = points[order[0]]!
      return [.touch(.move, x: point.x, y: point.y)]
    case .two:
      return [pair(.move)]
    case .idle:
      return []
    }
  }

  /// Lifted or cancelled fingers.
  mutating func ended(_ touches: [(Key, CGPoint)]) -> [ClientMessage] {
    var messages: [ClientMessage] = []
    for (key, point) in touches {
      if ignored.remove(key) != nil { continue }
      guard points[key] != nil else { continue }
      points[key] = point
      switch mode {
      case .one:
        messages.append(.touch(.up, x: point.x, y: point.y))
      case .two:
        messages.append(pair(.up))
        ignored.formUnion(order.filter { $0 != key })
      case .idle:
        break
      }
      order.removeAll()
      points.removeAll()
      mode = .idle
    }
    return messages
  }

  private mutating func track(_ key: Key, _ point: CGPoint) {
    order.append(key)
    points[key] = point
  }

  private func pair(_ phase: TouchPhase) -> ClientMessage {
    .touches(phase, points: order.enumerated().map { index, key in
      let point = points[key] ?? .zero
      return TouchPoint(id: index, x: point.x, y: point.y)
    })
  }
}
