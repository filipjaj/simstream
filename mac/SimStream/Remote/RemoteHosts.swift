import Foundation
import Observation

/// A Mac reachable over SSH (key auth, no prompts) that runs simulators, such as the home Mac mini.
struct RemoteHost: Identifiable, Hashable, Codable, Sendable {
  var id = UUID()
  var name: String
  /// Host alias or user@host, exactly as `ssh` takes it.
  var sshHost: String
}

/// SSH plumbing shared by listing, syncing and sharing. One multiplexed connection per host,
/// so the 10-second list poll costs a few milliseconds instead of a handshake.
enum RemoteShell {
  static let ssh = "/usr/bin/ssh"
  static let rsync = "/usr/bin/rsync"
  static let options = [
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
    "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/simstream-ssh-%C", "-o", "ControlPersist=120",
  ]
  /// Where the CLI lives on the remote, relative to its home directory.
  static let bundlePath = ".local/share/simstream"
  /// Remote command prefix: cloudflared is in Homebrew, AXe (fallback input) may be in ~/.local/bin.
  static let environment = "PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH"

  /// The CLI bundle shipped inside the app (binary, viewer.html, Frameworks).
  static var localBundle: URL? {
    let url = Bundle.main.resourceURL?.appending(path: "simstream")
    return url.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "simstream").path) ? $0 : nil }
  }

  static func run(_ host: RemoteHost, _ command: String) async throws -> ProcessRunner.Result {
    try await ProcessRunner.run(ssh, options + [host.sshHost, command])
  }

  static func sync(_ host: RemoteHost) async throws {
    guard let bundle = localBundle else { throw RemoteError.cliMissing }
    _ = try await run(host, "mkdir -p \(bundlePath)")
    let shell = ([ssh] + options).joined(separator: " ")
    let result = try await ProcessRunner.run(rsync, ["-a", "--delete", "-e", shell, bundle.path + "/", "\(host.sshHost):\(bundlePath)/"])
    guard result.status == 0 else { throw RemoteError.syncFailed }
  }
}

enum RemoteError: LocalizedError {
  case cliMissing, syncFailed, unreachable, badListing, startFailed

  var errorDescription: String? {
    switch self {
    case .cliMissing: "This build of SimStream doesn't include the simstream CLI."
    case .syncFailed: "Couldn't copy simstream to the remote Mac."
    case .unreachable: "Can't reach this Mac over SSH."
    case .badListing: "The remote Mac sent an unreadable simulator list."
    case .startFailed: "The remote Mac couldn't start the share."
    }
  }
}

/// Simulators on remote Macs, refreshed every 10 seconds over SSH.
@MainActor @Observable
final class RemoteCatalog {
  enum Status: Equatable {
    case connecting
    case ready
    case failed(String)
  }

  private(set) var hosts: [RemoteHost] = []
  private(set) var devices: [UUID: [SimulatorDevice]] = [:]
  private(set) var status: [UUID: Status] = [:]
  private(set) var transitioning: Set<String> = []
  /// Called on each poll that finds a live share running on a host.
  var onLiveShare: ((RemoteHost, RemoteShareState) -> Void)?
  private var synced: Set<UUID> = []
  private var pollTask: Task<Void, Never>?
  private static let storageKey = "remoteHosts"

  init() {
    hosts = Self.load()
  }

  func device(id: String) -> SimulatorDevice? {
    devices.values.lazy.flatMap { $0 }.first { $0.id == id }
  }

  func host(for device: SimulatorDevice) -> RemoteHost? {
    hosts.first { $0.id.uuidString == device.hostID }
  }

  func add(_ host: RemoteHost) {
    hosts.append(host)
    save()
    Task { await refresh(host) }
  }

  func remove(_ host: RemoteHost) {
    hosts.removeAll { $0.id == host.id }
    devices[host.id] = nil
    status[host.id] = nil
    synced.remove(host.id)
    save()
  }

  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await withTaskGroup(of: Void.self) { group in
          for host in self.hosts { group.addTask { await self.refresh(host) } }
        }
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func refresh(_ host: RemoteHost) async {
    if devices[host.id] == nil { status[host.id] = .connecting }
    do {
      if !synced.contains(host.id) {
        try await RemoteShell.sync(host)
        synced.insert(host.id)
      }
      let result = try await RemoteShell.run(host, "\(RemoteShell.environment) \(RemoteShell.bundlePath)/simstream list --json")
      guard result.status == 0 else { throw result.status == 255 ? RemoteError.unreachable : RemoteError.badListing }
      let parsed = try Self.parse(result.output, hostID: host.id.uuidString)
      if devices[host.id] != parsed { devices[host.id] = parsed }
      status[host.id] = .ready
      if let share = try? await RemoteShare.status(host), share.phase == .live { onLiveShare?(host, share) }
    } catch {
      status[host.id] = .failed(error.localizedDescription)
    }
  }

  func boot(_ device: SimulatorDevice) async {
    guard let host = host(for: device) else { return }
    transitioning.insert(device.id)
    defer { transitioning.remove(device.id) }
    _ = try? await RemoteShell.run(host, "xcrun simctl bootstatus \(device.udid) -b >/dev/null")
    await refresh(host)
  }

  /// Parses `simstream list --json`: booted first, then newest runtime, then name.
  static func parse(_ data: Data, hostID: String) throws -> [SimulatorDevice] {
    struct Row: Decodable {
      let udid: String
      let name: String
      let runtime: String
      let runtimeVersion: [Int]
      let family: String
      let booted: Bool
      /// Absent from CLIs older than Android support.
      let platform: SimulatorDevice.Platform?
      let physical: Bool?
    }
    let rows = try JSONDecoder().decode([Row].self, from: data)
    let families: [String: SimulatorDevice.Family] = ["iphone": .iPhone, "ipad": .iPad, "applewatch": .watch, "appletv": .tv, "visionpro": .vision,
                                                       "smartphone": .androidPhone, "rectangle.portrait": .androidTablet]
    return rows.map {
      SimulatorDevice(udid: $0.udid, name: $0.name, runtime: $0.runtime, runtimeVersion: $0.runtimeVersion,
                      state: $0.booted ? .booted : .shutdown, family: families[$0.family] ?? .iPhone, hostID: hostID,
                      platform: $0.platform ?? .iOS, isPhysical: $0.physical ?? false)
    }
    .sorted { lhs, rhs in
      if lhs.isBooted != rhs.isBooted { return lhs.isBooted }
      if lhs.runtimeVersion != rhs.runtimeVersion { return !lhs.runtimeVersion.lexicographicallyPrecedes(rhs.runtimeVersion) }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
  }

  /// Saved hosts; none until the user adds one in Settings.
  private static func load() -> [RemoteHost] {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
    return (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
  }
}
