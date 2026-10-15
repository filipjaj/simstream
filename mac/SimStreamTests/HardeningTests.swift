import Foundation
import Testing
@testable import SimStream

struct MessageAssemblerTests {
  private func frame(_ opcode: WebSocketFrame.Opcode, _ count: Int, fin: Bool) -> WebSocketFrame {
    WebSocketFrame(fin: fin, opcode: opcode, payload: Array(repeating: 0x61, count: count))
  }

  @Test func joinsFragmentsIntoOneMessage() throws {
    var assembler = MessageAssembler()
    #expect(try assembler.add(frame(.text, 3, fin: false)) == nil)
    #expect(try assembler.add(frame(.continuation, 2, fin: false)) == nil)
    #expect(try assembler.add(frame(.continuation, 1, fin: true))?.count == 6)
    // Ready for the next message.
    #expect(try assembler.add(frame(.text, 4, fin: true))?.count == 4)
  }

  @Test func rejectsMessagesThatGrowPastTheLimitThroughContinuations() throws {
    var assembler = MessageAssembler()
    let chunk = 16 * 1024
    _ = try assembler.add(frame(.text, chunk, fin: false))
    _ = try assembler.add(frame(.continuation, chunk, fin: false))
    _ = try assembler.add(frame(.continuation, chunk, fin: false))
    _ = try assembler.add(frame(.continuation, chunk, fin: false))
    #expect(throws: MessageAssembler.Failure.tooLarge) {
      try assembler.add(frame(.continuation, 1, fin: false))
    }
  }

  @Test func rejectsContinuationsWithoutAStartAndInterleavedMessages() throws {
    var assembler = MessageAssembler()
    #expect(throws: MessageAssembler.Failure.unexpectedContinuation) {
      try assembler.add(frame(.continuation, 1, fin: true))
    }
    _ = try assembler.add(frame(.text, 1, fin: false))
    #expect(throws: MessageAssembler.Failure.interleaved) {
      try assembler.add(frame(.text, 1, fin: true))
    }
  }
}

struct InputQueueTests {
  /// Records performed events; each one takes `delay` so a backlog builds up.
  private final class Recorder: @unchecked Sendable { // Guarded by `lock`.
    private let lock = NSLock()
    private var events: [InputEvent] = []
    func append(_ event: InputEvent) { lock.withLock { events.append(event) } }
    var all: [InputEvent] { lock.withLock { events } }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func discardDropsTheBacklogButNotLaterInput() async {
    let recorder = Recorder()
    let queue = InputQueue { event, _ in
      try? await Task.sleep(for: .milliseconds(20))
      recorder.append(event)
    }
    defer { queue.close() }
    for i in 0..<50 { queue.send(.key(UInt32(i))) }
    queue.discardPending()
    let lift = InputEvent.touch(.up, x: 0.5, y: 0.5)
    queue.send(lift)
    await waitUntil { recorder.all.last == lift }
    // At most the event already running when the backlog was discarded gets through.
    #expect(recorder.all.count <= 2)
    #expect(recorder.all.last == lift)
  }

  @Test func stopsALongTextPartWayWhenDiscarded() async {
    let typed = Recorder()
    let queue = InputQueue { _, isCurrent in
      for i in 0..<100 {
        guard isCurrent() else { return }
        typed.append(.key(UInt32(i)))
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
    defer { queue.close() }
    queue.send(.text(String(repeating: "a", count: 100)))
    await waitUntil { typed.all.count >= 5 }
    queue.discardPending()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(typed.all.count < 100)
  }

  @Test func dropsEventsBeyondCapacity() async {
    let recorder = Recorder()
    let gate = Recorder()
    let queue = InputQueue(capacity: 4) { event, _ in
      // Hold the first event until everything else is queued.
      if recorder.all.isEmpty { while gate.all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) } }
      recorder.append(event)
    }
    defer { queue.close() }
    for i in 0..<20 { queue.send(.key(UInt32(i))) }
    gate.append(.key(0))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(recorder.all.count <= 5)
  }
}

struct TextLimitTests {
  @Test func rejectsTextOverTheLimit() {
    let long = String(repeating: "a", count: InputEvent.maxTextLength + 1)
    let json = Data(#"{"type":"text","text":"\#(long)"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClientMessage.self, from: json) }
    let ok = Data(#"{"type":"text","text":"hello"}"#.utf8)
    #expect((try? JSONDecoder().decode(ClientMessage.self, from: ok)) == .input(.text("hello")))
  }

  @Test func onlyFingerUpsCountAsLifts() {
    #expect(InputEvent.touch(.up, x: 0, y: 0).isLift)
    #expect(InputEvent.twoFingers(.up, .zero, .zero).isLift)
    #expect(!InputEvent.touch(.down, x: 0, y: 0).isLift)
    #expect(!InputEvent.button(.home).isLift)
  }
}
