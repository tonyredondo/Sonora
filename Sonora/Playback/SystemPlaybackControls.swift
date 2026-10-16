import AVFAudio
import MediaPlayer

@MainActor
final class SystemPlaybackControls {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    init(owner: PlaybackController) {
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
    }
    isolated deinit {
        for (command, target) in targets { command.removeTarget(target) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
