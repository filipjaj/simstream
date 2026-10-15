import CoreImage
import Foundation
import IOSurface
import ImageIO

enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
  case dataSaver, balanced, sharp

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dataSaver: "Data Saver"
    case .balanced: "Balanced"
    case .sharp: "Sharp"
    }
  }

  /// Output pixels per screen point. The simulator renders at 2–3×.
  var pointScale: Double {
    switch self {
    case .dataSaver: 1
    case .balanced: 1.5
    case .sharp: 2
    }
  }

  var jpegQuality: Double {
    switch self {
    case .dataSaver: 0.5
    case .balanced: 0.62
    case .sharp: 0.75
    }
  }

  var framesPerSecond: Int {
    switch self {
    case .dataSaver: 24
    case .balanced: 30
    case .sharp: 60
    }
  }

  var h264Bitrate: Int {
    switch self {
    case .dataSaver: 1_000_000
    case .balanced: 2_500_000
    case .sharp: 6_000_000
    }
  }
}

extension StreamQuality {
  /// The `--quality` value the simstream CLI takes.
  var cliName: String {
    switch self {
    case .dataSaver: "data-saver"
    case .balanced: "balanced"
    case .sharp: "sharp"
    }
  }
}

struct StreamStats: Equatable, Sendable {
  var framesPerSecond = 0
  var bytesPerSecond = 0
  var codec = ""
}

/// Which encodings current viewers want.
struct StreamDemand: Equatable, Sendable {
  var jpeg = false
  var h264 = false

  var isEmpty: Bool { !jpeg && !h264 }
}

/// Encodes the simulator surface when it changes: H.264 for WebCodecs viewers, JPEG for the rest.
/// Both run on the GPU (~2–6 ms a frame), so a 60 fps stream costs a fraction of one core.
final class FramePump: @unchecked Sendable { // All mutable state is confined to `queue`.
  var onJPEG: (@Sendable (Data) -> Void)?
  var onH264: (@Sendable (H264Frame, H264Config) -> Void)?
  var onStats: (@Sendable (StreamStats) -> Void)?
  var demand: (@Sendable () -> StreamDemand)?

  private let queue = DispatchQueue(label: "simstream.encode", qos: .userInteractive)
  private let context = CIContext(options: [.cacheIntermediates: false, .name: "SimStream"])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private var timer: DispatchSourceTimer?
  private var link: SimulatorLink?
  private var quality = StreamQuality.balanced
  private var encoder: H264Encoder?
  private var tickCount = 0
  private var lastSequence: UInt64 = .max
  private var lastChange: UInt64 = 0
  private var refinedAfterChange = false
  private var lastJPEGSequence: UInt64 = .max
  private var lastJPEGEncode: UInt64 = 0
  private var lastJPEG: Data?
  private var windowStart: UInt64 = 0
  private var windowFrames = 0
  private var windowBytes = 0
  private var windowCodec = ""
  private let statsLock = NSLock()
  private var pendingH264Bytes = 0
  private var pendingH264Frames = 0

  /// The most recent JPEG, so a viewer who joins on a still screen sees something at once.
  var latestJPEG: Data? { queue.sync { lastJPEG } }

  func start(link: SimulatorLink, quality: StreamQuality) {
    queue.async { [self] in
      self.link = link
      self.quality = quality
      reset()
    }
  }

  func setQuality(_ quality: StreamQuality) {
    queue.async { [self] in
      guard self.quality != quality else { return }
      self.quality = quality
      reset()
    }
  }

