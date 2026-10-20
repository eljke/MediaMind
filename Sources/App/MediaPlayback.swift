import AVFoundation
import SwiftUI

@MainActor
final class MediaPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var position = 0.0
    @Published var error: String?
    @Published var rate: Float = 1
    private var observer: Any?
    private var itemID: UUID?
    private var savedPosition = 0.0

    func open(_ item: MediaItem, url: URL, initialTime: Double?) async {
        close()
        position = 0
        error = nil
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw MediaFileImport.ImportError.unreadable }
            try Task.checkCancellation()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            let saved = UserDefaults.standard.double(forKey: "position-\(item.id)")
            let resume = saved >= item.duration - 1 ? 0 : saved
            let start = min(max(0, initialTime ?? resume), max(0, item.duration - 0.1))
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            position = start
            savedPosition = start
            itemID = item.id
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.itemID == item.id, time.seconds.isFinite else { return }
                    self.position = time.seconds
                    if abs(time.seconds - self.savedPosition) >= 5 {
                        UserDefaults.standard.set(time.seconds, forKey: "position-\(item.id)")
                        self.savedPosition = time.seconds
                    }
                }
            }
            if initialTime != nil { player.playImmediately(atRate: rate) }
        } catch is CancellationError { close() }
        catch { self.error = "Не удалось открыть запись: \(error.localizedDescription)" }
    }

    func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.playImmediately(atRate: rate)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player?.defaultRate = rate
        if player?.timeControlStatus == .playing { player?.rate = rate }
    }

    func close() {
        if let itemID { UserDefaults.standard.set(position, forKey: "position-\(itemID)") }
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        itemID = nil
    }
}
