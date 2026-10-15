import AppKit
import SwiftUI
import WebKit

struct SimulatorDetail: View {
  let device: SimulatorDevice?
  @Environment(SimulatorCatalog.self) private var catalog

  var body: some View {
    Group {
      if let device {
        if device.isRemote {
          RemoteDetail(device: device)
        } else if device.isBooted {
          LivePreview(device: device)
            .id(device.udid)
        } else {
          ContentUnavailableView {
            Label(device.name, systemImage: device.family.symbol)
          } description: {
            Text("\(device.runtime) · Shut Down")
          } actions: {
            if catalog.transitioning.contains(device.udid) {
              ProgressView("Booting…").controlSize(.small)
            } else {
              Button("Boot Simulator") { Task { await catalog.boot(device) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
          }
        }
      } else {
        ContentUnavailableView("No Simulator Selected", systemImage: "iphone", description: Text("Choose a simulator in the sidebar."))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background.secondary)
    .navigationTitle(device?.name ?? "SimStream")
    .navigationSubtitle(device?.runtime ?? "")
  }
}

private struct LivePreview: View {
  let device: SimulatorDevice
  @Environment(AppModel.self) private var model
  @Environment(ShareSession.self) private var session
  @State private var link: SimulatorLink?
  @State private var error: String?

  var body: some View {
    ZStack {
      if let link {
        let aspect = link.geometry.points.width / link.geometry.points.height
        GeometryReader { proxy in
          let size = fit(aspect: aspect, in: proxy.size)
          SurfaceView(link: link)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: size.width * device.cornerRatio, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: size.width * device.cornerRatio, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(32)
        .accessibilityLabel("\(device.name) screen")
      } else if let error {
        ContentUnavailableView("Can't Connect", systemImage: "bolt.horizontal.circle", description: Text(error))
      } else {
        ProgressView("Connecting…").controlSize(.small)
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button { link?.input.send(.button(.home)) } label: { Label("Home", systemImage: "house") }
          .help("Home")
        Button { link?.input.send(.button(.lock)) } label: { Label("Lock", systemImage: "lock") }
          .help("Lock")
      }
    }
    .task {
      do {
        link = try await model.pool.link(for: device.udid)
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  private func fit(aspect: Double, in bounds: CGSize) -> CGSize {
    guard bounds.width > 0, bounds.height > 0 else { return .zero }
    return bounds.width / bounds.height > aspect
      ? CGSize(width: bounds.height * aspect, height: bounds.height)
      : CGSize(width: bounds.width, height: bounds.width / aspect)
  }
}

/// Shows the simulator's IOSurface directly in a layer: no copies, no encoding.
struct SurfaceView: NSViewRepresentable {
  let link: SimulatorLink

  func makeNSView(context: Context) -> SurfaceLayerView {
    let view = SurfaceLayerView()
    view.link = link
    return view
  }

  func updateNSView(_ view: SurfaceLayerView, context: Context) {
    if view.link !== link { view.link = link }
  }
}

final class SurfaceLayerView: NSView {
  var link: SimulatorLink? {
    didSet { refresh(force: true) }
  }

  private var displayLink: CADisplayLink?
  private var lastSequence: UInt64 = .max

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.contentsGravity = .resizeAspect
    layer?.backgroundColor = NSColor.black.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    displayLink?.invalidate()
    displayLink = nil
    guard window != nil else { return }
    let displayLink = displayLink(target: self, selector: #selector(step))
    displayLink.add(to: .main, forMode: .common)
    self.displayLink = displayLink
  }

  @objc private func step(_ link: CADisplayLink) {
    refresh(force: false)
  }

  private func refresh(force: Bool) {
    guard let link else { return }
    let sequence = link.damageSequence
    if !force, link.reportsDamage, sequence == lastSequence { return }
    lastSequence = sequence
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Reassigning the same IOSurface is ignored; clearing first makes the layer re-read it.
    layer?.contents = nil
    layer?.contents = link.surface
    CATransaction.commit()
  }
}

/// A simulator on another Mac. There's no local surface to show, so once the share is live
/// this embeds the web viewer itself: watching and controlling work exactly as for guests.
private struct RemoteDetail: View {
  let device: SimulatorDevice
  @Environment(ShareSession.self) private var session
  @Environment(RemoteCatalog.self) private var remotes

  var body: some View {
    let hostName = remotes.host(for: device)?.name ?? "the remote Mac"
    if session.device?.id == device.id, let url = session.url {
      WebViewer(url: url)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .padding(20)
    } else {
      ContentUnavailableView {
        Label(device.name, systemImage: device.family.symbol)
      } description: {
        Text(device.isBooted
             ? "Running on \(hostName). Create a link to watch and control it here. The link stays live on \(hostName) when this Mac sleeps or quits."
             : "Shut down on \(hostName).")
      } actions: {
        if remotes.transitioning.contains(device.id) {
          ProgressView("Booting…").controlSize(.small)
        } else if !device.isBooted {
          Button("Boot on \(hostName)") { Task { await remotes.boot(device) } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
      }
    }
  }
}

struct WebViewer: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    view.underPageBackgroundColor = .black
    view.load(URLRequest(url: url))
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    if view.url?.host() != url.host() || view.url?.path() != url.path() { view.load(URLRequest(url: url)) }
  }
}
