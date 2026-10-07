import CallrecCore
import AVFoundation
import Combine
import Foundation

@MainActor
final class Player: ObservableObject {
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0

    private var player: AVPlayer?
    private var observer: Any?
    private var url: URL?

    func load(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        Task { [weak self] in
            do {
                let d = try await item.asset.load(.duration)
                self?.duration = CMTimeGetSeconds(d)
            } catch {
                log("could not read the audio duration of \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                self?.time = CMTimeGetSeconds(t)
                if let p = self?.player, p.timeControlStatus != .playing { self?.playing = false }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else {
            if duration > 0, time >= duration - 0.1 { seek(to: 0) }
            player.play()
        }
        playing.toggle()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = false
        time = 0
        duration = 0
        url = nil
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
