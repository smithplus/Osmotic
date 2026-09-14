import AVFoundation
import CoreMedia
import OsmoticCore
import SwiftUI

/// Turns the camera's H.264 Annex-B access units into frames on an `AVSampleBufferDisplayLayer`.
/// Fed from the session's worker thread; decoding setup and enqueueing happen on one serial queue.
/// Pattern after Kaze-for-DJI's `Pocket3VideoOutput` (MIT).
nonisolated final class LiveVideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "osmotic.liveview")
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var waitingForKeyframe = true
    private var frameIndex: Int64 = 0
    /// Called (on the render queue) when the first picture is on screen.
    var onFirstFrame: (@Sendable () -> Void)?
    /// Called (on the render queue) with the picture's size whenever the stream's format changes —
    /// a camera filming vertically streams a portrait picture.
    var onDimensions: (@Sendable (CGSize) -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// One access unit (or any run of NAL units) in Annex-B form.
    func enqueue(annexB: [UInt8]) {
        queue.async { [self] in handle(H264AnnexB.units(annexB)) }
    }

    /// Forget the stream (a new one starts with fresh parameter sets and a keyframe).
    func reset() {
        queue.async { [self] in
            format = nil; sps = nil; pps = nil
            waitingForKeyframe = true
            frameIndex = 0
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func handle(_ units: [[UInt8]]) {
        var picture: [[UInt8]] = []
        var keyframe = false
        for u in units {
            switch H264AnnexB.type(of: u) {
            case H264AnnexB.NALType.sps.rawValue:
                if sps != u { sps = u; format = nil }
            case H264AnnexB.NALType.pps.rawValue:
                if pps != u { pps = u; format = nil }
            case H264AnnexB.NALType.idr.rawValue:
                keyframe = true
                picture.append(u)
            case H264AnnexB.NALType.slice.rawValue:
                picture.append(u)
            default:
                break   // AUD, SEI, others: not needed to show the picture
            }
        }
        guard !picture.isEmpty else { return }
        if format == nil, let sps, let pps {
            format = makeFormat(sps: sps, pps: pps)
            if let format {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                onDimensions?(CGSize(width: Int(d.width), height: Int(d.height)))
            }
        }
        guard let format else { return }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }
        guard let sample = makeSample(H264AnnexB.avcc(picture), format: format, keyframe: keyframe) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            waitingForKeyframe = true
            return
        }
        renderer.enqueue(sample)
        if frameIndex == 0 { onFirstFrame?() }
        frameIndex += 1
    }

    private func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var out: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return status == noErr ? out : nil
    }

    private func makeSample(_ avcc: [UInt8], format: CMVideoFormatDescription, keyframe: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: avcc.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // Live: show each frame as soon as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !keyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// The monitor: hosts the renderer's layer.
struct LiveVideoView: NSViewRepresentable {
    let renderer: LiveVideoRenderer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        renderer.layer.frame = v.bounds
        renderer.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(renderer.layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
