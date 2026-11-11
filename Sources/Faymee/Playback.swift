import AVFoundation
import Observation

/// 详情页的回放状态。播放条和转写稿共用这一个 AVPlayer：
/// 转写稿靠周期时间观察知道播到哪了，点时间时让它跳转
@MainActor @Observable
final class Playback {
    /// 时间观察的间隔。句子通常一两秒以上，0.25 秒足够让高亮跟得上
    static let interval = CMTime(value: 1, timescale: 4)
    /// 播放条上可选的速度
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    let player: AVPlayer
    /// 当前播放位置，相对录音开头的秒数
    private(set) var currentTime: TimeInterval = 0
    /// 录音总长（秒），读出来之前为 0
    private(set) var duration: TimeInterval = 0
    /// 正在播放（含缓冲等待），暂停时为 false
    private(set) var isPlaying = false
    /// 播放速度。暂停时也记着，下次播放仍按它
    private(set) var rate: Float = 1

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                if time.isNumeric { self?.currentTime = time.seconds }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        Task { [weak self] in
            guard let time = try? await asset.load(.duration), time.isNumeric else { return }
            self?.duration = time.seconds
        }
    }

    /// 跳到 time 秒并开始播放
    func play(from time: TimeInterval) {
        seek(to: time)
        player.play()
    }

    /// 播放或暂停。已经播到结尾时从头播
    func togglePlay() {
        if player.timeControlStatus != .paused {
            player.pause()
            return
        }
        if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
        player.play()
    }

    /// 前后跳 seconds 秒，播放或暂停的状态不变
    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// 跳到 time 秒（超出录音范围时取边界），播放或暂停的状态不变
    func seek(to time: TimeInterval) {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max(0, time), upper)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 改播放速度。正在播时立即生效，暂停时下次播放生效
    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if player.timeControlStatus != .paused { player.rate = newRate }
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
