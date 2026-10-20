import AVFAudio
import SFBAudioEngine
import SonoraCore

struct TransitionTrack: @unchecked Sendable {
    let id: String
    let prepared: PreparedTrack

    static func prepare(_ prepared: PreparedTrack, id: String) -> Self {
        if prepared.decoder is NormalizedPCMDecoder, prepared.decoder.processingFormat == NormalizedPCMDecoder.format { return Self(id: id, prepared: prepared) }
        // Unsupported conversion preserves ordinary playback and is reported in the
        // transition result. The raw decoder has not yet been transferred to SFB.
        let decoder = (try? NormalizedPCMDecoder(prepared.decoder)) as (any PCMDecoding)? ?? prepared.decoder
        return Self(id: id, prepared: PreparedTrack(decoder: decoder, details: prepared.details))
    }
}

/// One ownership transfer between I/O preparation, outgoing decoding and enqueue.
/// SFB owns an enqueued decoder exclusively. Only the *unenqueued* incoming decoder
/// can be borrowed here; it is returned after its head has been copied, and cannot
/// be enqueued until outgoing decoding finishes. No render callback takes this lock.
final class CrossfadeHandoff: @unchecked Sendable {
    private let condition = NSCondition()
    private var next: TransitionTrack?
    private var started = false
    private var prepared = false
    private var finished = false
    private var consumed = false
    private var canceled = false
    private var outcome: TransitionOutcome = .notReady

    func beginPreparation() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !started, !canceled else { return false }
        started = true; return true
    }
    func supply(_ track: TransitionTrack?) {
        condition.lock(); defer { condition.unlock() }
        guard !canceled else { return }
        next = track; prepared = true; condition.broadcast()
    }
    func borrowForMix() -> TransitionTrack? {
        condition.lock(); defer { condition.unlock() }
        // Only the decoder worker may wait, and only briefly. Slow cloud/provider
        // preparation falls back to continuous playback instead of fading to silence.
        let deadline = Date().addingTimeInterval(0.1)
        while !prepared && !canceled {
            if !condition.wait(until: deadline) { break }
        }
        guard !canceled else { return nil }
        let track = next; next = nil; return track
    }
    func returnAfterMix(_ track: TransitionTrack, outcome: TransitionOutcome) {
        condition.lock(); defer { condition.unlock() }
        guard !canceled else { return }
        next = track; self.outcome = outcome
    }
    func finishDecoding(outcome: TransitionOutcome? = nil) {
        condition.lock(); defer { condition.unlock() }
        finished = true
        if let outcome { self.outcome = outcome }
    }
    func takeForEnqueue() -> (TransitionTrack, TransitionOutcome)? {
        condition.lock(); defer { condition.unlock() }
        guard finished, prepared, !consumed, !canceled, let next else { return nil }
        consumed = true; self.next = nil
        return (next, outcome)
    }
    func cancel() {
        condition.lock(); defer { condition.unlock() }
        canceled = true; next = nil; condition.broadcast()
    }
    func retryAfterFailure() {
        condition.lock(); defer { condition.unlock() }
        guard !canceled else { return }
        next = nil; started = false; prepared = false; consumed = false; outcome = .notReady
    }
}

/// Mixes only the outgoing tail and a bounded incoming head. Linear complementary
/// gains preserve headroom. At EOF the head is freed; SFB subsequently renders the
/// incoming decoder from its advanced position, so its beginning is not repeated.
final class CrossfadeDecoder: NSObject, PCMDecoding {
    private let base: NormalizedPCMDecoder
    private let handoff: CrossfadeHandoff
    private let maximumOverlap: AVAudioFramePosition
    private let planningFrame: AVAudioFramePosition
    private let adaptive: AudioRhythmAnalysis?
    private var planned = false
    private var head: AVAudioPCMBuffer?
    private var fadeStart: AVAudioFramePosition = 0
    private var overlap: AVAudioFramePosition = 0
    private var finished = false
    private let scratch = AVAudioPCMBuffer(pcmFormat: NormalizedPCMDecoder.format, frameCapacity: 8192)!
    var inputSource: InputSource { base.inputSource }
    var sourceFormat: AVAudioFormat { base.sourceFormat }
    var processingFormat: AVAudioFormat { base.processingFormat }
    var decodingIsLossless: Bool { false }
    var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    var isOpen: Bool { base.isOpen || finished }
    let supportsSeeking = false
    var position: AVAudioFramePosition { base.position }
    var length: AVAudioFramePosition { base.length }

