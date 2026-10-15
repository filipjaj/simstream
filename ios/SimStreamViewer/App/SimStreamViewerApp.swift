import SwiftUI

@main
struct SimStreamViewerApp: App {
  @State private var recents = RecentLinks()
  @State private var session: StreamSession?

  var body: some Scene {
    WindowGroup {
      ConnectView(recents: recents, open: open)
        .fullScreenCover(item: $session) { session in
          StreamScreen(session: session, recents: recents) { self.session = nil }
        }
        .onOpenURL { url in
          if let link = StreamLink(url.absoluteString) { open(link) }
        }
        #if DEBUG
        // `-openLink <url>` launch argument: opens a share without the system's open-in-app prompt,
        // which simulator automation can't tap.
        .task {
          if let raw = UserDefaults.standard.string(forKey: "openLink"), let link = StreamLink(raw) { open(link) }
        }
        #endif
    }
  }

  private func open(_ link: StreamLink) {
    session?.stop()
    recents.opened(link)
    session = StreamSession(link: link)
  }
}

extension StreamSession: Identifiable {}
