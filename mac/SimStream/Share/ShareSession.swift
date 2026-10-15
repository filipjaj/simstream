import Foundation
import Observation

/// Routes viewer input to the current simulator without hopping through the main actor.
private final class InputRouter: @unchecked Sendable { // State is guarded by `lock`.
  private let lock = NSLock()
  private var link: SimulatorLink?
  private var enabled = true
  /// Set while the share is locked to one app.
  private var edges: EdgeGuard?

  func configure(link: SimulatorLink?, enabled: Bool) {
    lock.withLock {
      self.link = link
      self.enabled = enabled
    }
  }

  func setEnabled(_ enabled: Bool) { lock.withLock { self.enabled = enabled } }

  func setLocked(_ locked: Bool) { lock.withLock { edges = locked ? EdgeGuard() : nil } }

  func route(_ event: InputEvent) {
    let (target, events): (SimulatorLink?, [InputEvent]) = lock.withLock {
      guard enabled, let link else { return (nil, []) }
      return (link, edges?.filter(event) ?? [event])
    }
    events.forEach { target?.input.send($0) }
  }
}

/// One public link to one simulator, live for 15 minutes unless extended or stopped.
@MainActor @Observable
final class ShareSession {
  enum Phase: Equatable {
    case idle
    case starting(String)
    case live(URL)
    case ended(EndReason)
    case failed(String)
  }

  enum EndReason: Equatable {
    case expired, stopped
  }

  nonisolated static let lifetime: TimeInterval = 15 * 60

  /// How a share is served. The Mac app uses the defaults; the CLI sets them from flags.
  struct Options: Sendable {
    /// Open a public Cloudflare quick tunnel. Off serves on 127.0.0.1 only.
    var tunnel = true
    /// Fixed local port, for port forwarding. Nil picks a free one.
    var port: UInt16?
    var lifetime: TimeInterval = ShareSession.lifetime
  }

  var options = Options()
  /// The page on 127.0.0.1, available as soon as the local server runs.
  private(set) var localURL: URL?

  private(set) var phase = Phase.idle
  private(set) var device: SimulatorDevice?
  private(set) var expiresAt: Date?
  private(set) var viewers = 0
  private(set) var stats = StreamStats()
  private(set) var inputTransport: String?

  var allowControl = true {
    didSet {
      router.setEnabled(allowControl)
      server?.setControlEnabled(allowControl)
      publishState()
      remoteControl("control \(allowControl ? "on" : "off")")
    }
  }
  /// Viewer currently driving the simulator, if any.
  private(set) var controllerName: String?
  private(set) var waitingCount = 0
  var allowSwitching = false {
    didSet {
      publishState()
      remoteControl("switching \(allowSwitching ? "on" : "off")")
    }
  }
  /// Keeps viewers inside one app: system gestures and buttons are dropped, and the app is
  /// brought back to the front whenever something else opens.
  var lockedApp: LockedApp? {
    didSet {
      guard lockedApp != oldValue else { return }
      router.setLocked(lockedApp != nil)
      publishState()
      remoteControl(lockedApp.map { LockedApp.isValidBundleID($0.bundleID) ? "lock \($0.bundleID)" : "lock off" } ?? "lock off")
      startLockWatch()
    }
  }
  var quality = StreamQuality.balanced {
    didSet {
      pump.setQuality(quality)
      remoteControl("quality \(quality.cliName)")
    }
  }

  /// Set while the share runs detached on a remote Mac (see RemoteShare).
  private(set) var remoteHost: RemoteHost?
  private var remotePoll: Task<Void, Never>?
  /// True while copying remote state into the properties above, so their didSets don't echo it back.
  private var applyingRemote = false

  var isActive: Bool {
    switch phase {
    case .starting, .live: true
    default: false
    }
  }

  var url: URL? {
    if case .live(let url) = phase { url } else { nil }
  }

  private let pool: LinkPool
  private let catalog: SimulatorCatalog
  private let pump = FramePump()
  private let router = InputRouter()
  private var server: StreamServer?
  private var tunnel: QuickTunnel?
  private var startTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var lockWatch: Task<Void, Never>?

  init(pool: LinkPool, catalog: SimulatorCatalog) {
    self.pool = pool
    self.catalog = catalog
  }

  func start(_ device: SimulatorDevice) {
    if remoteHost != nil { stopRemote() }
    teardown()
    self.device = device
    viewers = 0
    phase = .starting("Connecting to \(device.name)…")
    startTask = Task { [weak self] in
      do {
        try await self?.run(device)
      } catch is CancellationError {
        // Stopped while starting.
      } catch {
        self?.fail(error.localizedDescription)
      }
    }
  }

  func stop() {
    guard isActive else { return }
    if remoteHost != nil { stopRemote() }
    teardown()
    phase = .ended(.stopped)
  }

  /// Hands control to the next viewer in line.
  func passControl() {
    server?.passControl()
    remoteControl("pass")
  }