    init(_ base: NormalizedPCMDecoder, handoff: CrossfadeHandoff, duration: Double, adaptive: AudioRhythmAnalysis? = nil) {
        self.base = base; self.handoff = handoff
        self.adaptive = adaptive
        maximumOverlap = min(AVAudioFramePosition(duration * base.processingFormat.sampleRate), max(0, (base.length - base.position) / 2))
        planningFrame = base.length - maximumOverlap
        super.init()
    }
    func open() throws { if !isOpen { try base.open() } }
    func close() throws { try base.close() }
    func seek(to frame: AVAudioFramePosition) throws { throw CocoaError(.featureUnsupported) }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let buffer = buffer as? AVAudioPCMBuffer else { throw CocoaError(.fileReadCorruptFile) }
        try decode(into: buffer, length: buffer.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length requested: AVAudioFrameCount) throws {
        guard !finished else { buffer.frameLength = 0; return }
        guard buffer.format == processingFormat, let output = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let wanted = min(AVAudioFramePosition(min(requested, buffer.frameCapacity)), length - position)
        var written = 0
        // SFB treats *any* short read as EOF. Fill the entire request even when it
        // crosses the planning/fade boundary; only the real file end is a short read.
        while written < wanted {
            let start = position
            if !planned && start >= planningFrame { planOverlap(); planned = true }
            var count = min(wanted - AVAudioFramePosition(written), AVAudioFramePosition(scratch.frameCapacity))
            if !planned { count = min(count, planningFrame - start) }
            if head != nil && start < fadeStart { count = min(count, fadeStart - start) }
            try base.decode(into: scratch, length: AVAudioFrameCount(count))
            guard scratch.frameLength > 0 else { break }
            for channel in 0..<2 {
                let source = scratch.floatChannelData![channel]
                for frame in 0..<Int(scratch.frameLength) {
                    if let head, start + AVAudioFramePosition(frame) >= fadeStart {
                        let index = Int(start - fadeStart) + frame
                        let progress = Float(index) / Float(max(1, overlap - 1))
                        output[channel][written + frame] = source[frame] * (1 - progress) + head.floatChannelData![channel][index] * progress
                    } else { output[channel][written + frame] = source[frame] }
                }
            }
            written += Int(scratch.frameLength)
        }
        buffer.frameLength = AVAudioFrameCount(written)
        if position >= length || written == 0 {
            finished = true; head = nil; handoff.finishDecoding(); try? base.close()
        }
    }
    private func planOverlap() {
        guard let next = handoff.borrowForMix() else { return }
        guard let decoder = next.prepared.decoder as? NormalizedPCMDecoder else {
            handoff.returnAfterMix(next, outcome: .incompatible); return
        }
        var frames = min(maximumOverlap, max(0, (decoder.length - decoder.position) / 2))
        var outcome = TransitionOutcome.mixed(Double(frames) / processingFormat.sampleRate)
        var skip: AVAudioFramePosition = 0
        if let adaptive {
            let rate = processingFormat.sampleRate
            let decision = AdaptiveMixPlanner.plan(outgoing: adaptive.tail, incoming: next.prepared.details.rhythm?.head,
                end: Double(length) / rate, earliestStart: Double(position) / rate,
                incomingPosition: Double(decoder.position) / rate, incomingDuration: Double(decoder.length) / rate,
                maximumOverlap: Double(frames) / rate)
            switch decision {
            case .matched(let plan):
                frames = min(frames, AVAudioFramePosition((plan.duration * rate).rounded()))
                skip = AVAudioFramePosition((plan.incomingSkip * rate).rounded())
                let approximate = min(adaptive.tail?.confidence ?? 0, next.prepared.details.rhythm?.head?.confidence ?? 0) < 0.72
                outcome = approximate ? .adaptiveEstimate(Double(frames) / rate, plan.bpm) : .adaptive(Double(frames) / rate, plan.bpm)
            case .fallback(let reason):
                if let plan = AdaptiveMixPlanner.estimated(outgoingBPM: adaptive.tailBPM,
                    incomingBPM: next.prepared.details.rhythm?.headBPM, end: Double(length) / rate,
                    earliestStart: Double(position) / rate, incomingPosition: Double(decoder.position) / rate,
                    incomingDuration: Double(decoder.length) / rate, maximumOverlap: Double(frames) / rate) {
                    frames = min(frames, AVAudioFramePosition((plan.duration * rate).rounded()))
                    outcome = .estimated(Double(frames) / rate, plan.bpm)
                } else {
                    outcome = .adaptiveFallback(adaptive.reason ?? next.prepared.details.rhythm?.reason ?? reason)
                }
            }
        }
        guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            handoff.returnAfterMix(next, outcome: .tooShort); return
        }
        do {
            while skip > 0 {
                try decoder.decode(into: scratch, length: AVAudioFrameCount(min(skip, AVAudioFramePosition(scratch.frameCapacity))))
                guard scratch.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                skip -= AVAudioFramePosition(scratch.frameLength)
            }
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            guard buffer.frameLength == buffer.frameCapacity else { throw CocoaError(.fileReadCorruptFile) }
            head = buffer; overlap = frames; fadeStart = length - frames
            handoff.returnAfterMix(next, outcome: outcome)
        } catch {
            // A failed head read cannot fade out the healthy outgoing track. The
            // controller opens the next available file through its normal error path.
            handoff.returnAfterMix(next, outcome: .failed(error.localizedDescription))
        }
    }
}