  func requestKeyframe() {
    queue.async { [self] in
      encoder?.requestKeyframe()
      lastSequence = .max
    }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
      link = nil
      lastJPEG = nil
      encoder?.invalidate()
      encoder = nil
    }
  }

  private func reset() {
    lastSequence = .max
    lastJPEGSequence = .max
    lastJPEG = nil
    encoder?.invalidate()
    encoder = nil
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    timer.schedule(deadline: .now(), repeating: 1.0 / Double(quality.framesPerSecond), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
  }

  private func tick() {
    let now = DispatchTime.now().uptimeNanoseconds
    tickCount &+= 1
    reportStats(now: now)
    guard let link else { return }
    let demand = demand?() ?? StreamDemand()
    if !demand.h264, encoder != nil {
      encoder?.invalidate()
      encoder = nil
    }
    guard !demand.isEmpty else { return }

    let sequence = link.damageSequence
    // Without damage reports (some runtimes), treat every tick as a change.
    let changed = !link.reportsDamage || sequence != lastSequence
    if changed {
      lastSequence = sequence
      lastChange = now
      refinedAfterChange = false
    }

    if demand.h264 {
      // Once motion stops, encode the still frame once more so the encoder can sharpen it.
      let refine = !changed && !refinedAfterChange && now &- lastChange > 250_000_000
      if refine { refinedAfterChange = true }
      if changed || refine, let encoder = ensureEncoder(link.geometry) {
        encoder.encode(link.surface)
      }
    }

    // JPEG tops out at 30 fps; above that it costs more bandwidth than it's worth.
    if demand.jpeg, quality.framesPerSecond <= 30 || tickCount % 2 == 0 {
      encodeJPEG(link: link, now: now)
    }
  }

  private func ensureEncoder(_ geometry: ScreenGeometry) -> H264Encoder? {
    if let encoder { return encoder }
    let size = outputSize(geometry)
    do {
      let encoder = try H264Encoder(width: size.width, height: size.height, bitrate: quality.h264Bitrate,
                                    framesPerSecond: quality.framesPerSecond)
      encoder.onFrame = { [weak self] frame, config in
        guard let self else { return }
        self.statsLock.withLock {
          self.pendingH264Frames += 1
          self.pendingH264Bytes += frame.data.count
        }
        onH264?(frame, config)
      }
      self.encoder = encoder
      return encoder
    } catch {
      NSLog("SimStream: H.264 encoder unavailable: \(error)")
      return nil
    }
  }

  private func encodeJPEG(link: SimulatorLink, now: UInt64) {
    let sequence = link.damageSequence
    let stale = now &- lastJPEGEncode > 1_000_000_000
    if link.reportsDamage, sequence == lastJPEGSequence, !stale, lastJPEG != nil { return }
    lastJPEGSequence = sequence
    lastJPEGEncode = now

    var image = CIImage(ioSurface: link.surface)
    let factor = min(1, quality.pointScale / link.geometry.scale)
    if factor < 0.999 {
      image = image.samplingLinear().transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }
    let option = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
    guard let frame = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [option: quality.jpegQuality]),
          frame != lastJPEG else { return }
    lastJPEG = frame
    windowFrames += 1
    windowBytes += frame.count
    windowCodec = "JPEG"
    onJPEG?(frame)
  }

  private func outputSize(_ geometry: ScreenGeometry) -> (width: Int, height: Int) {
    let factor = min(1, quality.pointScale / geometry.scale)
    return (Int((Double(geometry.pixelWidth) * factor).rounded()), Int((Double(geometry.pixelHeight) * factor).rounded()))
  }

  private func reportStats(now: UInt64) {
    if windowStart == 0 { windowStart = now }
    guard now &- windowStart >= 1_000_000_000 else { return }
    let (h264Frames, h264Bytes) = statsLock.withLock { () -> (Int, Int) in
      defer { self.pendingH264Frames = 0; self.pendingH264Bytes = 0 }
      return (self.pendingH264Frames, self.pendingH264Bytes)
    }
    let codecs = [h264Frames > 0 ? "H.264" : nil, windowFrames > 0 ? windowCodec : nil].compactMap { $0 }
    onStats?(StreamStats(framesPerSecond: max(h264Frames, windowFrames), bytesPerSecond: h264Bytes + windowBytes,
                         codec: codecs.joined(separator: " + ")))
    windowStart = now
    windowFrames = 0
    windowBytes = 0
  }
}