  /// Pushes the expiry back by another 15 minutes from now, or from the current expiry if later.
  func extend() {
    if remoteHost != nil { return remoteControl("extend") }
    guard let expiresAt, url != nil else { return }
    self.expiresAt = max(expiresAt, Date()).addingTimeInterval(options.lifetime)
    scheduleExpiry()
    publishState()
  }

  /// Moves the live share to another booted simulator; viewers keep their link.
  func switchTo(_ next: SimulatorDevice) async {
    guard isActive, next.isBooted, next.udid != device?.udid else { return }
    do {
      let link = try await pool.link(for: next.udid)
      device = next
      inputTransport = link.input.name
      router.configure(link: link, enabled: allowControl)
      pump.start(link: link, quality: quality)
      publishState()
    } catch {
      NSLog("SimStream: couldn't switch to \(next.name): \(error)")
    }
  }

  // MARK: - Lifecycle

  private func run(_ device: SimulatorDevice) async throws {
    let link = try await pool.link(for: device.udid)
    try Task.checkCancellation()
    inputTransport = link.input.name

    let token = Self.makeToken()
    let server = StreamServer(token: token, page: Self.viewerPage)
    self.server = server
    router.configure(link: link, enabled: allowControl)
    router.setLocked(lockedApp != nil)
    startLockWatch()
    server.onMessage = { [weak self, router] message in
      switch message {
      case .input(let event):
        router.route(event)
      case .select(let udid):
        Task { @MainActor in self?.viewerSelected(udid) }
      case .ping, .ack, .hello, .keyframe, .requestControl, .releaseControl:
        break
      }
    }
    server.onViewersChanged = { [weak self] count in
      Task { @MainActor in
        self?.viewers = count
        self?.publishState()
      }
    }
    server.onControlChanged = { [weak self] holder, waiting in
      Task { @MainActor in
        self?.controllerName = holder
        self?.waitingCount = waiting
      }
    }
    server.setControlEnabled(allowControl)
    server.latestJPEG = { [pump] in pump.latestJPEG }
    server.onKeyframeNeeded = { [pump] in pump.requestKeyframe() }
    let port = try await server.start(port: options.port)
    localURL = URL(string: "http://127.0.0.1:\(port)/\(token)/")

    pump.onJPEG = { [weak server] frame in server?.broadcast(jpeg: frame) }
    pump.onH264 = { [weak server] frame, config in server?.broadcast(h264: frame, config: config) }
    pump.demand = { [weak server] in server?.demand ?? StreamDemand() }
    pump.onStats = { [weak self] stats in
      Task { @MainActor in if self?.stats != stats { self?.stats = stats } }
    }
    pump.start(link: link, quality: quality)

    guard options.tunnel else {
      expiresAt = Date().addingTimeInterval(options.lifetime)
      if let localURL { phase = .live(localURL) }
      scheduleExpiry()
      publishState()
      return
    }

    phase = .starting("Creating a public link…")
    let tunnel = QuickTunnel()
    self.tunnel = tunnel
    let base = try await tunnel.start(port: port)
    tunnel.onExit = { [weak self] in
      Task { @MainActor in self?.fail("The tunnel closed unexpectedly.") }
    }
    try Task.checkCancellation()

    phase = .starting("Publishing the link…")
    await tunnel.waitForDNS(base)
    try Task.checkCancellation()
    let shareURL = base.appending(path: token + "/")

    expiresAt = Date().addingTimeInterval(options.lifetime)
    phase = .live(shareURL)
    scheduleExpiry()
    publishState()
  }

  private func scheduleExpiry() {
    expiryTask?.cancel()
    guard let expiresAt else { return }
    expiryTask = Task { [weak self] in
      let delay = expiresAt.timeIntervalSinceNow
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard !Task.isCancelled else { return }
      self?.expire()
    }
  }

  private func expire() {
    server?.expire()
    let server = server, tunnel = tunnel
    tunnel?.onExit = nil
    // Give viewers a moment to receive the "expired" message before the tunnel goes.
    Task {
      try? await Task.sleep(for: .seconds(1))
      server?.stop()
      tunnel?.stop()
    }
    self.server = nil
    self.tunnel = nil
    teardown()
    phase = .ended(.expired)
  }

  private func fail(_ message: String) {
    guard isActive else { return }
    teardown()
    phase = .failed(message)
  }

  private func teardown() {
    remotePoll?.cancel()
    remotePoll = nil
    remoteHost = nil
    startTask?.cancel()
    startTask = nil
    expiryTask?.cancel()
    expiryTask = nil
    lockWatch?.cancel()
    lockWatch = nil
    tunnel?.stop()
    tunnel = nil
    server?.stop()
    server = nil
    pump.stop()
    router.configure(link: nil, enabled: false)
    expiresAt = nil
    localURL = nil
    viewers = 0
    controllerName = nil
    waitingCount = 0
    stats = StreamStats()
  }

