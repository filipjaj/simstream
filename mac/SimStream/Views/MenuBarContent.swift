import SwiftUI

struct MenuBarContent: View {
  @Environment(ShareSession.self) private var session
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if let device = session.device {
      Text("Sharing \(device.name)")
    }
    if let expiresAt = session.expiresAt {
      Text("Expires at \(expiresAt.formatted(date: .omitted, time: .shortened))")
    }
    Text(session.viewers == 1 ? "1 viewer" : "\(session.viewers) viewers")
    Divider()
    if let url = session.url {
      Button("Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
      }
      Button("Add 15 Minutes") { session.extend() }
    }
    Button("Stop Sharing") { session.stop() }
    Divider()
    Button("Show SimStream") {
      openWindow(id: "main")
      NSApp.activate()
    }
  }
}
