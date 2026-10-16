import Foundation

/// An app a share can be locked to.
struct LockedApp: Codable, Hashable, Sendable, Identifiable {
  let bundleID: String
  let name: String

  var id: String { bundleID }

  /// Bundle IDs (and Android package names) travel inside SSH and adb shell command lines, so only
  /// these characters are accepted.
  static func isValidBundleID(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
  }
}

/// The app each simulator was last locked to, so a new link starts locked the same way.
/// Choosing "Any App" forgets it.
@MainActor @Observable
final class LockMemory {
  private static let key = "lockedApps"
  private let defaults: UserDefaults
  private var apps: [String: LockedApp]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    apps = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: LockedApp].self, from: $0) } ?? [:]
  }

  func app(for udid: String) -> LockedApp? { apps[udid] }

  func remember(_ app: LockedApp?, for udid: String) {
    guard apps[udid] != app else { return }
    apps[udid] = app
    if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Self.key) }
  }
}

/// User-installed apps on a simulator (`simctl listapps`) or Android device (`pm list packages -3`).
enum InstalledApps {
  static func list(device: SimulatorDevice) async -> [LockedApp] {
    guard device.platform == .android else { return await list(udid: device.udid) }
    guard let serial = device.adbSerial, let output = try? await ADB.shell("pm list packages -3", serial: serial) else { return [] }
    return parsePackages(output)
  }

  /// `pm list packages` prints "package:<name>" lines. Android has no cheap way to read app labels
  /// in bulk, so the package name doubles as the display name.
  static func parsePackages(_ output: String) -> [LockedApp] {
    output.split(whereSeparator: \.isNewline)
      .compactMap { line -> LockedApp? in
        guard line.hasPrefix("package:") else { return nil }
        let name = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
        return LockedApp.isValidBundleID(name) ? LockedApp(bundleID: name, name: name) : nil
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func list(udid: String) async -> [LockedApp] {
    guard let result = try? await ProcessRunner.run(Tools.xcrun, ["simctl", "listapps", udid]), result.status == 0 else { return [] }
    return parse(result.output)
  }

  /// `simctl listapps` prints an old-style plist keyed by bundle ID.
  static func parse(_ data: Data) -> [LockedApp] {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return [] } // Plist values are heterogeneous.
    return plist.compactMap { bundleID, info in
      guard info["ApplicationType"] as? String == "User" else { return nil }
      let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
      return LockedApp(bundleID: bundleID, name: name)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Brings the app to the front, launching it if it isn't running. A running app keeps its
  /// process and state. Costs ~0.25 s when the app is already in front.
  @discardableResult
  static func bringToFront(_ bundleID: String, udid: String) async -> Bool {
    (try? await ProcessRunner.run(Tools.xcrun, ["simctl", "launch", udid, bundleID]))?.status == 0
  }

  @discardableResult
  static func bringToFront(_ bundleID: String, device: SimulatorDevice) async -> Bool {
    guard device.platform == .android else { return await bringToFront(bundleID, udid: device.udid) }
    guard let serial = device.adbSerial, LockedApp.isValidBundleID(bundleID) else { return false }
    // Starting the launcher activity with NEW_TASK resumes the app's existing task, so a running
    // app keeps its state; when it's already in front, am only prints a warning.
    let script = "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "
      + "$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(bundleID) | tail -n 1)"
    return (try? await ADB.shell(script, serial: serial)) != nil
  }
}

/// Keeps a viewer inside the locked app by dropping the input that opens system UI: hardware
/// buttons and drags that start on the top or bottom edge (Home, the app switcher, Control
/// Centre, Notification Centre). Taps on those edges still go through. Anything that gets
/// past this, like a link that opens Safari, is undone by bringing the app back to the front.
///
/// Edges are in the simulator's portrait framebuffer, so in landscape only the bring-back covers
/// the home gesture.
struct EdgeGuard: Equatable, Sendable {
  /// Fractions of the screen height. The bottom band covers the home indicator, the top band the status bar.
  static let topBand = 0.06
  static let bottomBand = 0.05
  /// How far a finger that started on an edge may move and still count as a tap.
  static let slop = 0.015
  /// Fraction of the screen width on each side where Android's back gesture starts.
  static let sideBand = 0.04

  /// Also guards the left and right edges (Android's back gesture).
  var guardsSides = false

  init(guardsSides: Bool = false) {
    self.guardsSides = guardsSides
  }

  private enum Gesture: Equatable, Sendable {
    case none
    /// Started on an edge; held back until it ends as a tap or turns into a drag.
    case held(x: Double, y: Double)
    case blocked
  }

  private var gesture = Gesture.none

  static func onEdge(_ y: Double) -> Bool { y < topBand || y > 1 - bottomBand }

  private func onEdge(x: Double, y: Double) -> Bool {
    Self.onEdge(y) || (guardsSides && (x < Self.sideBand || x > 1 - Self.sideBand))
  }

  /// The events to forward in place of `event`.
  mutating func filter(_ event: InputEvent) -> [InputEvent] {
    switch event {
    case .button:
      return []
    case .text, .key:
      return [event]
    case .touch(let phase, let x, let y):
      return touch(phase, x: x, y: y, event: event)
    case .twoFingers(let phase, let a, let b):
      switch (phase, gesture) {
      case (.down, .none):
        if onEdge(x: a.x, y: a.y) || onEdge(x: b.x, y: b.y) { gesture = .blocked; return [] }
        return [event]
      case (.up, .blocked):
        gesture = .none
        return []
      case (_, .blocked), (_, .held):
        return []
      default:
        return [event]
      }
    }
  }

  private mutating func touch(_ phase: TouchPhase, x: Double, y: Double, event: InputEvent) -> [InputEvent] {
    switch (phase, gesture) {
    case (.down, .none):
      guard onEdge(x: x, y: y) else { return [event] }
      gesture = .held(x: x, y: y)
      return []
    case (.down, _), (.move, .held):
      // SimulatorKit moves a finger with repeated downs, so treat both as movement.
      guard case .held(let x0, let y0) = gesture else { return [] }
      if hypot(x - x0, y - y0) > Self.slop { gesture = .blocked }
      return []
    case (.move, .blocked):
      return []
    case (.up, .held(let x0, let y0)):
      gesture = .none
      return [.touch(.down, x: x0, y: y0), .touch(.up, x: x0, y: y0)]
    case (.up, .blocked):
      gesture = .none
      return []
    default:
      return [event]
    }
  }
}
