import CoreVideo
import Darwin
import Foundation
import IOSurface

/// A live connection to one Android device (emulator or real) through scrcpy-server: H.264 from the
/// device's own encoder, decoded here into an IOSurface, plus a control socket for input.
/// If the server drops (screen recorder reset, adb hiccup) the link reconnects and keeps its last frame.
final class AndroidLink: ScreenLink, @unchecked Sendable { // Mutable state is guarded by `lock`.
  enum Failure: LocalizedError {
    case notRunning, noVideo(String)

    var errorDescription: String? {
      switch self {
      case .notRunning: "The device isn't connected."
      case .noVideo(let reason): "The device didn't start streaming. \(reason)"
      }
    }
  }

  let serial: String
  private(set) var input: any InputDriver = NoInputDriver()

  private let lock = NSLock()
  /// The newest decoded frames. Holding a few keeps the decoder's pool from reusing a buffer
  /// that FramePump or the preview is still reading.
  private var frames: [CVPixelBuffer] = []
  private var damage: UInt64 = 0
  private var currentGeometry: ScreenGeometry
  private var connection: ScrcpyConnection?
  private var closed = false
  private let jar: ScrcpyServerJar
  /// Device points per video pixel, from `wm size` / `wm density`.
  private let densityScale: Double
  private let physicalWidth: Int

  var geometry: ScreenGeometry { lock.withLock { currentGeometry } }
  var surface: IOSurface {
    lock.withLock { frames.last.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() } } ?? Self.blank
  }
  var damageSequence: UInt64 { lock.withLock { damage } }
  let reportsDamage = true

  /// The current video size, for touch coordinates.
  var videoSize: (width: Int, height: Int) {
    let geometry = geometry
    return (geometry.pixelWidth, geometry.pixelHeight)
  }

  private init(serial: String, jar: ScrcpyServerJar, densityScale: Double, physicalWidth: Int) {
    self.serial = serial
    self.jar = jar
    self.densityScale = densityScale
    self.physicalWidth = physicalWidth
    currentGeometry = ScreenGeometry(pixelWidth: 1, pixelHeight: 1, scale: 1)
  }

  static func connect(serial: String) async throws -> AndroidLink {
    let jar = try await ScrcpyServerJar.locate()
    let display = try await ADB.shell("wm size; wm density", serial: serial)
    let (width, density) = Self.parseDisplay(display)
    let link = AndroidLink(serial: serial, jar: jar, densityScale: Double(density ?? 160) / 160, physicalWidth: width ?? 0)
    link.input = ScrcpyInputDriver(link: link)
    try await link.open()
    return link
  }

  /// `wm size` / `wm density` print a physical value and, if set, an override; the override wins.
  static func parseDisplay(_ output: String) -> (width: Int?, density: Int?) {
    var width: Int?, density: Int?
    for line in output.split(whereSeparator: \.isNewline) {
      let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
      if line.contains("size:"), let w = value.split(separator: "x").first.flatMap({ Int($0) }) {
        if line.hasPrefix("Override") || width == nil { width = w }
      } else if line.contains("density:"), let d = Int(value) {
        if line.hasPrefix("Override") || density == nil { density = d }
      }
    }
    return (width, density)
  }

  /// Starts scrcpy-server and waits for its first frame. The jar is pushed every time: with
  /// cleanup=true the server deletes it when it exits, so a reconnect would find nothing to run.
  private func open() async throws {
    try await ADB.run(["push", jar.path, ScrcpyConnection.remoteJar], serial: serial).check("adb push")
    let connection = try await ScrcpyConnection.start(serial: serial, jar: jar)
    let first = FirstFrame()
    connection.onSession = { [weak self] width, height in self?.sessionChanged(width: width, height: height) }
    connection.onFrame = { [weak self] buffer in
      self?.received(buffer)
      first.signal()
    }
    connection.onEnd = { [weak self] in self?.connectionEnded() }
    lock.withLock { self.connection = connection }
    connection.startReading()
    guard await first.wait(seconds: 15) else {
      connection.close()
      throw Failure.noVideo(connection.lastServerError ?? "")
    }
  }

  func send(_ message: Data) {
    lock.withLock { connection }?.send(message)
  }

  func close() {
    let connection = lock.withLock { () -> ScrcpyConnection? in
      closed = true
      defer { self.connection = nil }
      return self.connection
    }
    input.close()
    connection?.close()
  }

  private func sessionChanged(width: Int, height: Int) {
    // Points come from the physical width; scale maps them to the (possibly downsized) video.
    let pointsWidth = physicalWidth > 0 ? Double(physicalWidth) / densityScale : Double(width) / densityScale
    let scale = pointsWidth > 0 ? Double(width) / pointsWidth : 1
    lock.withLock { currentGeometry = ScreenGeometry(pixelWidth: width, pixelHeight: height, scale: scale) }
  }

  private func received(_ buffer: CVPixelBuffer) {
    lock.withLock {
      frames.append(buffer)
      if frames.count > 3 { frames.removeFirst() }
      damage &+= 1
    }
  }

  private func connectionEnded() {
    guard !lock.withLock({ closed }) else { return }
    NSLog("SimStream: scrcpy connection to \(serial) ended; reconnecting")
    Task.detached { [weak self] in
      for attempt in 1...5 {
        try? await Task.sleep(for: .seconds(Double(attempt)))
        guard let self, !self.lock.withLock({ self.closed }) else { return }
        do {
          try await self.open()
          return
        } catch {
          NSLog("SimStream: reconnecting to \(self.serial) failed: \(error)")
        }
      }
    }
  }

  /// Shown before the first frame arrives; FramePump never reads it because no damage is reported yet.
  private static let blank: IOSurface = {
    let properties: [IOSurfacePropertyKey: Any] = [ // IOSurface properties are heterogeneous.
      .width: 1, .height: 1, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
    ]
    return IOSurface(properties: properties)!
  }()
}

