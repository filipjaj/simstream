import SwiftUI

/// The simulator, full screen, with this device's own chrome out of the way: no status bar, no home
/// indicator, edge swipes deferred so the simulator's own Home and Control Center gestures win.
struct StreamScreen: View {
  let session: StreamSession
  let recents: RecentLinks
  let close: () -> Void

  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("shakeHintsShown") private var shakeHintsShown = 0
  @State private var showsControls = false
  @State private var showsKeyboard = false
  @State private var showsHint = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      StreamSurface(session: session, showsKeyboard: showsKeyboard) {
        withAnimation(.snappy) { showsControls.toggle() }
      }
      .ignoresSafeArea(.container)

      if session.phase != .live {
        StatusOverlay(phase: session.phase, deviceName: session.state?.device.name, close: close)
          .transition(.opacity)
      }
    }
    .overlay(alignment: .top) {
      VStack(spacing: 8) {
        ControlStatusPill(session: session)
        if showsHint {
        Label("Shake for controls", systemImage: "iphone.radiowaves.left.and.right")
          .font(.subheadline.weight(.medium))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .glassEffect()
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .animation(.snappy, value: session.role)
    }
    .overlay(alignment: .bottom) {
      if showsControls || session.phase == .live && session.state?.controlEnabled == false {
        ControlBar(session: session, showsKeyboard: $showsKeyboard, close: close) {
          withAnimation(.snappy) { showsControls = false }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.smooth, value: session.phase)
    .sensoryFeedback(.warning, trigger: session.deniedCount)
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .defersSystemGestures(on: .all)
    .preferredColorScheme(.dark)
    .onAppear { session.start() }
    .onDisappear { session.stop() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { session.start() } else if phase == .background { session.stop() }
    }
    .onChange(of: session.state) { _, state in
      if let state { recents.update(session.link, with: state) }
    }
    .onChange(of: session.phase) { _, phase in
      if phase == .live { showHintIfNeeded() }
      if phase == .expired { showsKeyboard = false }
    }
  }

  /// The first few sessions teach the gesture, then it stays out of the way.
  private func showHintIfNeeded() {
    guard shakeHintsShown < 3, !showsHint else { return }
    shakeHintsShown += 1
    withAnimation(.snappy) { showsHint = true }
    Task {
      try? await Task.sleep(for: .seconds(3))
      withAnimation(.smooth) { showsHint = false }
    }
  }
}

private struct StatusOverlay: View {
  let phase: StreamSession.Phase
  let deviceName: String?
  let close: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      switch phase {
      case .connecting, .live:
        ProgressView().controlSize(.large)
        Text(deviceName.map { "Connecting to \($0)" } ?? "Connecting")
          .font(.headline)
      case .reconnecting(let attempt):
        ProgressView().controlSize(.large)
        VStack(spacing: 6) {
          Text("Reconnecting").font(.headline)
          if attempt > 3 {
            Text("The Mac isn't responding. Check that it's awake and still sharing.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      case .expired:
        ContentUnavailableView {
          Label("Sharing Ended", systemImage: "iphone.slash")
        } description: {
          Text("The link expired or the Mac stopped sharing. Ask for a new link to keep going.")
        } actions: {
          Button("Done", action: close)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
      }
    }
    .multilineTextAlignment(.center)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.6))
    .overlay(alignment: .topLeading) {
      if phase != .expired {
        Button("Close", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly)
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.large)
          .padding(20)
      }
    }
  }
}

#Preview("Live") {
  StreamScreen(session: StreamSession(preview: .live, state: .preview, latency: 48),
               recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-stream")!)) {}
}

#Preview("Connecting") {
  StreamScreen(session: StreamSession(preview: .connecting, state: nil),
               recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-stream")!)) {}
}

#Preview("Reconnecting") {
  StreamScreen(session: StreamSession(preview: .reconnecting(attempt: 5), state: .preview),
               recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-stream")!)) {}
}

#Preview("Expired") {
  StreamScreen(session: StreamSession(preview: .expired, state: .preview),
               recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-stream")!)) {}
}
