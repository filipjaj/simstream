import Foundation
import Network

/// Serves the viewer page and its WebSocket on 127.0.0.1. Everything lives under a
/// random token path, so the public tunnel URL alone doesn't grant access.
final class StreamServer: @unchecked Sendable { // All mutable state is confined to `queue`.
  enum Failure: LocalizedError {
    case listenerFailed(String)

    var errorDescription: String? {
      switch self {
      case .listenerFailed(let reason): "Couldn't start the local server: \(reason)"
      }
    }
  }

  var onMessage: (@Sendable (ClientMessage) -> Void)?
  var onViewersChanged: (@Sendable (Int) -> Void)?
  var onKeyframeNeeded: (@Sendable () -> Void)?
  /// Holder name (nil when free) and how many wait, for the host's UI.
  var onControlChanged: (@Sendable (String?, Int) -> Void)?
  /// The holder lost control (hand-over, release, disconnect, control off). Called before the
  /// finger-lift, so queued input from the old holder can be dropped first.
  var onControlRevoked: (@Sendable () -> Void)?
  var latestJPEG: (@Sendable () -> Data?)?

  private let queue = DispatchQueue(label: "simstream.server", qos: .userInteractive)
  private let page: Data
  private var token: String?
  private var listener: NWListener?
  private var viewers: [UUID: ViewerConnection] = [:]
  private var state: Data?
  private var heartbeat: DispatchSourceTimer?
  private var control = ControlQueue()
  private var controlEnabled = true
  private var guestNumber = 0
  /// The holder's last touch while fingers are down, so a hand-over can lift them.
  private var touchDown: InputEvent?
  private let countLock = NSLock()
  private var currentDemand = StreamDemand()

  /// Safe to read from any thread; the frame pump encodes only what viewers need.
  var demand: StreamDemand { countLock.withLock { currentDemand } }

  init(token: String, page: Data) {
    self.token = token
    self.page = page
  }

