import Foundation

/// A Cloudflare quick tunnel (`cloudflared tunnel --url`) to a local port.
/// No account needed; the hostname is random and dies with the process.
final class QuickTunnel: @unchecked Sendable { // `process` is only touched from the main actor's calls.
  enum Failure: LocalizedError {
    case notInstalled, noURL

    var errorDescription: String? {
      switch self {
      case .notInstalled: "cloudflared isn't installed. Run `brew install cloudflared`."
      case .noURL: "Cloudflare didn't hand out a tunnel URL. Check your internet connection."
      }
    }
  }

  var onExit: (@Sendable () -> Void)?
  private var process: Process?

  func start(port: UInt16) async throws -> URL {
    guard let cloudflared = Tools.path(of: "cloudflared") else { throw Failure.notInstalled }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cloudflared)
    process.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
    let log = Pipe()
    process.standardError = log
    process.standardOutput = FileHandle.nullDevice
    self.process = process

    let url: URL = try await withCheckedThrowingContinuation { continuation in
      let once = Once()
      // Force-try: the pattern is a constant and known to compile.
      let pattern = try! Regex(#"https://[a-z0-9-]+\.trycloudflare\.com"#)
      let lineBuffer = LineBuffer()
      // Ready once cloudflared has both printed the hostname and registered an edge connection.
      log.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        for line in lineBuffer.lines(appending: chunk) {
          let match = line.firstMatch(of: pattern).flatMap { URL(string: String(line[$0.range])) }
          if let url = lineBuffer.note(url: match, registered: line.contains("Registered tunnel connection")) {
            once.run { continuation.resume(returning: url) }
          }
        }
      }
      process.terminationHandler = { [weak self] _ in
        log.fileHandleForReading.readabilityHandler = nil
        once.run { continuation.resume(throwing: Failure.noURL) }
        self?.onExit?()
      }
      do {
        try process.run()
      } catch {
        once.run { continuation.resume(throwing: error) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        once.run { continuation.resume(throwing: Failure.noURL) }
      }
    }
    return url
  }

  /// Waits until the hostname resolves publicly, asked over DNS-over-HTTPS so this Mac's
  /// resolver never sees the name before it exists. (An early local lookup caches NXDOMAIN,
  /// which would break the link in the host's own browser for many minutes.)
  func waitForDNS(_ url: URL, timeout: Duration = .seconds(30)) async {
    guard let host = url.host(),
          var components = URLComponents(string: "https://cloudflare-dns.com/dns-query") else { return }
    components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
    guard let query = components.url else { return }
    var request = URLRequest(url: query, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
    request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
    struct Answer: Decodable { let Answer: [Record]?; struct Record: Decodable { let data: String } }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !Task.isCancelled {
      if let (data, _) = try? await URLSession.shared.data(for: request),
         let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.Answer?.isEmpty == false {
        return
      }
      try? await Task.sleep(for: .milliseconds(600))
    }
  }

  func stop() {
    onExit = nil
    process?.terminate()
    process = nil
  }
}

private final class LineBuffer: @unchecked Sendable { // `pending` is guarded by `lock`.
  private let lock = NSLock()
  private var pending = ""
  private var url: URL?
  private var registered = false

  /// Records what a log line revealed; returns the URL once the tunnel is usable.
  func note(url: URL?, registered: Bool) -> URL? {
    lock.withLock {
      if self.url == nil { self.url = url }
      self.registered = self.registered || registered
      return self.registered ? self.url : nil
    }
  }

  func lines(appending chunk: Data) -> [String] {
    lock.withLock {
      pending += String(decoding: chunk, as: UTF8.self)
      var parts = pending.components(separatedBy: "\n")
      pending = parts.removeLast()
      return parts
    }
  }
}
