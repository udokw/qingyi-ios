import AVFoundation
import AudioToolbox

/// 落子/将军音效: 使用安卓版同名 wav; 围棋落子用系统轻点
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var cache: [String: AVAudioPlayer] = [:]
    private var enabled = true

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
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
        AudioServicesPlaySystemSound(1104)
    }

    private func play(_ name: String) {
        if let player = cache[name] {
            player.currentTime = 0
            player.play()
            return
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            AudioServicesPlaySystemSound(1104)
            return
        }
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            cache[name] = player
            player.play()
        }
    }
}
