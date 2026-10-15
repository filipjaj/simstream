import Foundation

/// Runs command-line tools without blocking the caller's thread.
enum ProcessRunner {
  struct Result: Sendable {
    let status: Int32
    let output: Data
  }

  enum Failure: LocalizedError {
    case toolMissing(String)
    case failed(String, status: Int32)

    var errorDescription: String? {
      switch self {
      case .toolMissing(let name): "\(name) is not installed."
      case .failed(let name, let status): "\(name) exited with status \(status)."
      }
    }
  }

  static func run(_ executable: String, _ arguments: [String], input: Data? = nil) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let stdout = Pipe()
      process.standardOutput = stdout
      process.standardError = FileHandle.nullDevice
      let stdin = input.map { _ in Pipe() }
      if let stdin { process.standardInput = stdin }

      // Drain stdout concurrently so a large listing can't fill the pipe and stall the child.
      let collected = OutputBuffer()
      stdout.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { collected.append(chunk) }
      }
      process.terminationHandler = { finished in
        stdout.fileHandleForReading.readabilityHandler = nil
        collected.append(stdout.fileHandleForReading.readDataToEndOfFile())
        continuation.resume(returning: Result(status: finished.terminationStatus, output: collected.data))
      }
      do {
        try process.run()
        if let stdin, let input {
          stdin.fileHandleForWriting.write(input)
          try? stdin.fileHandleForWriting.close()
        }
      } catch {
        stdout.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}

private final class OutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
  var data: Data { lock.withLock { storage } }
}

/// Locates Homebrew-installed tools; apps launched from Finder don't inherit the shell PATH.
enum Tools {
  static func path(of name: String) -> String? {
    let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] + envPaths
    return candidates
      .map { "\($0)/\(name)" }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static let xcrun = "/usr/bin/xcrun"
}
