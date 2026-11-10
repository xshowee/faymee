import AVFoundation
import Observation

/// 详情页的回放状态。播放器控件和转写稿共用这一个 AVPlayer：
/// 转写稿靠周期时间观察知道播到哪了，点时间时让它跳转
@MainActor @Observable
final class Playback {
    /// 时间观察的间隔。句子通常一两秒以上，0.25 秒足够让高亮跟得上
    static let interval = CMTime(value: 1, timescale: 4)

    let player: AVPlayer
    /// 当前播放位置，相对录音开头的秒数
    private(set) var currentTime: TimeInterval = 0
    /// 正在播放（含缓冲等待），暂停时为 false
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                if time.isNumeric { self?.currentTime = time.seconds }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    /// 跳到 time 秒并开始播放
    func play(from time: TimeInterval) {
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// 离开详情页时调用，停止播放并移除观察
    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
    }
}
