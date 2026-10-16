import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes scrcpy's Annex B H.264 into IOSurface-backed BGRA buffers, the same kind of surface a
/// simulator framebuffer is, so everything downstream (preview, FramePump) treats both alike.
/// Not thread-safe: one reader thread feeds it.
final class H264Decoder {
  enum Failure: Error {
    case format(OSStatus), session(OSStatus), sample(OSStatus)
  }

  /// Called on the decoding thread with every decoded frame.
  var onFrame: ((CVPixelBuffer) -> Void)?

  private var format: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var parameterSets: [Data] = []

  /// Feeds one packet: a config packet (SPS/PPS) or a frame. Frames that arrive before the first
  /// config packet, or fail to decode, are dropped; the next keyframe recovers.
  func decode(_ packet: Data, isConfig: Bool) throws {
    var units = ScrcpyProtocol.nalUnits(packet)
    let sets = units.filter { [7, 8].contains(ScrcpyProtocol.nalType($0)) }
    if isConfig || !sets.isEmpty {
      try configure(sets)
      units.removeAll { [7, 8].contains(ScrcpyProtocol.nalType($0)) }
    }
    guard !units.isEmpty, let format, let session else { return }
    let sample = try makeSample(ScrcpyProtocol.avcc(units), format: format)
    var flags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags) { [weak self] status, _, image, _, _ in
      guard status == noErr, let image else { return }
      self?.onFrame?(image)
    }
    if status != noErr { NSLog("SimStream: H.264 decode failed (\(status))") }
    // When an encoder's SPS doesn't rule out frame reordering, VideoToolbox may hold a frame back
    // until the next one arrives. scrcpy sends nothing while the screen is still, so a held frame
    // would show only after the next change. No-op when nothing is held.
    VTDecompressionSessionFinishDelayedFrames(session)
  }

  func invalidate() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    format = nil
    parameterSets = []
  }

  deinit { invalidate() }

  private func configure(_ sets: [Data]) throws {
    let sps = sets.filter { ScrcpyProtocol.nalType($0) == 7 }
    let pps = sets.filter { ScrcpyProtocol.nalType($0) == 8 }
    guard let first = sps.first, !pps.isEmpty else { return }
    let ordered = [first] + pps
    // A rotation or encoder restart resends parameter sets; only rebuild when they change.
    guard ordered != parameterSets || session == nil else { return }
    invalidate()

    var description: CMVideoFormatDescription?
    let status = ordered.withUnsafePointers { pointers, sizes in
      CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: ordered.count, parameterSetPointers: pointers,
                                                          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw Failure.format(status) }

    let attributes: [CFString: Any] = [ // CoreVideo attribute dictionaries are heterogeneous.
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var session: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                               imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &session)
    guard created == noErr, let session else { throw Failure.session(created) }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    self.session = session
    format = description
    parameterSets = ordered
  }

  private func makeSample(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw Failure.sample(status) }
    status = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
    guard status == noErr else { throw Failure.sample(status) }
    var sample: CMSampleBuffer?
    var size = data.count
    status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                       sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw Failure.sample(status) }
    return sample
  }
}

private extension Array where Element == Data {
  /// Calls `body` with C arrays of base pointers and sizes, valid only inside it.
  func withUnsafePointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
    let copies = map { data -> UnsafeMutablePointer<UInt8> in
      let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
      data.copyBytes(to: pointer, count: data.count)
      return pointer
    }
    defer { copies.forEach { $0.deallocate() } }
    let pointers = copies.map { UnsafePointer($0) }
    let sizes = map(\.count)
    return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
  }
}
