import Foundation
import Testing
@testable import SimStream

struct ControlQueueTests {
  let a = UUID(), b = UUID(), c = UUID()
  let start = Date(timeIntervalSince1970: 1_000)

  @Test func firstTouchClaimsFreeControl() {
    var queue = ControlQueue()
    let result = queue.admit(a, now: start)
    #expect(result.allowed && result.changed)
    #expect(queue.holder == a)
    let other = queue.admit(b, now: start)
    #expect(other.allowed == false)
  }

  @Test func requestsQueueInOrderAndStartTheTurnClock() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    #expect(queue.turnEndsAt == nil)
    queue.request(b, now: start.addingTimeInterval(5))
    queue.request(c, now: start.addingTimeInterval(6))
    queue.request(b, now: start.addingTimeInterval(7)) // duplicate is ignored
    #expect(queue.waiting == [b, c])
    #expect(queue.position(of: c) == 2)
    #expect(queue.turnEndsAt == start.addingTimeInterval(5 + queue.turn))
  }

  @Test func holderKeepsControlWhileNobodyWaits() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    let moved = queue.tick(now: start.addingTimeInterval(3600))
    #expect(moved == nil)
    #expect(queue.holder == a)
  }

  @Test func turnExpiresWhenSomeoneWaits() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    queue.request(b, now: start)
    // Active the whole time, so only the turn limit applies.
    for second in stride(from: 0.0, to: queue.turn, by: 5) {
      _ = queue.admit(a, now: start.addingTimeInterval(second))
      let moved = queue.tick(now: start.addingTimeInterval(second))
      #expect(moved == nil)
    }
    let moved = queue.tick(now: start.addingTimeInterval(queue.turn))
    #expect(moved == .some(a))
    #expect(queue.holder == b)
    #expect(queue.turnEndsAt == nil)
  }

  @Test func idleHolderLosesControlEarly() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    queue.request(b, now: start.addingTimeInterval(1))
    let early = queue.tick(now: start.addingTimeInterval(queue.idle - 1))
    #expect(early == nil)
    let late = queue.tick(now: start.addingTimeInterval(queue.idle))
    #expect(late == .some(a))
    #expect(queue.holder == b)
  }

  @Test func newHolderGetsAFullTurnWhenOthersStillWait() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    queue.request(b, now: start)
    queue.request(c, now: start)
    queue.release(a, now: start.addingTimeInterval(10))
    #expect(queue.holder == b)
    #expect(queue.waiting == [c])
    #expect(queue.turnEndsAt == start.addingTimeInterval(10 + queue.turn))
  }

  @Test func leavingTheLineAndDisconnecting() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    queue.request(b, now: start)
    let left = queue.release(b, now: start)
    #expect(left)
    #expect(queue.waiting.isEmpty)
    #expect(queue.turnEndsAt == nil)
    let stranger = queue.release(c, now: start)
    #expect(stranger == false)
    queue.release(a, now: start)
    #expect(queue.holder == nil)
  }

  @Test func hostCanPassControlOn() {
    var queue = ControlQueue()
    queue.request(a, now: start)
    queue.request(b, now: start)
    queue.passOn(now: start)
    #expect(queue.holder == b)
    queue.passOn(now: start)
    #expect(queue.holder == nil)
  }
}
