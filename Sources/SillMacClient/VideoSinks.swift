import AVFoundation
import CoreMedia
import Foundation
import StreamProtocol
import VideoToolbox

/// The HEVC parameter sets and access units the Mac sends (StreamMessage.swift: kind 0, and kind 1's
/// length-prefixed NAL units) as CoreMedia samples: the format description, and one sample per frame,
/// shown as soon as it decodes. The iOS client's HEVCDisplayView does the same on a phone.
enum HEVCSamples {
    static func formatDescription(_ ps: ParameterSets) -> CMVideoFormatDescription? {
        let buffers = ps.sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
            parameterSetSizes: ps.sets.map(\.count), nalUnitHeaderLength: Int32(ps.nalUnitHeaderLength),
            extensions: nil, formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }
        let replaced = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard replaced == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        return sample
    }

    static func size(_ desc: CMVideoFormatDescription) -> CGSize {
        let d = CMVideoFormatDescriptionGetDimensions(desc)
        return CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
    }
}

/// The stream window's picture: an AVSampleBufferDisplayLayer fed on the session's queue (its enqueue
/// and flush are safe off the main thread). A repeat of the same parameter sets (each keyframe carries
/// them) changes nothing; new ones (a new source, a resize) blank the picture until their keyframe.
final class DisplayLayerSink: FrameSink {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var lastSets: Data?
    private var waitingForKeyframe = true
    var onSize: ((CGSize) -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func apply(_ sets: ParameterSets) {
        let encoded = sets.encoded()
        if encoded == lastSets, format != nil { return }
        guard let desc = HEVCSamples.formatDescription(sets) else { print("Sill: the Mac's parameter sets did not parse"); return }
        lastSets = encoded
        format = desc
        waitingForKeyframe = true
        layer.flushAndRemoveImage()
        onSize?(HEVCSamples.size(desc))
    }

    func enqueue(_ frame: Data, isKeyframe: Bool) {
        guard let format else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }
        guard let sample = HEVCSamples.sample(frame, format: format) else { return }
        if layer.status == .failed {
            print("Sill: the display layer failed (\(String(describing: layer.error))); waiting for a keyframe")
            layer.flush()
            waitingForKeyframe = true
            return
        }
        layer.enqueue(sample)
    }

    func clear() {
        format = nil
        lastSets = nil
        waitingForKeyframe = true
        layer.flushAndRemoveImage()
    }
}

/// TEST ONLY (the headless check, `--headless`): decodes every frame with VideoToolbox and counts the
/// decoded pictures, so a check without a window knows the stream really decodes on this Mac.
final class DecodingCounterSink: FrameSink {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true
    private let lock = NSLock()
    private var _decoded = 0
    private var _failed = 0
    private(set) var size: CGSize = .zero

    var decoded: Int { lock.lock(); defer { lock.unlock() }; return _decoded }
    var failed: Int { lock.lock(); defer { lock.unlock() }; return _failed }

    func apply(_ sets: ParameterSets) {
        guard let desc = HEVCSamples.formatDescription(sets) else { return }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: desc) { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        format = desc
        size = HEVCSamples.size(desc)
        waitingForKeyframe = true
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                  imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s)
        session = status == noErr ? s : nil
        if session == nil { print("headless: VTDecompressionSessionCreate failed: \(status)") }
    }

    func enqueue(_ frame: Data, isKeyframe: Bool) {
        guard let format, let session else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }
        guard let sample = HEVCSamples.sample(frame, format: format) else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            self.lock.lock()
            if status == noErr, image != nil { self._decoded += 1 } else { self._failed += 1 }
            self.lock.unlock()
        }
        if status != noErr { lock.lock(); _failed += 1; lock.unlock() }
    }

    func clear() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }
}
