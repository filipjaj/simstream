import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// Decoder configuration a browser needs before the first keyframe (WebCodecs `VideoDecoderConfig`).
struct H264Config: Equatable, Sendable {
  /// RFC 6381 codec string, e.g. "avc1.64001f".
  let codec: String
  /// avcC record (AVCDecoderConfigurationRecord).
  let description: Data
  let width: Int
  let height: Int

  /// Builds an avcC record from one SPS and one PPS.
  static func make(sps: [UInt8], pps: [UInt8], width: Int, height: Int) -> H264Config? {
    guard sps.count >= 4, !pps.isEmpty else { return nil }
    var record: [UInt8] = [1, sps[1], sps[2], sps[3], 0xFF, 0xE1]
    record += [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)] + sps
    record += [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)] + pps
    let codec = "avc1." + sps[1...3].map { String(format: "%02x", $0) }.joined()
    return H264Config(codec: codec, description: Data(record), width: width, height: height)
  }
}

struct H264Frame: Sendable {
  /// Length-prefixed (AVCC) NAL units.
  let data: Data
  let isKeyframe: Bool
  /// Microseconds, monotonic.
  let timestamp: Int64
}

/// Hardware H.264 encoder tuned for latency: real-time mode, no frame reordering,
/// low-latency rate control. ~10× less bandwidth than MJPEG at the same sharpness.
final class H264Encoder: @unchecked Sendable { // Used only from FramePump's queue, plus VT's output callback.
  enum Failure: Error { case sessionCreation(OSStatus), transferCreation(OSStatus) }

  var onFrame: (@Sendable (H264Frame, H264Config) -> Void)?
  let width: Int
  let height: Int

  private var session: VTCompressionSession?
  private var transfer: VTPixelTransferSession?
  private let configLock = NSLock()
  private var config: H264Config?
  private var forceKeyframe = true

  init(width: Int, height: Int, bitrate: Int, framesPerSecond: Int) throws {
    // H.264 needs even dimensions.
    self.width = width & ~1
    self.height = height & ~1
    let specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
    var created: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(self.width), height: Int32(self.height), codecType: kCMVideoCodecType_H264,
      encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &created)
    guard status == noErr, let created else { throw Failure.sessionCreation(status) }
    session = created

    let properties: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
      kVTCompressionPropertyKey_AverageBitRate: bitrate,
      kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
      kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
    ]
    for (key, value) in properties {
      VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
    }
    VTCompressionSessionPrepareToEncodeFrames(created)

    var transfer: VTPixelTransferSession?
    let transferStatus = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    guard transferStatus == noErr, let transfer else { throw Failure.transferCreation(transferStatus) }
    VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
    self.transfer = transfer
  }

  deinit { invalidate() }

  func requestKeyframe() { forceKeyframe = true }

  /// Copies the surface into a scaled encoder buffer and submits it. Returns false on failure.
  @discardableResult
  func encode(_ surface: IOSurface) -> Bool {
    guard let session, let transfer, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return false }
    var unmanaged: Unmanaged<CVPixelBuffer>?
    guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanaged) == kCVReturnSuccess,
          let source = unmanaged?.takeRetainedValue() else { return false }
    var target: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return false }
    guard VTPixelTransferSessionTransferImage(transfer, from: source, to: target) == noErr else { return false }

    let now = Int64(DispatchTime.now().uptimeNanoseconds / 1000)
    let pts = CMTime(value: now, timescale: 1_000_000)
    var options: CFDictionary?
    if forceKeyframe {
      options = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
      forceKeyframe = false
    }
    let status = VTCompressionSessionEncodeFrame(session, imageBuffer: target, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
      guard status == noErr, let sample, let self else { return }
      self.emit(sample, timestamp: now)
    }
    return status == noErr
  }

  func invalidate() {
    if let session {
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    transfer = nil
  }

  private func emit(_ sample: CMSampleBuffer, timestamp: Int64) {
    guard let block = sample.dataBuffer, let format = sample.formatDescription else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    let config: H264Config? = configLock.withLock {
      if isKeyframe || self.config == nil, let fresh = Self.config(from: format, width: width, height: height) {
        self.config = fresh
      }
      return self.config
    }
    guard let config else { return }

    let length = CMBlockBufferGetDataLength(block)
    var data = Data(count: length)
    let copied = data.withUnsafeMutableBytes { bytes -> OSStatus in
      guard let base = bytes.baseAddress else { return -1 }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
    }
    guard copied == noErr else { return }
    onFrame?(H264Frame(data: data, isKeyframe: isKeyframe, timestamp: timestamp), config)
  }

  private static func config(from format: CMFormatDescription, width: Int, height: Int) -> H264Config? {
    var sps: UnsafePointer<UInt8>?, spsSize = 0, pps: UnsafePointer<UInt8>?, ppsSize = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps,
                                                             parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pps,
                                                             parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
          let sps, let pps else { return nil }
    return H264Config.make(sps: Array(UnsafeBufferPointer(start: sps, count: spsSize)),
                           pps: Array(UnsafeBufferPointer(start: pps, count: ppsSize)),
                           width: width, height: height)
  }
}
