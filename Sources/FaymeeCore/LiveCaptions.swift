import Foundation
import Observation

/// 一场录音的实时字幕：决定什么时候跑、什么时候停，把分路的音频交给实时字幕会话。
///
/// - 会中面板可见、设置里打开了实时字幕（`isWanted`）才跑；第一次需要时才创建会话（开始准备模型），
///   面板一直没开过就什么都不做
/// - 不需要时暂停会话（停掉引擎、释放模型），再需要时恢复（会话插分隔行）
/// - 只在会话真正在跑时打开分路，其余时候（没开过、暂停、准备中、出错、录音结束）不复制音频
/// - 录音结束时 `stop()`，之后什么都不做
///
/// App 在 `needsPumping` 时定时（约 0.1 秒）在主线程调用 `pump()` 取走分路里的音频
@MainActor @Observable
public final class LiveCaptions {
    /// 还没需要过时为 nil
    public private(set) var session: LiveCaptionSession?

    /// 面板可见且设置里打开了实时字幕
    public var isWanted = false {
        didSet {
            guard isWanted != oldValue else { return }
            apply()
        }
    }

    /// 录音的采集回调写盘之后往这里送一份
    @ObservationIgnored public let tap: LiveAudioTap

    @ObservationIgnored private let engine: any StreamingTranscriber
    @ObservationIgnored private let recordingStartedAt: Date
    @ObservationIgnored private let hotwords: [String]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var stopped = false

    /// recordingStartedAt 是录音开始的墙钟时间（字幕时间的零点）。now 只给测试替换
    public init(engine: any StreamingTranscriber, recordingStartedAt: Date, hotwords: [String],
                tap: LiveAudioTap = LiveAudioTap(), now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.recordingStartedAt = recordingStartedAt
        self.hotwords = hotwords
        self.tap = tap
        self.now = now
    }

    /// App 是否要定时调用 `pump()`：需要字幕且录音没结束时（含准备模型期间，准备好后靠 `pump` 打开分路）。
    /// 不需要时分路已关、会话已暂停，`pump` 什么都不做，定时器可以停掉
    public var needsPumping: Bool { isWanted && !stopped }

    /// 取走分路里的音频交给会话，并按会话的状态开关分路
    public func pump() {
        let running = isRunning
        tap.isEnabled = running
        guard running, let session else { return }
        for chunk in tap.drain() {
            session.append(chunk.buffer, at: chunk.time)
        }
    }

    /// 录音结束：停掉会话、关掉分路，之后什么都不做
    public func stop() {
        stopped = true
        tap.isEnabled = false
        session?.stop()
    }

    private var isRunning: Bool { isWanted && !stopped && session?.status == .running }

    private func apply() {
        guard !stopped else { return }
        if isWanted {
            if let session {
                session.resume()
            } else {
                session = LiveCaptionSession(engine: engine, recordingStartedAt: recordingStartedAt,
                                             hotwords: hotwords, now: now)
            }
        } else {
            tap.isEnabled = false
            session?.pause()
        }
    }
}
