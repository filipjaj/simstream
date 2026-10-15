import CoreGraphics
import FBControlCore
import FBSimulatorControl
import Foundation
import IOSurface

struct ScreenGeometry: Equatable, Sendable {
  let pixelWidth: Int
  let pixelHeight: Int
  let scale: Double

  var points: CGSize { CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale) }
}

/// A live connection to one booted simulator: its framebuffer surface and an input driver.
/// Opening one costs ~150 ms; it is kept for as long as the simulator is previewed or shared.
final class SimulatorLink: @unchecked Sendable { // Mutable state is guarded by `lock`.
  enum Failure: LocalizedError {
    case notFound, noScreen

    var errorDescription: String? {
      switch self {
      case .notFound: "The simulator isn't running."
      case .noScreen: "The simulator has no screen to stream."
      }
    }
  }

  let udid: String
  let geometry: ScreenGeometry
  let input: any InputDriver

  private let framebuffer: FBFramebuffer
  private let observer: FramebufferObserver
  private let lock = NSLock()
  private var currentSurface: IOSurface
  private var damage: UInt64 = 0
  private var damageReported = false

  var surface: IOSurface { lock.withLock { currentSurface } }
  /// Increments whenever the simulator reports a redrawn region.
  var damageSequence: UInt64 { lock.withLock { damage } }
  /// Some runtimes never report damage; consumers then poll the surface instead.
  var reportsDamage: Bool { lock.withLock { damageReported } }

  private init(udid: String, geometry: ScreenGeometry, framebuffer: FBFramebuffer, input: any InputDriver) throws {
    self.udid = udid
    self.geometry = geometry
    self.framebuffer = framebuffer
    self.input = input
    observer = FramebufferObserver()
    guard let surface = framebuffer.attach(observer, on: DispatchQueue(label: "simstream.framebuffer.\(udid)")) else {
      throw Failure.noScreen
    }
    currentSurface = surface
    observer.onSurface = { [weak self] surface in
      guard let self, let surface else { return }
      self.lock.withLock { self.currentSurface = surface; self.damage &+= 1 }
    }
    observer.onDamage = { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.damage &+= 1; self.damageReported = true }
    }
  }

  static func connect(udid: String) async throws -> SimulatorLink {
    let logger = FBControlCoreGlobalConfiguration.defaultLogger
    guard let simulator = try SimulatorControl.simulator(udid: udid) else { throw Failure.notFound }
    guard let info = simulator.screenInfo else { throw Failure.noScreen }
    let geometry = ScreenGeometry(pixelWidth: Int(info.widthPixels), pixelHeight: Int(info.heightPixels), scale: Double(info.scale))
    let framebuffer = try FBFramebuffer.mainScreenSurface(for: simulator, logger: logger)

    let input: any InputDriver
    do {
      input = HIDInputDriver(hid: try await connectHID(simulator), udid: udid, points: geometry.points)
    } catch {
      NSLog("SimStream: direct HID unavailable (\(error)); falling back to AXe CLI")
      guard let fallback = AXeCLIInputDriver(udid: udid, points: geometry.points) else { throw error }
      input = fallback
    }
    return try SimulatorLink(udid: udid, geometry: geometry, framebuffer: framebuffer, input: input)
  }

  /// Prefers the DTUHID transport (Xcode 26+), then whatever FBSimulatorControl picks.
  private static func connectHID(_ simulator: FBSimulator) async throws -> FBSimulatorHID {
    do {
      return try FBSimulatorHID(for: simulator, transport: .dtuhid)
    } catch {
      NSLog("SimStream: DTUHID transport unavailable (\(error)); trying the default")
      return try await simulator.connectToHID()
    }
  }

  func close() {
    framebuffer.detach(observer)
    input.close()
  }
}

private final class FramebufferObserver: NSObject, FBFramebufferConsumer {
  var onSurface: ((IOSurface?) -> Void)?
  var onDamage: (() -> Void)?

  func didChange(_ surface: IOSurface?) { onSurface?(surface) }
  func didReceiveDamageRect() { onDamage?() }
}

/// One FBSimulatorControl per process; its simulator set tracks devices booted later.
private enum SimulatorControl {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var control: FBSimulatorControl? // Guarded by `lock`.

  static func simulator(udid: String) throws -> FBSimulator? {
    try lock.withLock {
      // Loads CoreSimulator and SimulatorKit from the selected Xcode before any HID or framebuffer call.
      try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(FBControlCoreGlobalConfiguration.defaultLogger)
      if let found = control?.set.simulator(withUDID: udid) { return found }
      // A device booted after the set was created can be missing; rebuild once.
      let configuration = FBSimulatorControlConfiguration(deviceSetPath: nil, logger: FBControlCoreGlobalConfiguration.defaultLogger, reporter: nil)
      let fresh = try FBSimulatorControl.withConfiguration(configuration)
      control = fresh
      return fresh.set.simulator(withUDID: udid)
    }
  }
}

/// Keeps one link per simulator so the preview and a share reuse the same connection.
@MainActor
final class LinkPool {
  private var links: [String: SimulatorLink] = [:]
  private var pending: [String: Task<SimulatorLink, Error>] = [:]

  func link(for udid: String) async throws -> SimulatorLink {
    if let link = links[udid] { return link }
    if let task = pending[udid] { return try await task.value }
    let task = Task.detached { try await SimulatorLink.connect(udid: udid) }
    pending[udid] = task
    defer { pending[udid] = nil }
    let link = try await task.value
    links[udid] = link
    return link
  }

  func existing(_ udid: String) -> SimulatorLink? { links[udid] }

  /// Drops links for simulators that are no longer booted.
  func prune(keeping booted: Set<String>) {
    for (udid, link) in links where !booted.contains(udid) {
      link.close()
      links[udid] = nil
    }
  }

  func closeAll() {
    links.values.forEach { $0.close() }
    links.removeAll()
  }
}
