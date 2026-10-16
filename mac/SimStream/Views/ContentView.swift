import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(ShareSession.self) private var session
  @State private var showsInspector = true

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      SimulatorSidebar(selection: $model.selection)
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
    } detail: {
      SimulatorDetail(device: model.selectedDevice)
    }
    .inspector(isPresented: $showsInspector) {
      ShareInspector(device: model.selectedDevice)
        .inspectorColumnWidth(min: 290, ideal: 310, max: 380)
    }
    .confirmationDialog(
      "Share a real phone?",
      isPresented: Binding(get: { model.physicalShareToConfirm != nil }, set: { if !$0 { model.physicalShareToConfirm = nil } }),
      presenting: model.physicalShareToConfirm
    ) { device in
      Button("Create Link") { model.createLink(for: device, confirmed: true) }
      Button("Cancel", role: .cancel) {}
    } message: { device in
      Text("\(device.name) is a real device, not an emulator. Anyone with the link can see its screen\(session.allowControl ? " and use it: messages, email, accounts and settings included" : ""). Lock the share to one app or turn off control to limit this.")
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showsInspector.toggle()
        } label: {
          Label("Share", systemImage: session.isActive ? "dot.radiowaves.left.and.right" : "square.and.arrow.up")
            .symbolEffect(.variableColor.iterative, isActive: session.url != nil)
        }
        .help(showsInspector ? "Hide sharing" : "Show sharing")
      }
    }
  }
}
