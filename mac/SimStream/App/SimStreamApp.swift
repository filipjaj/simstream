import AppKit
import SwiftUI

@main
struct SimStreamApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let model = AppModel.shared

  var body: some Scene {
    Window("SimStream", id: "main") {
      ContentView()
        .environment(model)
        .environment(model.catalog)
        .environment(model.remotes)
        .environment(model.session)
    }
    .defaultSize(width: 1100, height: 780)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .newItem) {
        ShareCommands(model: model)
      }
    }

    Settings {
      RemoteHostsSettings()
        .environment(model.remotes)
    }

    MenuBarExtra(isInserted: Binding(get: { model.session.isActive }, set: { _ in })) {
      MenuBarContent()
        .environment(model)
        .environment(model.session)
    } label: {
      Image(systemName: "dot.radiowaves.left.and.right")
        .accessibilityLabel("SimStream is sharing a simulator")
    }
  }
}

/// App-wide state: the simulator list, open connections and the share.
@MainActor @Observable
final class AppModel {
  static let shared = AppModel()

  let catalog = SimulatorCatalog()
  let remotes = RemoteCatalog()
  let lockMemory = LockMemory()
  let pool = LinkPool()
  let session: ShareSession
  var selection: String?
  /// A real phone waiting for the host to confirm sharing it.
  var physicalShareToConfirm: SimulatorDevice?

  private init() {
    session = ShareSession(pool: pool, catalog: catalog)
    catalog.startPolling()
    remotes.startPolling()
    observeCatalog()
    resumeRemoteShares()
    shareFromLaunchArguments()
  }

  /// `SimStream --share <udid>` creates a link right away and prints it, for scripting.
  private func shareFromLaunchArguments() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let flag = arguments.firstIndex(of: "--share"), arguments.indices.contains(flag + 1) else { return }
    let udid = arguments[flag + 1]
    selection = udid
    Task {
      await catalog.refresh()
      guard let device = catalog.device(udid), device.isBooted else {
        print("SimStream: \(udid) isn't a booted simulator")
        return
      }
      session.start(device)
      while session.isActive, session.url == nil { try? await Task.sleep(for: .milliseconds(200)) }
      if let url = session.url { print("Public: \(url.absoluteString)") } else { print("SimStream: \(session.phase)") }
      fflush(stdout)
    }
  }

  var selectedDevice: SimulatorDevice? {
    selection.flatMap { catalog.device($0) ?? remotes.device(id: $0) }
  }

  func createLink(for device: SimulatorDevice, confirmed: Bool = false) {
    // A real phone holds someone's accounts and messages; never share one without asking.
    if device.isPhysical, !confirmed {
      physicalShareToConfirm = device
      return
    }
    session.lockedApp = lockMemory.app(for: device.udid)
    if device.isRemote, let host = remotes.host(for: device) {
      session.startRemote(device, on: host)
    } else if session.isActive, session.remoteHost == nil, session.device?.id != device.id {
      Task { await session.switchTo(device) }
    } else {
      session.start(device)
    }
  }

  /// Quitting ends a share from this Mac. Remote shares keep running on their Mac.
  func shutdown() {
    if session.remoteHost == nil { session.stop() }
    pool.closeAll()
  }

  /// A share running on a remote Mac (started before this Mac slept, or from the CLI over SSH) shows up
  /// in the app on the next poll, as long as the app isn't already sharing something.
  private func resumeRemoteShares() {
    remotes.onLiveShare = { [weak self] host, state in
      guard let self, !session.isActive, let udid = state.udid else { return }
      let device = remotes.devices[host.id]?.first { $0.udid == udid }
        ?? SimulatorDevice(udid: udid, name: state.deviceName ?? "Simulator", runtime: "", runtimeVersion: [],
                           state: .booted, family: .iPhone, hostID: host.id.uuidString)
      session.adopt(state, device: device, host: host)
      if selection == nil || selectedDevice?.isRemote == false { selection = device.id }
    }
  }

  private func catalogDidChange() {
    let booted = Set(catalog.booted.map(\.udid))
    if session.remoteHost == nil, let shared = session.device?.udid, !booted.contains(shared) { session.stop() }
    pool.prune(keeping: booted)
    if selection == nil { selection = catalog.booted.first?.udid ?? catalog.devices.first?.udid }
    session.catalogChanged()
    observeCatalog()
  }

  private func observeCatalog() {
    withObservationTracking {
      _ = catalog.devices
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.catalogDidChange()
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { AppModel.shared.shutdown() }
  }
}

private struct ShareCommands: View {
  let model: AppModel

  var body: some View {
    Button("Create Share Link") {
      if let device = model.selectedDevice { model.createLink(for: device) }
    }
    .keyboardShortcut("l", modifiers: [.command, .shift])
    .disabled(model.selectedDevice?.isBooted != true)

    Button("Stop Sharing") { model.session.stop() }
      .keyboardShortcut(".", modifiers: [.command])
      .disabled(!model.session.isActive)
  }
}