  /// While a local share is locked and viewers have control, brings the locked app back to the
  /// front about once a second. Remote shares run this on the remote Mac.
  private func startLockWatch() {
    lockWatch?.cancel()
    lockWatch = nil
    guard lockedApp != nil, remoteHost == nil, server != nil else { return }
    lockWatch = Task { [weak self] in
      while !Task.isCancelled {
        if let self, let app = lockedApp, allowControl, let udid = device?.udid {
          await InstalledApps.bringToFront(app.bundleID, udid: udid)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func viewerSelected(_ udid: String) {
    guard allowSwitching, let next = catalog.device(udid) else { return }
    Task { await switchTo(next) }
  }

  // MARK: - Viewer state

  private func publishState() {
    guard let server, let device, let link = pool.existing(device.udid) else { return }
    let points = link.geometry.points
    let choices = allowSwitching
      ? catalog.booted.map { ViewerState.Choice(udid: $0.udid, name: $0.name, runtime: $0.runtime, symbol: $0.family.symbol) }
      : []
    let state = ViewerState(
      device: .init(udid: device.udid, name: device.name, runtime: device.runtime, symbol: device.family.symbol,
                    width: points.width, height: points.height, cornerRatio: device.cornerRatio),
      expiresAt: (expiresAt ?? Date().addingTimeInterval(options.lifetime)).timeIntervalSince1970 * 1000,
      viewers: viewers,
      controlEnabled: allowControl,
      choices: choices,
      lockedApp: lockedApp?.name
    )
    guard let data = try? JSONEncoder().encode(state) else { return }
    server.publish(state: data)
  }

  /// Called when the simulator list changes so switch choices stay current.
  func catalogChanged() {
    if allowSwitching { publishState() }
  }

  private static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
    return String((0..<20).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
  }

  /// From the app bundle, or next to the `simstream` CLI binary.
  private static let viewerPage: Data = {
    // Resolve symlinks: ~/.local/bin/simstream points into ~/.local/share/simstream, where viewer.html lives.
    let besideBinary = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "viewer.html")
    let candidates = [Bundle.main.url(forResource: "viewer", withExtension: "html"), besideBinary].compactMap { $0 }
    return candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first ?? Data("Viewer page missing.".utf8)
  }()
}

// MARK: - Remote shares

extension ShareSession {
  /// Starts a detached share on a remote Mac. It keeps running if this Mac sleeps or quits;
  /// reopening SimStream picks it up again via `adopt`.
  func startRemote(_ device: SimulatorDevice, on host: RemoteHost) {
    if remoteHost != nil { stopRemote() }
    teardown()
    self.device = device
    phase = .starting("Starting on \(host.name)…")
    let (minutes, quality, control, switching, locked) = (options.lifetime / 60, quality, allowControl, allowSwitching, lockedApp?.bundleID)
    startTask = Task { [weak self] in
      do {
        try await RemoteShell.sync(host)
        let state = try await RemoteShare.start(host, udid: device.udid, minutes: minutes, quality: quality, control: control, switching: switching, lockedApp: locked)
        guard let self, !Task.isCancelled else { return }
        if state.phase == .live {
          adopt(state, device: device, host: host)
        } else {
          phase = .failed(state.message ?? "The share didn't start on \(host.name).")
        }
      } catch {
        self?.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// Shows a share that is already running on a remote Mac and keeps it in sync.
  func adopt(_ state: RemoteShareState, device: SimulatorDevice, host: RemoteHost) {
    remoteHost = host
    self.device = device
    apply(state)
    remotePoll?.cancel()
    remotePoll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, let host = remoteHost else { return }
        // A failed poll (Wi-Fi blip, laptop waking) keeps the last state; the share itself is unaffected.
        if let state = try? await RemoteShare.status(host) { apply(state) }
      }
    }
  }

  private func apply(_ state: RemoteShareState) {
    switch state.phase {
    case .live:
      guard let url = state.url.flatMap(URL.init(string:)) else { return }
      applyingRemote = true
      defer { applyingRemote = false }
      if phase != .live(url) { phase = .live(url) }
      expiresAt = state.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
      viewers = state.viewers
      controllerName = state.holder
      waitingCount = state.waiting
      stats = StreamStats(framesPerSecond: state.fps, bytesPerSecond: state.bytesPerSecond, codec: state.codec)
      inputTransport = state.transport.map { "\($0) on \(remoteHost?.name ?? "remote")" }
      if allowControl != state.allowControl { allowControl = state.allowControl }
      if allowSwitching != state.allowSwitching { allowSwitching = state.allowSwitching }
      if lockedApp != state.lockedApp { lockedApp = state.lockedApp }
      if quality.cliName != state.quality, let match = StreamQuality.allCases.first(where: { $0.cliName == state.quality }) { quality = match }
    case .starting:
      phase = .starting(state.step ?? "Starting…")
    case .ended, .none:
      teardown()
      phase = .ended(state.message == "The link expired." ? .expired : .stopped)
    case .failed:
      teardown()
      phase = .failed(state.message ?? "The share failed.")
    }
  }

  fileprivate func remoteControl(_ command: String) {
    guard let host = remoteHost, !applyingRemote else { return }
    Task {
      await RemoteShare.control(host, command)
      if let state = try? await RemoteShare.status(host) { apply(state) }
    }
  }

  fileprivate func stopRemote() {
    guard let host = remoteHost else { return }
    Task { await RemoteShare.stop(host) }
  }
}
