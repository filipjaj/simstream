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
