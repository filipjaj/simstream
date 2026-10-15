import CoreMedia
import Foundation

/// Turns SimStream's H.264 packets into sample buffers the display layer decodes in hardware.
/// The Mac already sends AVCC (length-prefixed) NAL units plus an avcC record, which is exactly
/// the MP4 layout VideoToolbox expects, so no Annex B conversion is needed.
struct H264SampleFactory {
  private(set) var format: CMVideoFormatDescription?
  private(set) var config: CodecConfig?

  enum Failure: Error, Equatable {
    case formatDescription(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case notConfigured
  }

  /// Returns true when the format changed and the renderer should be flushed.
  @discardableResult
  mutating func configure(_ config: CodecConfig) throws -> Bool {
    guard config != self.config else { return false }
    let atoms = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": config.description]]
    var created: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: Int32(config.width), height: Int32(config.height),
      extensions: atoms as CFDictionary, formatDescriptionOut: &created)
    guard status == noErr, let created else { throw Failure.formatDescription(status) }
    let changed = format != nil
    format = created
    self.config = config
    return changed
  }

  func sample(payload: Data, timestamp: Int64, isKeyframe: Bool) throws -> CMSampleBuffer {
    guard let format else { throw Failure.notConfigured }
    let length = payload.count
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block)
    guard status == noErr, let block else { throw Failure.blockBuffer(status) }
    status = payload.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
      return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard status == noErr else { throw Failure.blockBuffer(status) }

    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000),
                                    decodeTimeStamp: .invalid)
    var size = length
    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
      sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw Failure.sampleBuffer(status) }

    // Live stream: show each frame as soon as it's decoded instead of scheduling it on a timebase.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                           Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      if !isKeyframe {
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      }
    }
    return sample
  }
}
