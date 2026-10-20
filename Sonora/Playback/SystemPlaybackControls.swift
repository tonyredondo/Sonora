import AVFAudio
import MediaPlayer
import Observation
import SonoraCore

@MainActor
final class SystemPlaybackControls {
    static let playbackRates: [Float] = [0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private weak var owner: PlaybackController?
    init(owner: PlaybackController) {
        self.owner = owner
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlaybackController) -> Void) {
            targets.append((command, command.addTarget { [weak owner] _ in
                Task { @MainActor in if let owner { action(owner) } }
                return .success
            }))
        }
        register(center.playCommand) { $0.resume() }
        register(center.pauseCommand) { $0.pause() }
        register(center.togglePlayPauseCommand) { $0.togglePlayback() }
        register(center.nextTrackCommand) { $0.next() }
        register(center.previousTrackCommand) { $0.previous() }
        targets.append((center.changeShuffleModeCommand, center.changeShuffleModeCommand.addTarget { [weak owner] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent,
                  event.shuffleType == .off || event.shuffleType == .items else { return .commandFailed }
            let shuffled = event.shuffleType == .items
            Task { @MainActor in owner?.shuffle = shuffled }
            return .success
        }))
        targets.append((center.changeRepeatModeCommand, center.changeRepeatModeCommand.addTarget { [weak owner] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch event.repeatType {
            case .off: mode = .off
            case .one: mode = .one
            case .all: mode = .all
            @unknown default: return .commandFailed
            }
            Task { @MainActor in owner?.repeatMode = mode }
            return .success
        }))
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.playbackRates.map { NSNumber(value: $0) }
        targets.append((center.changePlaybackRateCommand, center.changePlaybackRateCommand.addTarget { [weak owner] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent,
                  event.playbackRate.isFinite, (0.5...2).contains(event.playbackRate) else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in owner?.setPlaybackAdjustment(rate: rate) }
            return .success
        }))
        targets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak owner] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in owner?.seek(to: position) }
            return .success
        }))
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak owner] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in
                if type == .began { owner?.interruptionBegan() }
                else if type == .ended { owner?.interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak owner] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in owner?.pause() } }
        })
        observeModes()
    }
    /// Native CarPlay buttons read these command states, including changes made
    /// on the phone while the CarPlay screen stays open.
    private func observeModes() {
        guard let owner else { return }
        withObservationTracking {
            let center = MPRemoteCommandCenter.shared()
            center.changeShuffleModeCommand.currentShuffleType = owner.shuffle ? .items : .off
            center.changeRepeatModeCommand.currentRepeatType = switch owner.repeatMode {
            case .off: .off
            case .one: .one
            case .all: .all
            }
            let available = owner.current != nil
            center.changeShuffleModeCommand.isEnabled = available
            center.changeRepeatModeCommand.isEnabled = available
            center.changePlaybackRateCommand.isEnabled = available
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModes() }
        }
    }
    isolated deinit {
        for (command, target) in targets { command.removeTarget(target) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

extension PlaybackController {
    func cycleRepeatMode() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    func cyclePlaybackRate() {
        let next = SystemPlaybackControls.playbackRates.first { $0 > equalizer.playback.rate + 0.001 }
        setPlaybackAdjustment(rate: next ?? SystemPlaybackControls.playbackRates[0])
    }
}
