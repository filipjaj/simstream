import CoreImage.CIFilterBuiltins
import SwiftUI

struct ShareInspector: View {
  let device: SimulatorDevice?
  @Environment(AppModel.self) private var model
  @Environment(ShareSession.self) private var session

  var body: some View {
    @Bindable var session = session
    Form {
      if let device, session.device?.id == device.id, case .live(let url) = session.phase {
        LiveShareSections(url: url)
      } else if let device, session.device?.id == device.id, case .starting(let step) = session.phase {
        Section {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(step)
          }
          .padding(.vertical, 4)
          Button("Cancel", role: .cancel) { session.stop() }
        } header: {
          Text("Creating Link")
        }
      } else {
        NewShareSections(device: device)
      }

      Section("Stream") {
        Toggle("Viewers can control", isOn: $session.allowControl)
        Toggle("Viewers can switch simulators", isOn: $session.allowSwitching)
        Picker("Quality", selection: $session.quality) {
          ForEach(StreamQuality.allCases) { Text($0.title).tag($0) }
        }
        // Remote shares can't be extended while this Mac sleeps, so pick the length up front.
        Picker("Link lasts", selection: $session.options.lifetime) {
          Text("15 minutes").tag(TimeInterval(15 * 60))
          Text("30 minutes").tag(TimeInterval(30 * 60))
          Text("1 hour").tag(TimeInterval(60 * 60))
          Text("2 hours").tag(TimeInterval(2 * 60 * 60))
          Text("4 hours").tag(TimeInterval(4 * 60 * 60))
        }
        .disabled(session.isActive)
      }
    }
    .formStyle(.grouped)
    .animation(.default, value: session.phase)
  }
}

private struct NewShareSections: View {
  let device: SimulatorDevice?
  @Environment(AppModel.self) private var model
  @Environment(ShareSession.self) private var session

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "link.badge.plus")
          .font(.system(size: 28, weight: .regular))
          .foregroundStyle(.tint)
        Text(title)
          .font(.headline)
        Text("Anyone with the link can watch and control this simulator in a browser, until the link expires.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 4)

      if case .failed(let message) = session.phase, session.device?.id == device?.id {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
      } else if case .ended(.expired) = session.phase, session.device?.id == device?.id {
        Label("The last link expired.", systemImage: "clock.badge.xmark")
          .foregroundStyle(.secondary)
          .font(.callout)
      }

      Button {
        if let device { model.createLink(for: device) }
      } label: {
        Text(buttonTitle).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(device?.isBooted != true)
      .keyboardShortcut(.defaultAction)
    }
  }

  private var title: String {
    guard let device else { return "Share a Simulator" }
    return "Share \(device.name)"
  }

  private var buttonTitle: String {
    if device?.isBooted != true { return "Boot to Share" }
    if session.isActive { return "Move Link to This Simulator" }
    return "Create Link"
  }
}

private struct LiveShareSections: View {
  let url: URL
  @Environment(ShareSession.self) private var session
  @State private var copied = false
  /// The QR can open the browser viewer (works for everyone) or the SimStream iOS app.
  @AppStorage("qrOpensApp") private var qrOpensApp = false

  private var qrText: String {
    guard qrOpensApp, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    components.scheme = "simstream"
    return components.string ?? url.absoluteString
  }

  var body: some View {
    Section {
      HStack {
        LiveBadge()
        Spacer()
        Label("\(session.viewers) watching", systemImage: "person.2.fill")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      }

      Picker("QR code opens", selection: $qrOpensApp) {
        Text("Browser").tag(false)
        Text("iOS App").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      QRCode(text: qrText)
        .frame(width: 172, height: 172)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel("QR code for the share link")

      Text(url.absoluteString)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .lineLimit(3)
        .foregroundStyle(.secondary)

      HStack {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
          copied = true
        } label: {
          Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
            .frame(maxWidth: .infinity)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
          .labelStyle(.iconOnly)
          .help("Share link")
      }
      .controlSize(.large)
      .task(id: copied) {
        guard copied else { return }
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
    }

    Section("Expires") {
      if let expiresAt = session.expiresAt {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(0, expiresAt.timeIntervalSince(context.date))
          VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Time left") {
              Text(Duration.seconds(remaining.rounded()), format: .time(pattern: .minuteSecond))
                .monospacedDigit()
                .foregroundStyle(remaining < 60 ? .red : .primary)
            }
            ProgressView(value: remaining, total: max(remaining, session.options.lifetime))
              .tint(remaining < 60 ? .red : .accentColor)
          }
        }
      }
      Button("Add 15 Minutes", systemImage: "plus.circle") { session.extend() }
    }

    Section("Control") {
      LabeledContent("In control", value: session.controllerName ?? "Nobody")
      LabeledContent("Waiting", value: "\(session.waitingCount)")
      Button("Pass to Next in Line", systemImage: "arrow.right.circle") { session.passControl() }
        .disabled(session.controllerName == nil)
    }

    Section("Connection") {
      LabeledContent("Frame rate", value: session.stats.codec.isEmpty ? "\(session.stats.framesPerSecond) fps" : "\(session.stats.framesPerSecond) fps · \(session.stats.codec)")
      LabeledContent("Bandwidth", value: Int64(session.stats.bytesPerSecond).formatted(.byteCount(style: .binary, spellsOutZero: false)) + "/s")
      if let transport = session.inputTransport {
        LabeledContent("Input", value: transport)
      }
    }

    Section {
      Button("Stop Sharing", role: .destructive) { session.stop() }
        .frame(maxWidth: .infinity)
    }
  }
}

struct LiveBadge: View {
  var body: some View {
    Text("LIVE")
      .font(.caption.weight(.bold))
      .tracking(0.6)
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.red, in: .capsule)
      .accessibilityLabel("Live")
  }
}

struct QRCode: View {
  let text: String

  var body: some View {
    if let image = Self.render(text) {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .padding(10)
        .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
    }
  }

  private static func render(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}
