import SwiftUI

/// Home screen. Scanning the Mac's QR code is the main path; pasting or typing the link are the fallbacks.
/// Links still live sit up top, since reopening one is the most common thing after the first time.
struct ConnectView: View {
  let recents: RecentLinks
  let open: (StreamLink) -> Void

  @State private var scanning = false
  @State private var typing = false
  @State private var typed = ""
  @State private var invalidLink = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 36) {
          Hero()
          if !liveRecents.isEmpty {
            RecentSection(entries: liveRecents, open: open, remove: recents.remove)
          } else {
            HowItWorks()
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(Background())
      .safeAreaInset(edge: .bottom) { actions }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Enter Link", systemImage: "link") { typing = true }
        }
      }
      .onAppear { recents.prune() }
      .fullScreenCover(isPresented: $scanning) {
        QRScannerSheet { link in
          scanning = false
          open(link)
        }
      }
      .alert("Enter Link", isPresented: $typing) {
        TextField("https://…trycloudflare.com/…", text: $typed)
          .textContentType(.URL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Cancel", role: .cancel) { typed = "" }
        Button("Connect") { submit(typed) }
      } message: {
        Text("The link SimStream shows when you share a simulator.")
      }
      .alert("Not a SimStream Link", isPresented: $invalidLink) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("A share link looks like https://name.trycloudflare.com/abc123/. Copy it again from the Mac.")
      }
    }
  }

  private var actions: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(spacing: 12) {
        Button { scanning = true } label: {
          Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)

        PasteButton(payloadType: String.self) { strings in
          if let first = strings.first { submit(first) }
        }
        .buttonBorderShape(.capsule)
        .tint(.secondary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .frame(maxWidth: 560)
  }

  private var liveRecents: [RecentLinks.Entry] {
    recents.entries.filter { $0.isLive(at: .now) }
  }

  private func submit(_ raw: String) {
    typed = ""
    guard let link = StreamLink(raw) else {
      invalidLink = true
      return
    }
    open(link)
  }
}

private struct Hero: View {
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "iphone.gen3.radiowaves.left.and.right")
        .font(.system(size: 52, weight: .regular))
        .foregroundStyle(.tint)
        .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeat(.periodic(delay: 2)))
        .frame(width: 112, height: 112)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .circle)
        .accessibilityHidden(true)
      VStack(spacing: 8) {
        Text("SimStream")
          .font(.largeTitle.bold())
        Text("Use a simulator from your Mac on this iPhone, as if the app were installed here.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.top, 12)
  }
}

private struct HowItWorks: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Step(number: 1, symbol: "macbook", text: "Open SimStream on your Mac and share a simulator.")
      Step(number: 2, symbol: "qrcode", text: "Scan the QR code in the Share panel.")
      Step(number: 3, symbol: "hand.tap", text: "Tap, scroll, pinch and type as if the app runs here. Shake for Home and Lock.")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
  }

  private struct Step: View {
    let number: Int
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 14) {
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(.tint)
          .frame(width: 30)
        Text(text)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("Step \(number). \(Text(text))"))
    }
  }
}

private struct RecentSection: View {
  let entries: [RecentLinks.Entry]
  let open: (StreamLink) -> Void
  let remove: (RecentLinks.Entry) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Still Sharing")
        .font(.title3.bold())
        .padding(.leading, 4)
      VStack(spacing: 0) {
        ForEach(entries) { entry in
          Button { open(entry.link) } label: { RecentRow(entry: entry) }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
            }
          if entry != entries.last {
            Divider().padding(.leading, 70)
          }
        }
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
    }
  }
}

private struct RecentRow: View {
  let entry: RecentLinks.Entry

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "iphone.gen3")
        .font(.title2)
        .foregroundStyle(.white)
        .frame(width: 42, height: 42)
        .background(.tint, in: .rect(cornerRadius: 11, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.deviceName ?? entry.link.host)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Group {
          if let expiresAt = entry.expiresAt {
            Text("\(entry.runtime ?? "Simulator") · \(expiresAt, style: .timer) left")
          } else {
            Text(entry.link.host)
          }
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contentShape(.rect)
  }
}

/// A soft wash of the tint behind the hero, so the screen has a sense of place without a picture.
private struct Background: View {
  var body: some View {
    LinearGradient(colors: [Color.accentColor.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
      .background(Color(.systemGroupedBackground))
      .ignoresSafeArea()
  }
}

#Preview("First run") {
  ConnectView(recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-empty")!)) { _ in }
}

#Preview("With live links") {
  let defaults = UserDefaults(suiteName: "preview-recents")!
  let recents = RecentLinks(defaults: defaults)
  let link = StreamLink("https://quiet-river.trycloudflare.com/k3x9/")!
  recents.opened(link)
  recents.update(link, with: .preview)
  recents.opened(StreamLink("https://bright-hill.trycloudflare.com/p2m7/")!)
  return ConnectView(recents: recents) { _ in }
}

#Preview("Dark") {
  ConnectView(recents: RecentLinks(defaults: UserDefaults(suiteName: "preview-empty")!)) { _ in }
    .preferredColorScheme(.dark)
}