/// One scrcpy-server process on the device and its two sockets (video, control) over `adb forward`.
final class ScrcpyConnection: @unchecked Sendable { // Callbacks are set before `startReading`; `server` and sockets are guarded by `lock`.
  static let remoteJar = "/data/local/tmp/simstream-scrcpy-server.jar"

  var onSession: ((Int, Int) -> Void)?
  var onFrame: ((CVPixelBuffer) -> Void)?
  var onEnd: (() -> Void)?

  private let serial: String
  private let port: Int
  private let socketName: String
  private let server: Process
  private let serverLog: ServerLog
  private let video: Int32
  private let control: Int32
  private let writeQueue: DispatchQueue
  private let lock = NSLock()
  private var closed = false

  var lastServerError: String? { serverLog.lastError }

  private init(serial: String, port: Int, socketName: String, server: Process, serverLog: ServerLog, video: Int32, control: Int32) {
    self.serial = serial
    self.port = port
    self.socketName = socketName
    self.server = server
    self.video = video
    self.control = control
    writeQueue = DispatchQueue(label: "simstream.scrcpy.control.\(serial)")
    self.serverLog = serverLog
  }

  static func start(serial: String, jar: ScrcpyServerJar) async throws -> ScrcpyConnection {
    let scid = UInt32.random(in: 1..<0x7FFF_FFFF)
    let socketName = String(format: "scrcpy_%08x", scid)
    let forward = try await ADB.run(["forward", "tcp:0", "localabstract:\(socketName)"], serial: serial)
    guard forward.status == 0, let port = Int(String(decoding: forward.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw ADB.Failure.failed("adb forward failed.")
    }

    let log = ServerLog()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: AndroidTools.adb ?? "/usr/bin/false")
    server.arguments = ["-s", serial, "shell", "CLASSPATH=\(remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", jar.version]
      + serverOptions(scid: socketName.dropFirst(7))
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { log.append($0.availableData) }
    try server.run()

    do {
      // adb accepts on the forwarded port even before the server listens, so a connection only
      // counts once the server's dummy byte arrives.
      let video = try await connectWhenReady(port: port, server: server)
      let control = try Socket.connect(port: port)
      // Video socket: codec id, then session and media packets.
      let codec = try Socket.read(video, count: 4).readBigEndian(UInt32.self, at: 0)
      guard codec == ScrcpyProtocol.codecH264 else { throw AndroidLink.Failure.noVideo("Unexpected codec \(String(codec, radix: 16)).") }
      return ScrcpyConnection(serial: serial, port: port, socketName: socketName, server: server, serverLog: log, video: video, control: control)
    } catch {
      server.terminate()
      _ = try? await ADB.run(["forward", "--remove", "tcp:\(port)"], serial: serial)
      if let reason = log.lastError { throw AndroidLink.Failure.noVideo(reason) }
      throw error
    }
  }

  /// Options for scrcpy-server (see Options.java). Capture stays in the device's natural orientation,
  /// like a simulator framebuffer, so the stream size and touch mapping never change on rotation.
  static func serverOptions(scid: Substring) -> [String] {
    ["scid=\(scid)", "log_level=warn", "tunnel_forward=true", "audio=false", "control=true", "cleanup=true",
     "video_codec=h264", "max_size=1920", "max_fps=60", "video_bit_rate=8000000", "capture_orientation=@0",
     "send_device_meta=false", "clipboard_autosync=false", "stay_awake=true", "power_on=true"]
  }

