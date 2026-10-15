import AVFoundation
import Observation
import QuartzCore
import UIKit

/// One connection to a shared simulator: WebSocket, hardware H.264 decode and input forwarding.
/// Mirrors what viewer.html does in the browser, including the ack-per-frame flow control the
/// Mac relies on to keep latency flat.
@MainActor @Observable
final class StreamSession {
  enum Phase: Equatable {
    case connecting
    /// Frames are arriving.
    case live
    case reconnecting(attempt: Int)
    /// The host stopped sharing or the link's time ran out. Final.
    case expired
  }

  let link: StreamLink
  private(set) var phase = Phase.connecting
  private(set) var state: ViewerState?
  /// Round-trip time to the Mac in milliseconds.
  private(set) var latency: Double?
  /// Who drives the simulator. Nil from Macs that predate the control queue: anyone may touch.
  private(set) var control: ControlState?
  /// This viewer, as the Mac knows it.
  private(set) var me: Welcome?
  /// Bumps each time the Mac refuses input, to drive feedback.
  private(set) var deniedCount = 0
  /// Pixel size of the stream; follows the simulator when it rotates.
  private(set) var videoSize: CGSize?

  /// Hosted by the stream view; owned here so decoding survives view updates.
  @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var factory = H264SampleFactory()
  @ObservationIgnored private var needsKeyframe = true
  @ObservationIgnored private let encoder = JSONEncoder()
  @ObservationIgnored private let decoder = JSONDecoder()

  enum Role: Equatable {
    /// Nobody holds control; the first touch claims it.
    case open
    case driving
    case waiting(position: Int)
    case watching(holder: String)
  }

  var role: Role {
    guard let control, let holder = control.holder else { return .open }
    if holder.id == me?.id { return .driving }
    if let index = control.waiting.firstIndex(where: { $0.id == me?.id }) { return .waiting(position: index + 1) }
    return .watching(holder: holder.name)
  }

  var canControl: Bool {
    guard phase == .live, state?.controlEnabled == true else { return false }
    return role == .open || role == .driving
  }

  init(link: StreamLink) {
    self.link = link
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
  }

  /// For previews: a session frozen in one phase with no network.
  init(preview phase: Phase, state: ViewerState?, latency: Double? = nil, control: ControlState? = nil) {
    link = StreamLink("https://preview.trycloudflare.com/preview/")!
    self.phase = phase
    self.control = control
    me = Welcome(id: "me", name: "iPhone")
    self.state = state
    self.latency = latency
    videoSize = state.map { CGSize(width: $0.device.width * 3, height: $0.device.height * 3) }
  }

  func start() {
    guard runner == nil, phase != .expired else { return }
    runner = Task { await run() }
  }

  /// Drops the connection, e.g. when the app leaves the foreground. `start()` resumes.
  func stop() {
    runner?.cancel()
    runner = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    if phase == .live { phase = .reconnecting(attempt: 0) }
  }

  func send(_ message: ClientMessage) {
    guard let socket, let data = try? encoder.encode(message), let text = String(data: data, encoding: .utf8) else { return }
    socket.send(.string(text)) { _ in }
  }

  var multitouch: Bool { state?.multitouch == true }

  /// Touch messages from `TouchTracker`. Dropped while someone else drives.
  func send(touches messages: [ClientMessage]) {
    guard canControl else { return }
    messages.forEach(send)
  }

  func press(_ button: HardwareButton) {
    guard canControl else { return }
    send(.button(button))
  }

  // MARK: - Connection

  private func run() async {
    var attempt = 0
    let pinger = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        // The Mac drops viewers that stay silent for 8 s, so this doubles as a keepalive.
        self?.send(.ping(CACurrentMediaTime() * 1000))
      }
    }
    defer { pinger.cancel() }

    while !Task.isCancelled, phase != .expired {
      let task = URLSession.shared.webSocketTask(with: link.webSocketURL)
      task.maximumMessageSize = 8 << 20
      socket = task
      task.resume()
      needsKeyframe = true
      // A new connection is a new viewer to the Mac; stale queue state would misreport our role.
      control = nil
      me = nil
      if displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding { displayLayer.sampleBufferRenderer.flush() }
      send(.hello(h264: true))

      do {
        while !Task.isCancelled {
          let message = try await task.receive()
          attempt = 0
          receive(message)
        }
      } catch {
        if let response = task.response as? HTTPURLResponse, [404, 410].contains(response.statusCode) {
          phase = .expired
        }
      }
      if socket === task { socket = nil }
      guard !Task.isCancelled, phase != .expired else { break }

      attempt += 1
      phase = .reconnecting(attempt: attempt)
      try? await Task.sleep(for: .milliseconds(min(500 * (1 << min(attempt, 4)), 5000)))
    }
  }

  private func receive(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .data(let data):
      guard let packet = VideoPacket(data) else { return }
      handle(packet)
    case .string(let text):
      guard let message = try? decoder.decode(ServerMessage.self, from: Data(text.utf8)) else { return }
      handle(message)
    @unknown default:
      break
    }
  }

  private func handle(_ message: ServerMessage) {
    switch message {
    case .state(let next):
      state = next
    case .control(let next):
      control = next
    case .welcome(let welcome):
      me = welcome
    case .codec(let config):
      do {
        if try factory.configure(config) { displayLayer.sampleBufferRenderer.flush() }
        videoSize = CGSize(width: config.width, height: config.height)
      } catch {
        requestKeyframe()
      }
    case .pong(let sent):
      latency = CACurrentMediaTime() * 1000 - sent
    case .expired:
      phase = .expired
      socket?.cancel(with: .normalClosure, reason: nil)
    case .denied:
      deniedCount += 1
    case .unknown:
      break
    }
  }

  private func handle(_ packet: VideoPacket) {
    // Every frame is acknowledged, drawn or not; the Mac keeps at most four in flight.
    defer { send(.ack) }
    guard case .h264(let isKeyframe, let timestamp, let payload) = packet else { return }
    let renderer = displayLayer.sampleBufferRenderer

    if renderer.status == .failed {
      renderer.flush()
      return requestKeyframe()
    }
    if needsKeyframe && !isKeyframe { return }
    // Dropping a delta frame corrupts every frame after it, so a backed-up decoder resyncs instead.
    if !isKeyframe && !renderer.isReadyForMoreMediaData { return requestKeyframe() }

    do {
      let sample = try factory.sample(payload: payload, timestamp: timestamp, isKeyframe: isKeyframe)
      renderer.enqueue(sample)
      needsKeyframe = false
      if phase != .live { phase = .live }
    } catch {
      requestKeyframe()
    }
  }

  private func requestKeyframe() {
    guard !needsKeyframe else { return }
    needsKeyframe = true
    send(.keyframe)
  }
}

extension ViewerState {
  static let preview = ViewerState(
    device: Device(udid: "A1B2", name: "iPhone 17 Pro", runtime: "iOS 26.1", symbol: "iphone",
                   width: 402, height: 874, cornerRatio: 0.14),
    expiresAt: (Date.now.timeIntervalSince1970 + 1_380) * 1000,
    viewers: 2, controlEnabled: true, choices: [])
}
