import Foundation
import Observation

struct SimulatorDevice: Identifiable, Hashable, Sendable {
  enum State: String, Sendable {
    case booted = "Booted"
    case booting = "Booting"
    case shutdown = "Shutdown"
    case shuttingDown = "Shutting Down"
    case unknown
  }

  enum Family: Sendable {
    case iPhone, iPad, watch, tv, vision

    var symbol: String {
      switch self {
      case .iPhone: "iphone"
      case .iPad: "ipad"
      case .watch: "applewatch"
      case .tv: "appletv"
      case .vision: "visionpro"
      }
    }
  }

  let udid: String
  let name: String
  /// Display name such as "iOS 27.0".
  let runtime: String
  /// Numeric version used to sort runtimes newest first.
  let runtimeVersion: [Int]
  let state: State
  let family: Family
  /// The RemoteHost this simulator runs on; nil for this Mac.
  var hostID: String?

  var id: String { hostID.map { "\($0)/\(udid)" } ?? udid }
  var isRemote: Bool { hostID != nil }
  var isBooted: Bool { state == .booted }

  /// Screen corner radius as a fraction of screen width, for drawing the stream like the device.
  var cornerRatio: Double {
    switch family {
    case .iPhone: name.contains("SE") ? 0 : 0.13
    case .iPad: 0.03
    case .watch: 0.2
    case .tv, .vision: 0
    }
  }
}

extension SimulatorDevice {
  /// Parses `xcrun simctl list devices -j`. Unavailable devices are dropped.
  static func parseList(_ data: Data) throws -> [SimulatorDevice] {
    struct Listing: Decodable {
      struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let deviceTypeIdentifier: String?
      }
      let devices: [String: [Device]]
    }
    let listing = try JSONDecoder().decode(Listing.self, from: data)
    return listing.devices.flatMap { runtimeID, devices in
      let (runtime, version) = describeRuntime(runtimeID)
      return devices
        .filter { $0.isAvailable ?? true }
        .map { device in
          SimulatorDevice(
            udid: device.udid,
            name: device.name,
            runtime: runtime,
            runtimeVersion: version,
            state: State(rawValue: device.state) ?? .unknown,
            family: family(typeID: device.deviceTypeIdentifier ?? "", runtime: runtime)
          )
        }
    }
  }

  /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → ("iOS 27.0", [27, 0]).
  static func describeRuntime(_ identifier: String) -> (String, [Int]) {
    let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
    var parts = tail.split(separator: "-").map(String.init)
    guard !parts.isEmpty else { return (identifier, []) }
    let platform = parts.removeFirst()
    let version = parts.compactMap(Int.init)
    let name = version.isEmpty ? platform : "\(platform) \(version.map(String.init).joined(separator: "."))"
    return (name, version)
  }

  private static func family(typeID: String, runtime: String) -> Family {
    if typeID.contains("iPad") { return .iPad }
    if typeID.contains("Watch") || runtime.hasPrefix("watchOS") { return .watch }
    if typeID.contains("TV") || runtime.hasPrefix("tvOS") { return .tv }
    if typeID.contains("Vision") || runtime.hasPrefix("xrOS") || runtime.hasPrefix("visionOS") { return .vision }
    return .iPhone
  }
}

/// Live list of installed simulators, refreshed from `simctl` while the app runs.
@MainActor @Observable
final class SimulatorCatalog {
  struct RuntimeGroup: Identifiable {
    let runtime: String
    let devices: [SimulatorDevice]
    var id: String { runtime }
  }

  private(set) var devices: [SimulatorDevice] = []
  private(set) var loadError: String?
  private(set) var transitioning: Set<String> = []
  private var pollTask: Task<Void, Never>?

  var booted: [SimulatorDevice] { devices.filter(\.isBooted) }

  /// Non-booted simulators grouped by runtime, newest runtime first.
  var groups: [RuntimeGroup] {
    Dictionary(grouping: devices.filter { !$0.isBooted }, by: \.runtime)
      .map { RuntimeGroup(runtime: $0.key, devices: $0.value) }
      .sorted { ($0.devices.first?.runtimeVersion ?? []).lexicographicallyPrecedes($1.devices.first?.runtimeVersion ?? []) == false }
  }

  func device(_ udid: String) -> SimulatorDevice? { devices.first { $0.udid == udid } }

  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  func refresh() async {
    do {
      let result = try await ProcessRunner.run(Tools.xcrun, ["simctl", "list", "devices", "available", "-j"])
      let parsed = try SimulatorDevice.parseList(result.output)
      let sorted = parsed.sorted { lhs, rhs in
        if lhs.runtimeVersion != rhs.runtimeVersion { return !lhs.runtimeVersion.lexicographicallyPrecedes(rhs.runtimeVersion) }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      if sorted != devices { devices = sorted }
      loadError = nil
    } catch {
      loadError = "Couldn't list simulators. Check that Xcode is installed and selected."
    }
  }

  func boot(_ device: SimulatorDevice) async {
    await transition(device, ["simctl", "boot", device.udid])
  }

  func shutdown(_ device: SimulatorDevice) async {
    await transition(device, ["simctl", "shutdown", device.udid])
  }

  private func transition(_ device: SimulatorDevice, _ arguments: [String]) async {
    transitioning.insert(device.udid)
    defer { transitioning.remove(device.udid) }
    _ = try? await ProcessRunner.run(Tools.xcrun, arguments)
    await refresh()
  }
}