  func start(port: UInt16? = nil) async throws -> UInt16 {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

    return try await withCheckedThrowingContinuation { continuation in
      let once = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port?.rawValue { once.run { continuation.resume(returning: port) } }
        case .failed(let error):
          once.run { continuation.resume(throwing: Failure.listenerFailed(error.localizedDescription)) }
        default:
          break
        }
      }
      listener.start(queue: queue)
      startHeartbeat()
    }
  }

  /// cloudflared keeps the local socket open after a browser leaves, so silence is the only
  /// reliable signal. Viewers ping every 2 s; anyone quiet for 8 s is dropped.
  private func startHeartbeat() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 3, repeating: 3)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      for viewer in viewers.values {
        if viewer.silence > 8 { viewer.close() } else { viewer.ping() }
      }
      if control.tick(now: Date()) != nil { controlMoved() }
    }
    timer.resume()
    heartbeat = timer
  }

  func publish(state: Data) {
    queue.async { [self] in
      self.state = state
      viewers.values.forEach { $0.sendText(state) }
    }
  }

  func broadcast(jpeg: Data) {
    queue.async { [self] in
      // Frame once, send the same bytes to every viewer.
      let packet = WebSocketFrame.encode(.binary, VideoPacket.jpeg(jpeg))
      viewers.values.filter { $0.codec == .jpeg }.forEach { $0.sendJPEG(packet) }
    }
  }

  func broadcast(h264 frame: H264Frame, config: H264Config) {
    queue.async { [self] in
      let packet = WebSocketFrame.encode(.binary, VideoPacket.h264(frame))
      var needsKeyframe = false
      for viewer in viewers.values where viewer.codec == .h264 {
        if viewer.config != config, frame.isKeyframe {
          viewer.config = config
          viewer.sendText(VideoPacket.codecMessage(config))
        }
        if viewer.sendVideo(packet, isKeyframe: frame.isKeyframe) { needsKeyframe = true }
      }
      if needsKeyframe { onKeyframeNeeded?() }
    }
  }

  func setControlEnabled(_ enabled: Bool) {
    queue.async { [self] in
      controlEnabled = enabled
      if !enabled { liftFinger() }
    }
  }

  /// Host override: hands control to the next viewer in line.
  func passControl() {
    queue.async { [self] in
      control.passOn(now: Date())
      controlMoved()
    }
  }

  /// Revokes the token, tells viewers the link expired and disconnects them.
  func expire() {
    queue.async { [self] in
      token = nil
      let message = Data(#"{"type":"expired"}"#.utf8)
      viewers.values.forEach { $0.sendText(message) }
      queue.asyncAfter(deadline: .now() + 0.5) { [self] in
        viewers.values.forEach { $0.close() }
      }
    }
  }

  func stop() {
    queue.async { [self] in
      token = nil
      viewers.values.forEach { $0.close() }
      heartbeat?.cancel()
      heartbeat = nil
      listener?.cancel()
      listener = nil
    }
  }

  // MARK: - HTTP

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    readHead(connection, buffer: [])
  }

  private func readHead(_ connection: NWConnection, buffer: [UInt8]) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(contentsOf: data) }
      if let (request, used) = HTTPRequest.parse(buffer) {
        route(request, connection: connection, leftover: Array(buffer[used...]))
      } else if error != nil || isComplete || buffer.count > 16_384 {
        connection.cancel()
      } else {
        readHead(connection, buffer: buffer)
      }
    }
  }

  private func route(_ request: HTTPRequest, connection: NWConnection, leftover: [UInt8]) {
    guard let token, request.method == "GET" else {
      return respond(connection, status: "410 Gone", type: "text/html; charset=utf-8", body: Self.expiredPage)
    }
    switch request.path {
    case "/\(token)":
      respond(connection, status: "308 Permanent Redirect", type: "text/plain", body: Data(), extra: "Location: /\(token)/\r\n")
    case "/\(token)/":
      respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page)
    case "/\(token)/health":
      respond(connection, status: "200 OK", type: "text/plain", body: Data("ok".utf8))
    case "/\(token)/ws" where request.isWebSocketUpgrade:
      upgrade(connection, request: request, leftover: leftover)
    default:
      respond(connection, status: "404 Not Found", type: "text/html; charset=utf-8", body: Self.expiredPage)
    }
  }

  private func respond(_ connection: NWConnection, status: String, type: String, body: Data, extra: String = "") {
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
    var response = Data(head.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }

  // MARK: - WebSocket

  private func upgrade(_ connection: NWConnection, request: HTTPRequest, leftover: [UInt8]) {
    let accept = WebSocketFrame.acceptKey(for: request.headers["sec-websocket-key"] ?? "")
    let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

    let viewer = ViewerConnection(connection: connection)
    viewer.onText = { [weak self, weak viewer] payload in
      guard let self, let viewer else { return }
      handle(payload, from: viewer)
    }
    viewer.onClose = { [weak self, weak viewer] in
      guard let self, let viewer else { return }
      viewers[viewer.id] = nil
      updateCount()
      let wasHolder = control.holder == viewer.id
      if control.release(viewer.id, now: Date()) {
        if wasHolder { liftFinger() }
        broadcastControl()
      }
    }
    guestNumber += 1
    viewer.name = "Guest \(guestNumber)"
    viewers[viewer.id] = viewer
    updateCount()
    if let welcome = try? JSONEncoder().encode(Welcome(id: viewer.id.uuidString, name: viewer.name)) { viewer.sendText(welcome) }
    if let state { viewer.sendText(state) }
    if let control = controlMessage() { viewer.sendText(control) }
    viewer.begin(with: leftover)
  }

  private func handle(_ payload: Data, from viewer: ViewerConnection) {
    guard let message = try? JSONDecoder().decode(ClientMessage.self, from: payload) else { return }
    switch message {
    case .ack:
      viewer.acknowledgeFrame()
    case .hello(let h264):
      viewer.codec = h264 ? .h264 : .jpeg
      updateCount()
      if h264 {
        onKeyframeNeeded?()
      } else if let frame = latestJPEG?() {
        viewer.sendJPEG(WebSocketFrame.encode(.binary, VideoPacket.jpeg(frame)))
      }
    case .keyframe:
      viewer.resync()
      onKeyframeNeeded?()
    case .ping(let sent):
      viewer.sendText(Data(#"{"type":"pong","t":\#(sent)}"#.utf8))
    case .requestControl:
      if control.request(viewer.id, now: Date()) { broadcastControl() }
    case .releaseControl:
      let wasHolder = control.holder == viewer.id
      if control.release(viewer.id, now: Date()) {
        if wasHolder { liftFinger() }
        broadcastControl()
      }
    case .input(let event):
      guard controlEnabled else { return Self.debug("\(viewer.name) input dropped: control is off") }
      let (allowed, changed) = control.admit(viewer.id, now: Date())
      Self.debug("\(viewer.name) \(event) \(allowed ? "admitted" : "denied (holder: \(control.holder.flatMap { viewers[$0]?.name } ?? "nobody"))")")
      guard allowed else {
        viewer.sendText(Data(#"{"type":"denied"}"#.utf8))
        return
      }
      switch event {
      case .touch(let phase, _, _), .twoFingers(let phase, _, _): touchDown = phase == .up ? nil : event
      default: break
      }
      if changed { broadcastControl() }
      onMessage?(message)
    case .select:
      // Switching simulators is the holder's call.
      guard control.holder == viewer.id || control.holder == nil else { return }
      onMessage?(message)
    }
  }

  // MARK: - Control

  /// Control changed hands: lift the previous holder's finger and tell everyone.
  private func controlMoved() {
    liftFinger()
    broadcastControl()
  }

  private func liftFinger() {
    onControlRevoked?()
    guard let touch = touchDown else { return }
    touchDown = nil
    switch touch {
    case .touch(_, let x, let y): onMessage?(.input(.touch(.up, x: x, y: y)))
    case .twoFingers(_, let a, let b): onMessage?(.input(.twoFingers(.up, a, b)))
    default: break
    }
  }

  private func controlMessage() -> Data? {
    let viewers = viewers
    let person = { (id: UUID) in viewers[id].map { ControlState.Person(id: id.uuidString, name: $0.name) } }
    let message = ControlState(holder: control.holder.flatMap(person), waiting: control.waiting.compactMap(person),
                               turnEndsAt: control.turnEndsAt.map { $0.timeIntervalSince1970 * 1000 })
    return try? JSONEncoder().encode(message)
  }

  private func broadcastControl() {
    guard let message = controlMessage() else { return }
    viewers.values.forEach { $0.sendText(message) }
    onControlChanged?(control.holder.flatMap { viewers[$0]?.name }, control.waiting.count)
  }

  private func updateCount() {
    let demand = StreamDemand(jpeg: viewers.values.contains { $0.codec == .jpeg },
                              h264: viewers.values.contains { $0.codec == .h264 })
    countLock.withLock { currentDemand = demand }
    onViewersChanged?(viewers.count)
  }

  /// `SIMSTREAM_DEBUG=1` logs every viewer input and whether it was admitted.
  private static let debugging = ProcessInfo.processInfo.environment["SIMSTREAM_DEBUG"] == "1"
  private static func debug(_ message: @autoclosure () -> String) {
    guard debugging else { return }
    print("[input] \(message())")
  }

  private static let expiredPage = Data("""
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Link expired</title>
    <style>:root{color-scheme:light dark}body{margin:0;min-height:100dvh;display:grid;place-items:center;
    font:17px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;background:Canvas;color:CanvasText;text-align:center}
    p{color:color-mix(in srgb,CanvasText 60%,transparent);margin:6px 0 0}</style>
    <main><h1 style="font-size:22px;margin:0">This link has expired</h1><p>Ask for a new link to keep watching.</p></main>
    """.utf8)
}

/// One viewer's WebSocket, with end-to-end flow control: the browser acknowledges each frame
/// it draws, and at most a few are in flight. A slow viewer gets fewer frames, never a growing delay.
/// JPEG is latest-wins. H.264 can't skip frames, so a backlog is dropped and resumes at a keyframe.
private final class ViewerConnection {
  enum Codec { case pending, jpeg, h264 }

  let id = UUID()
  var onText: ((Data) -> Void)?
  var onClose: (() -> Void)?
  /// Nothing is streamed until the browser's hello says what it can decode.
  var codec = Codec.pending
  var config: H264Config?
  var name = "Guest"

  private var maxUnacked: Int { codec == .h264 ? 4 : 2 }
  private static let maxVideoBacklog = 6
  private let connection: NWConnection
  private var buffer: [UInt8] = []
  private var message = MessageAssembler()
  private var controlOut: [Data] = []
  private var pendingFrame: Data?
  private var videoQueue: [Data] = []
  private var needsKeyframe = true
  private var sending = false
  private var unacked = 0
  private var lastFrameSent = Date.distantPast
  private var lastReceived = Date()
  private var closed = false

  /// Seconds since the browser last sent anything.
  var silence: TimeInterval { Date().timeIntervalSince(lastReceived) }

  func ping() {
    controlOut.append(WebSocketFrame.encode(.ping, Data()))
    pump()
  }

  init(connection: NWConnection) {
    self.connection = connection
  }

  func begin(with leftover: [UInt8]) {
    buffer = leftover
    drain()
    receive()
  }

  func sendText(_ text: Data) {
    controlOut.append(WebSocketFrame.encode(.text, text))
    pump()
  }

  /// `packet` is an encoded WebSocket frame.
  func sendJPEG(_ packet: Data) {
    pendingFrame = packet
    unstickIfNeeded()
    pump()
  }

  /// Queues an encoded H.264 packet. Returns true if this viewer needs a keyframe.
  func sendVideo(_ packet: Data, isKeyframe: Bool) -> Bool {
    if isKeyframe {
      needsKeyframe = false
      videoQueue.removeAll()
    } else if needsKeyframe {
      return true
    }
    videoQueue.append(packet)
    if videoQueue.count > Self.maxVideoBacklog {
      resync()
      return true
    }
    unstickIfNeeded()
    pump()
    return false
  }

  /// Drops queued video and waits for the next keyframe.
  func resync() {
    videoQueue.removeAll()
    needsKeyframe = true
    unacked = 0
  }

  /// A viewer that stops acknowledging (background tab) gets unstuck after 2 s.
  private func unstickIfNeeded() {
    if unacked >= maxUnacked, Date().timeIntervalSince(lastFrameSent) > 2 { unacked = 0 }
  }

  func acknowledgeFrame() {
    unacked = max(0, unacked - 1)
    pump()
  }

  func close() {
    guard !closed else { return }
    closed = true
    connection.send(content: WebSocketFrame.encode(.close, Data()), completion: .contentProcessed { [connection] _ in connection.cancel() })
    onClose?()
  }

  private func pump() {
    guard !sending, !closed else { return }
    let next: Data
    if !controlOut.isEmpty {
      next = controlOut.removeFirst()
    } else if unacked < maxUnacked, let frame = pendingFrame ?? videoQueue.first {
      if pendingFrame != nil { pendingFrame = nil } else { videoQueue.removeFirst() }
      unacked += 1
      lastFrameSent = Date()
      next = frame
    } else {
      return
    }
    sending = true
    connection.send(content: next, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      sending = false
      if error != nil { close() } else { pump() }
    })
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self, !closed else { return }
      if let data, !data.isEmpty {
        buffer.append(contentsOf: data)
        lastReceived = Date()
      }
      drain()
      if error != nil || isComplete { close() } else { receive() }
    }
  }

  private func drain() {
    do {
      while let (frame, used) = try WebSocketFrame.parse(buffer[...]) {
        buffer.removeFirst(used)
        handle(frame)
      }
    } catch {
      close()
    }
  }

  private func handle(_ frame: WebSocketFrame) {
    switch frame.opcode {
    case .text, .binary, .continuation:
      do {
        if let complete = try message.add(frame) { onText?(Data(complete)) }
      } catch {
        close()
      }
    case .ping:
      controlOut.append(WebSocketFrame.encode(.pong, Data(frame.payload)))
      pump()
    case .pong:
      break
    case .close:
      close()
    }
  }
}

/// Runs a closure at most once across threads.
final class Once: @unchecked Sendable { // `done` is guarded by `lock`.
  private let lock = NSLock()
  private var done = false

  func run(_ body: () -> Void) {
    let first = lock.withLock { () -> Bool in
      defer { done = true }
      return !done
    }
    if first { body() }
  }
}
