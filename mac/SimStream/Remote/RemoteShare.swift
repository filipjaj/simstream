import Foundation

/// State of the background share on a remote Mac, as printed by `simstream status --json`.
struct RemoteShareState: Decodable, Equatable, Sendable {
  enum Phase: String, Decodable, Sendable { case starting, live, ended, failed, none }

  var phase: Phase
  var step: String?
  var udid: String?
  var deviceName: String?
  var url: String?
  /// Milliseconds since 1970.
  var expiresAt: Double?
  var viewers = 0
  var holder: String?
  var waiting = 0
  var fps = 0
  var bytesPerSecond = 0
  var codec = ""
  var transport: String?
  var message: String?
  var allowControl = true
  var allowSwitching = false
  var quality = "balanced"
  var lockedApp: LockedApp?
}

/// Drives the detached `simstream` share on a remote Mac with short SSH calls. The share runs
/// on the remote in its own session, so it stays live when this Mac sleeps, closes or quits.
enum RemoteShare {
  static func start(_ host: RemoteHost, udid: String, minutes: Double, quality: StreamQuality,
                    control: Bool, switching: Bool, lockedApp: String?, physical: Bool = false) async throws -> RemoteShareState {
    var arguments = ["start", "--json", "--udid", udid, "--minutes", String(Int(minutes)), "--quality", quality.cliName]
    if !control { arguments.append("--view-only") }
    if switching { arguments.append("--allow-switching") }
    // The host picked a real phone in the app, past its warning.
    if physical { arguments.append("--allow-physical") }
    if let lockedApp, LockedApp.isValidBundleID(lockedApp) { arguments += ["--lock-app", lockedApp] }
    let result = try await RemoteShell.run(host, cli(arguments))
    if let state = try? JSONDecoder().decode(RemoteShareState.self, from: result.output) { return state }
    throw result.status == 255 ? RemoteError.unreachable : RemoteError.startFailed
  }

  static func status(_ host: RemoteHost) async throws -> RemoteShareState {
    let result = try await RemoteShell.run(host, cli(["status", "--json"]))
    guard result.status == 0 else { throw RemoteError.unreachable }
    return try JSONDecoder().decode(RemoteShareState.self, from: result.output)
  }

  static func control(_ host: RemoteHost, _ command: String) async {
    _ = try? await RemoteShell.run(host, cli(["ctl"] + command.split(separator: " ").map(String.init)))
  }

  /// User apps on a simulator of the remote Mac, for the lock picker.
  static func apps(_ host: RemoteHost, udid: String) async -> [LockedApp] {
    guard let result = try? await RemoteShell.run(host, cli(["apps", "--json", "--udid", udid])), result.status == 0 else { return [] }
    return (try? JSONDecoder().decode([LockedApp].self, from: result.output)) ?? []
  }

  static func stop(_ host: RemoteHost) async {
    _ = try? await RemoteShell.run(host, cli(["stop"]))
  }

  private static func cli(_ arguments: [String]) -> String {
    "\(RemoteShell.environment) \(RemoteShell.bundlePath)/simstream " + arguments.joined(separator: " ")
  }
}
