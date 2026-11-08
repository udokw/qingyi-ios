import AVFoundation
import AudioToolbox

/// 落子/将军音效: 使用安卓版同名 wav; 围棋落子用系统轻点
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var cache: [String: AVAudioPlayer] = [:]
    private var enabled = true

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for name in ["xq_move", "xq_check", "go_win", "go_lose"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            player.volume = 1.0
            cache[name] = player
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
    }

    func playMove() {
        guard enabled else { return }
        play("xq_move")
    }

    func playCheck() {
        guard enabled else { return }
        play("xq_check")
    }

    func playStone() {
        guard enabled else { return }
        play("xq_move")
    }

    /// 围棋终局：赢家听喝彩，输家听收束音，不再复用象棋「将军」音。
    func playWin() {
        guard enabled else { return }
        play("go_win")
    }

    func playLose() {
        guard enabled else { return }
        play("go_lose")
    }

    private func play(_ name: String) {
        if let player = cache[name] {
            player.currentTime = 0
            player.volume = 1.0
            player.play()
            return
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            AudioServicesPlaySystemSound(1104)
            return
        }
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            player.volume = 1.0
            cache[name] = player
            player.play()
        }
    }
}
