import AVFoundation
import SwiftUI

@MainActor
final class MediaPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var position = 0.0
    @Published var error: String?
    @Published var rate: Float = 1
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = UUID()
    private var duration = 0.0
    private var savedPosition = 0.0
    private var hasPlayed = false
    private var savePosition: ((PlaybackPosition) -> Void)?

    var currentPosition: Double {
        let seconds = player?.currentTime().seconds ?? position
        return seconds.isFinite ? min(duration, max(0, seconds)) : position
    }

    isolated deinit {
        if let observer { player?.removeTimeObserver(observer) }
        statusObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func open(_ item: MediaItem, url: URL, initialTime: Double?, resumePosition: Double, save: @escaping (PlaybackPosition) -> Void) async {
        close()
        let token = generation
        position = 0; error = nil; duration = item.duration; hasPlayed = false
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw MediaFileImport.ImportError.unreadable }
            try Task.checkCancellation()
            guard token == generation else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            let resume = PlaybackPosition(position: resumePosition).canResume(duration: duration) ? resumePosition : 0
            let start = min(max(0, initialTime ?? resume), max(0, duration - 0.1))
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard token == generation else { player.pause(); return }
            position = start; savedPosition = resumePosition; savePosition = save
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == token, time.seconds.isFinite else { return }
                    self.position = time.seconds
                    if self.player?.timeControlStatus == .playing {
                        self.hasPlayed = true
                        if abs(time.seconds - self.savedPosition) >= 5 { self.persist(time.seconds) }
                    }
                }
            }
            statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                let status = observed.timeControlStatus
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if status == .playing { self.hasPlayed = true }
                    else if status == .paused, let player = self.player { self.persist(player.currentTime().seconds) }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.hasPlayed = true
                    self.persist(self.duration)
                }
            }
            if initialTime != nil { player.playImmediately(atRate: rate) }
        } catch is CancellationError { if token == generation { close() } }
        catch { if token == generation { self.error = "Не удалось открыть запись: \(error.localizedDescription)" } }
    }

    func seek(_ seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.1))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.playImmediately(atRate: rate)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player?.defaultRate = rate
        if player?.timeControlStatus == .playing { player?.rate = rate }
    }

    func pauseAndSave() {
        if player?.timeControlStatus == .playing { hasPlayed = true }
        player?.pause()
        if let player { persist(player.currentTime().seconds) }
    }

    private func persist(_ seconds: Double) {
        guard hasPlayed, seconds.isFinite else { return }
        let seconds = min(duration, max(0, seconds))
        position = seconds
        guard abs(seconds - savedPosition) > 0.01 else { return }
        savedPosition = seconds
        savePosition?(PlaybackPosition(position: seconds))
    }

    func close() {
        pauseAndSave()
        generation = UUID()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        statusObserver?.invalidate(); statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        savePosition = nil
        player = nil
    }
}
