import SwiftUI

/// Hardware buttons and session info, in a glass bar that appears on shake.
struct ControlBar: View {
  let session: StreamSession
  @Binding var showsKeyboard: Bool
  let close: () -> Void
  let dismiss: () -> Void

  var body: some View {
    GlassEffectContainer {
      VStack(spacing: 10) {
        header
        HStack(spacing: 8) {
          // The Mac drops hardware buttons while the share is locked to one app.
          if session.state?.lockedApp == nil {
            control("Home", systemImage: "house") { session.press(.home) }
            control("Lock", systemImage: "lock") { session.press(.lock) }
          }
          Toggle(isOn: $showsKeyboard) {
            Label("Keyboard", systemImage: "keyboard")
          }
          .toggleStyle(.button)
          .labelStyle(.iconOnly)
          .frame(maxWidth: .infinity, minHeight: 44)
          .disabled(!session.canControl)
          .accessibilityHint("Shows this device's keyboard and types into the simulator")
          control("Hide Controls", systemImage: "chevron.down", enabled: true, action: dismiss)
        }
        .buttonStyle(.plain)
        .font(.title3)
      }
      .padding(14)
      .glassEffect(in: .rect(cornerRadius: 28, style: .continuous))
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(session.state?.device.name ?? "Simulator")
          .font(.headline)
        HStack(spacing: 6) {
          if let latency = session.latency {
            Text("\(Int(latency.rounded())) ms")
              .foregroundStyle(latency < 90 ? .green : latency < 220 ? .yellow : .red)
          }
          if let expiry = session.state?.expiryDate {
            Text("Ends \(expiry, style: .relative)")
          }
          if session.state?.controlEnabled == false {
            Text("View only")
          }
          if let app = session.state?.lockedApp {
            Label(app, systemImage: "lock.fill")
              .accessibilityLabel("Locked to \(app)")
          }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Disconnect", role: .destructive, action: close)
        .buttonStyle(.glass)
        .controlSize(.small)
    }
  }

  private func control(_ title: LocalizedStringKey, systemImage: String, enabled: Bool? = nil,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(.rect)
    }
    .disabled(!(enabled ?? session.canControl))
  }
}

#Preview {
  ZStack(alignment: .bottom) {
    Color.indigo.ignoresSafeArea()
    ControlBar(session: StreamSession(preview: .live, state: .preview, latency: 62),
               showsKeyboard: .constant(false), close: {}, dismiss: {})
      .padding()
  }
  .preferredColorScheme(.dark)
}