  private static func connectWhenReady(port: Int, server: Process) async throws -> Int32 {
    for _ in 0..<100 {
      guard server.isRunning else { break }
      if let socket = try? Socket.connect(port: port) {
        if (try? Socket.read(socket, count: 1)) != nil { return socket }
        Darwin.close(socket)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AndroidLink.Failure.noVideo("scrcpy-server didn't start.")
  }

  func startReading() {
    let thread = Thread { [self] in readLoop() }
    thread.name = "simstream.scrcpy.video.\(serial)"
    thread.qualityOfService = .userInteractive
    thread.start()
    // Device messages (clipboard, acks) aren't used, but the socket is drained so it never fills.
    let drain = Thread { [control] in while (try? Socket.read(control, count: 1)) != nil {} }
    drain.start()
  }

  private func readLoop() {
    let decoder = H264Decoder()
    decoder.onFrame = { [weak self] in self?.onFrame?($0) }
    do {
      while true {
        switch ScrcpyProtocol.parseHeader(try Socket.read(video, count: ScrcpyProtocol.headerSize)) {
        case .session(let width, let height):
          onSession?(width, height)
        case .media(let size, let isConfig, _, _):
          let packet = try Socket.read(video, count: size)
          do { try decoder.decode(packet, isConfig: isConfig) } catch { NSLog("SimStream: H.264 decoder: \(error)") }
        case nil:
          throw Socket.Failure.closed
        }
      }
    } catch {
      decoder.invalidate()
      let wasOpen = lock.withLock { () -> Bool in
        defer { closed = true }
        return !closed
      }
      teardown()
      if wasOpen { onEnd?() }
    }
  }

  func send(_ message: Data) {
    writeQueue.async { [self] in
      guard !lock.withLock({ closed }) else { return }
      try? Socket.write(control, message)
    }
  }

  func close() {
    lock.withLock { closed = true }
    teardown()
  }

  private func teardown() {
    // Closing the sockets ends the server (cleanup=true restores settings it changed).
    shutdown(video, SHUT_RDWR)
    shutdown(control, SHUT_RDWR)
    writeQueue.async { [video, control] in
      Darwin.close(video)
      Darwin.close(control)
    }
    if server.isRunning { server.terminate() }
    let (serial, port) = (serial, port)
    Task.detached { _ = try? await ADB.run(["forward", "--remove", "tcp:\(port)"], serial: serial) }
  }
}

/// Keeps scrcpy-server's output for error messages ("Could not find an encoder", version mismatch).
private final class ServerLog: @unchecked Sendable { // `text` is guarded by `lock`.
  private let lock = NSLock()
  private var text = ""

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.withLock {
      text += String(decoding: data, as: UTF8.self)
      if text.count > 8_000 { text = String(text.suffix(4_000)) }
    }
  }

  var lastError: String? {
    lock.withLock {
      text.split(whereSeparator: \.isNewline).last { $0.localizedCaseInsensitiveContains("error") || $0.contains("Exception") }.map(String.init)
    }
  }
}

/// Resolved once by whichever comes first: the first frame, or the timeout.
private final class FirstFrame: @unchecked Sendable { // `continuation` and `done` are guarded by `lock`.
  private let lock = NSLock()
  private var done = false
  private var continuation: CheckedContinuation<Bool, Never>?

  func signal() { finish(true) }

  func wait(seconds: Double) async -> Bool {
    await withCheckedContinuation { continuation in
      let finished = lock.withLock { () -> Bool in
        if done { return true }
        self.continuation = continuation
        return false
      }
      if finished { return continuation.resume(returning: true) }
      Task.detached { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        self?.finish(false)
      }
    }
  }

  private func finish(_ value: Bool) {
    let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard !done else { return nil }
      done = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(returning: value)
  }
}

/// Blocking TCP helpers for the two loopback sockets.
enum Socket {
  enum Failure: Error { case connect(Int32), closed }

  static func connect(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.connect(errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else {
      let error = errno
      Darwin.close(fd)
      throw Failure.connect(error)
    }
    return fd
  }

  static func read(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
      if n <= 0 {
        if n < 0, errno == EINTR { continue }
        throw Failure.closed
      }
      offset += n
    }
    return data
  }

  static func write(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
      if n <= 0 {
        if n < 0, errno == EINTR { continue }
        throw Failure.closed
      }
      offset += n
    }
  }
}

extension ProcessRunner.Result {
  func check(_ what: String) throws {
    guard status == 0 else { throw ADB.Failure.failed("\(what) failed (status \(status)).") }
  }
}

/// Placeholder until the link has a driver; never used after `connect` returns.
private struct NoInputDriver: InputDriver {
  let name = "None"
  func send(_ event: InputEvent) {}
  func discardPending() {}
  func close() {}
}
