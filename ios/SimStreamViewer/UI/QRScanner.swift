import AVFoundation
import SwiftUI
import VisionKit

/// Full-screen camera that connects the moment it sees a SimStream QR code. Other QR codes get
/// highlighted and explained instead of silently ignored, so a wrong code isn't mistaken for a broken camera.
struct QRScannerSheet: View {
  let found: (StreamLink) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var rejected = false
  /// Nil until the camera permission question is settled.
  @State private var cameraReady: Bool?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if cameraReady == nil {
        ProgressView()
      } else if cameraReady == true {
        QRScannerView { payload in
          if let link = StreamLink(payload) {
            found(link)
          } else if !rejected {
            withAnimation(.snappy) { rejected = true }
          }
        }
        .ignoresSafeArea()
        Viewfinder()
      } else {
        ContentUnavailableView {
          Label("Camera Unavailable", systemImage: "camera.slash")
        } description: {
          Text("Allow camera access for SimStream in Settings, or paste the link instead.")
        } actions: {
          if let settings = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: settings)
              .buttonStyle(.glass)
          }
        }
      }
    }
    .overlay(alignment: .top) {
      HStack {
        Button("Close", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.large)
        Spacer()
      }
      .padding(20)
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 4) {
        Text(rejected ? "Not a SimStream code" : "Scan the QR code")
          .font(.headline)
        Text(rejected ? "Look for the code in the Share panel on the Mac." : "It's in SimStream's Share panel on the Mac.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .glassEffect(in: .rect(cornerRadius: 24, style: .continuous))
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      .contentTransition(.opacity)
    }
    .preferredColorScheme(.dark)
    .task {
      if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
      }
      cameraReady = DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
    .sensoryFeedback(.error, trigger: rejected) { _, new in new }
  }
}

/// Corner brackets that frame where to aim. Purely a hint: the scanner reads codes anywhere in view.
private struct Viewfinder: View {
  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height) * 0.62
      RoundedRectangle(cornerRadius: 36, style: .continuous)
        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [side * 0.18, side * 0.82],
                                                        dashPhase: side * 0.09))
        .frame(width: side, height: side)
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct QRScannerView: UIViewControllerRepresentable {
  let onPayload: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .fast,
      recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    context.coordinator.onPayload = onPayload
    if !scanner.isScanning { try? scanner.startScanning() }
  }

  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
    scanner.stopScanning()
  }

  func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    var onPayload: (String) -> Void

    init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      for case .barcode(let code) in items {
        if let payload = code.payloadStringValue { onPayload(payload) }
      }
    }
  }
}

#Preview {
  QRScannerSheet { _ in }
}
