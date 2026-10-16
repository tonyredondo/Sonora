import AVFAudio
import SFBAudioEngine

enum PlayerEvent: Sendable {
    case started(ObjectIdentifier), decoded(ObjectIdentifier), released(ObjectIdentifier), state(Bool), ended
    case failed(ObjectIdentifier?, String)
}

/// The engine's event thread sends values, never mutable decoders, to the UI owner.
final class PlayerEvents: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    let receive: @Sendable (PlayerEvent) -> Void
    private let equalizer: EqualizerProcessor
    init(equalizer: EqualizerProcessor, receive: @escaping @Sendable (PlayerEvent) -> Void) {
        self.equalizer = equalizer; self.receive = receive
    }
    func audioPlayer(_ player: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        equalizer.connect(in: engine, format: format)
    }
    func audioPlayer(_ player: AudioPlayer, renderingStarted decoder: any PCMDecoding) { receive(.started(ObjectIdentifier(decoder))) }
    func audioPlayer(_ player: AudioPlayer, decodingComplete decoder: any PCMDecoding) { receive(.decoded(ObjectIdentifier(decoder))) }
    func audioPlayer(_ player: AudioPlayer, renderingComplete decoder: any PCMDecoding) { receive(.released(ObjectIdentifier(decoder))) }
    func audioPlayer(_ player: AudioPlayer, decoderCanceled decoder: any PCMDecoding, framesRendered: AVAudioFramePosition) { receive(.released(ObjectIdentifier(decoder))) }
    func audioPlayer(_ player: AudioPlayer, decodingAborted decoder: any PCMDecoding, error: Error, framesRendered: AVAudioFramePosition) { receive(.failed(ObjectIdentifier(decoder), error.localizedDescription)) }
    func audioPlayer(_ player: AudioPlayer, playbackStateChanged state: AudioPlayer.PlaybackState) { receive(.state(state == .playing)) }
    func audioPlayerEndOfAudio(_ player: AudioPlayer) { receive(.ended) }
    func audioPlayer(_ player: AudioPlayer, encounteredError error: Error) { receive(.failed(nil, error.localizedDescription)) }
}
