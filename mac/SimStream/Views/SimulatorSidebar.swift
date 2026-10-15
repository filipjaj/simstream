import SwiftUI

struct SimulatorSidebar: View {
  @Binding var selection: String?
  @Environment(SimulatorCatalog.self) private var catalog
  @Environment(ShareSession.self) private var session
  @Environment(RemoteCatalog.self) private var remotes
  @State private var query = ""

  var body: some View {
    List(selection: $selection) {
      let running = filter(catalog.booted)
      if !running.isEmpty {
        Section("Running") {
          ForEach(running) { SimulatorRow(device: $0, isShared: isShared($0)) }
        }
      }
      // Remote Macs right under Running: they're what you share, while shut-down local devices are the long tail.
      ForEach(remotes.hosts) { host in
        Section {
          RemoteHostStatus(host: host)
          ForEach(filter(remotes.devices[host.id] ?? [])) { SimulatorRow(device: $0, isShared: isShared($0)) }
        } header: {
          Label(host.name, systemImage: "macmini")
        }
      }
      ForEach(catalog.groups) { group in
        let devices = filter(group.devices)
        if !devices.isEmpty {
          Section(group.runtime) {
            ForEach(devices) { SimulatorRow(device: $0, isShared: false) }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $query, placement: .sidebar, prompt: "Filter Simulators")
    .overlay {
      if let error = catalog.loadError {
        ContentUnavailableView("No Simulators", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if !query.isEmpty, filter(catalog.devices).isEmpty {
        ContentUnavailableView.search(text: query)
      } else if catalog.devices.isEmpty {
        ProgressView()
      }
    }
  }

  private func isShared(_ device: SimulatorDevice) -> Bool {
    session.isActive && session.device?.id == device.id
  }

  private func filter(_ devices: [SimulatorDevice]) -> [SimulatorDevice] {
    guard !query.isEmpty else { return devices }
    return devices.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.runtime.localizedCaseInsensitiveContains(query) }
  }
}

private struct SimulatorRow: View {
  let device: SimulatorDevice
  let isShared: Bool
  @Environment(SimulatorCatalog.self) private var catalog
  @Environment(RemoteCatalog.self) private var remotes
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: device.family.symbol)
        .font(.title3)
        .foregroundStyle(device.isBooted ? .primary : .secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(device.name)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      status
    }
    .padding(.vertical, 2)
    .tag(device.id)
    .contextMenu {
      if device.isBooted {
        Button("Create Share Link") { model.createLink(for: device) }
        if !device.isRemote {
          Divider()
          Button("Shut Down") { Task { await catalog.shutdown(device) } }
        }
      } else {
        Button("Boot") { Task { device.isRemote ? await remotes.boot(device) : await catalog.boot(device) } }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(isShared ? "Sharing" : device.isBooted ? "Running" : "Shut down")
  }

  private var subtitle: String {
    device.isBooted ? device.runtime : "\(device.runtime) · Shut Down"
  }

  @ViewBuilder private var status: some View {
    if isShared {
      Image(systemName: "dot.radiowaves.left.and.right")
        .foregroundStyle(.red)
        .symbolEffect(.variableColor.iterative)
        .help("Sharing now")
    } else if catalog.transitioning.contains(device.udid) || remotes.transitioning.contains(device.id) {
      ProgressView().controlSize(.mini)
    } else if device.isBooted {
      Circle()
        .fill(.green)
        .frame(width: 7, height: 7)
        .help("Running")
    }
  }
}

/// Connection state for a remote Mac's section, shown only when it isn't simply ready.
private struct RemoteHostStatus: View {
  let host: RemoteHost
  @Environment(RemoteCatalog.self) private var remotes

  var body: some View {
    switch remotes.status[host.id] {
    case .connecting, nil:
      HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        Text("Connecting…").foregroundStyle(.secondary)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(message)
    case .ready:
      if remotes.devices[host.id]?.isEmpty ?? true {
        Text("No simulators").foregroundStyle(.secondary)
      }
    }
  }
}
