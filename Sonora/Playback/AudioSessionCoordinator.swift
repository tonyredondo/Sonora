import AVFAudio

/// Serializes potentially blocking system audio-session calls away from the UI.
actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
    }
    func deactivate() throws { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
}
