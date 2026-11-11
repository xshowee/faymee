import AVFoundation
import Observation

/// 字幕里定稿的一句。start / end 是录音里的秒数（以录音开始的墙钟时间为零点，按收到音频的时刻换算，误差几秒）
public struct LiveCaption: Hashable, Sendable, Identifiable {
    /// 会话内递增，不随丢弃最旧的句子变化
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
}

/// 会中面板显示的一行字幕
public enum LiveCaptionLine: Hashable, Sendable, Identifiable {
    case sentence(LiveCaption)
    /// “中间约 N 分钟没有字幕”：字幕暂停过（面板关闭、被挡住、合盖、熄屏）
    case gap(LiveCaptionGap)

    public var id: Int {
        switch self {
        case .sentence(let s): s.id
        case .gap(let g): g.id
        }
    }
}

/// 字幕停过的一段。start 是录音里的秒数，duration 按暂停到恢复的墙钟时间算
public struct LiveCaptionGap: Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var duration: TimeInterval

    /// 四舍五入的分钟数，不到半分钟为 0
    public var minutes: Int { Int((duration / 60).rounded()) }

    public var text: String {
        minutes == 0 ? "中间不到 1 分钟没有字幕" : "中间约 \(minutes) 分钟没有字幕"
    }
}

/// 还没定稿的文字（浅色显示）。start 是录音里的秒数
public struct LiveCaptionVolatile: Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
}

public enum LiveCaptionStatus: Hashable, Sendable {
    /// 准备语音模型（首次使用时下载），0...1
    case preparing(Double)
    /// 引擎在跑，或等第一块音频到来
    case running
    /// 面板不可见，引擎已停，等 `resume`
    case paused
    /// 出错原因。自动重试过一次仍出错才进入，等用户点“重试”
    case failed(String)
}

/// 实时字幕会话：吃流式引擎的事件，维护会中面板显示的字幕行。
/// 不知道音频从哪来，只接收音频块和“暂停 / 恢复”信号；不落盘，录音结束时随面板一起丢弃。
///
/// 每次暂停、出错都停掉引擎，之后来的第一块音频开始新的一次转写；换了音频格式（切换麦克风）时
/// 结束旧的转写（让它吐完剩下的定稿句子）、开新的，字幕接着显示，不插分隔行
@MainActor @Observable
public final class LiveCaptionSession {
    public private(set) var lines: [LiveCaptionLine] = []
    public private(set) var volatile: LiveCaptionVolatile?

    public var status: LiveCaptionStatus {
        if let failure { return .failed(failure) }
        if pausedAt != nil { return .paused }
        return isPrepared ? .running : .preparing(progress)
    }

    /// 只保留最近这么多句，更早的丢弃
    public static let limit = 200

    /// 自动重试过之后，当前转写开始这么久后还在出字，才算恢复正常、再给一次自动重试的机会
    public static let healthyAfter: TimeInterval = 30

    private var failure: String?
    private var pausedAt: Date?
    private var isPrepared = false
    private var progress: Double = 0

    @ObservationIgnored private let engine: any StreamingTranscriber
    @ObservationIgnored private let recordingStartedAt: Date
    @ObservationIgnored private let hotwords: [String]
    @ObservationIgnored private let now: () -> Date
    /// 正在送入音频的转写和它的音频格式
    @ObservationIgnored private var current: (token: Int, format: AVAudioFormat, transcription: any StreamingTranscription)?
    /// 事件还要的转写：当前的，加上换格式时正在收尾的。取消的转写迟到的事件据此丢弃
    @ObservationIgnored private var live: [Int: any StreamingTranscription] = [:]
    @ObservationIgnored private var nextToken = 0
    /// 浅色字是哪次转写的。只有当前的转写能改浅色字；它的主人定稿、结束时清掉，
    /// 收尾中的旧转写的定稿句子不清别人的浅色字
    @ObservationIgnored private var volatileOwner: Int?
    /// 每次开始准备加一，被取代的准备迟到的进度和结果丢弃
    @ObservationIgnored private var prepareToken = 0
    @ObservationIgnored private var nextID = 1
    /// 出错时自动重试一次，再错就显示出错和“重试”。重试后只有当前的转写开始 `healthyAfter` 之后
    /// 还出了非空的结果，才算恢复正常、再给一次机会：引擎若每次刚出一个结果就出错，只看“出过字”
    /// 会一直静默重试、永远不显示“重试”。收尾中的旧转写、空的临时文字都不算
    @ObservationIgnored private var canAutoRetry = true
    /// 当前转写开始的时刻，判断它是否已经正常跑了 `healthyAfter`
    @ObservationIgnored private var currentStartedAt: Date?
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private var stopped = false

    /// 创建即开始准备语音模型。now 只给测试替换
    public init(engine: any StreamingTranscriber, recordingStartedAt: Date, hotwords: [String],
                now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.recordingStartedAt = recordingStartedAt
        self.hotwords = hotwords
        self.now = now
        prepare()
    }

    /// 送入一块音频。at 是这块音频的墙钟时间（取收到的时刻即可）。
    /// 准备中、暂停、出错时直接丢掉
    public func append(_ buffer: AVAudioPCMBuffer, at time: Date) {
        guard status == .running, !stopped else { return }
        if let current, current.format != buffer.format {
            // 切换了麦克风：旧的转写把已送入的部分识别完再结束，它的定稿句子照常显示
            current.transcription.finish()
            self.current = nil
        }
        if current == nil { begin(format: buffer.format, at: time) }
        current?.transcription.append(buffer)
    }

    /// 面板不可见：停掉引擎、释放模型，丢掉没定稿的文字。恢复时在字幕里插入分隔行。
    /// 准备中也可以暂停（准备照常进行）；出错时不理会
    public func pause() {
        guard failure == nil, pausedAt == nil, !stopped else { return }
        cancelTranscriptions()
        pausedAt = now()
    }

    /// 面板恢复可见：插入分隔行，之后来的第一块音频开始新的转写
    public func resume() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        insertGap(from: pausedAt)
    }

    /// 出错后用户点“重试”：重新准备，出错到现在的这段插入分隔行
    public func retry() {
        guard failure != nil, !stopped else { return }
        failure = nil
        if let failedAt { insertGap(from: failedAt) }
        failedAt = nil
        prepare()
    }

    /// 录音结束：停掉引擎，之后什么都不做
    public func stop() {
        stopped = true
        prepareToken += 1
        cancelTranscriptions()
    }

    private func begin(format: AVAudioFormat, at time: Date) {
        nextToken += 1
        let token = nextToken
        let transcription = engine.start(format: format, hotwords: hotwords)
        current = (token, format, transcription)
        currentStartedAt = now()
        live[token] = transcription
        // 引擎的时间从这次转写的第一块音频算起，换算到录音里
        let anchor = time.timeIntervalSince(recordingStartedAt)
        Task { [weak self] in
            for await event in transcription.events {
                guard let self, self.live[token] != nil else { return }
                self.handle(event, token: token, anchor: anchor)
            }
            self?.ended(token)
        }
    }

    private func handle(_ event: StreamingTranscriptionEvent, token: Int, anchor: TimeInterval) {
        switch event {
        case .volatile(let text, let start):
            // 换格式后收尾中的旧转写：临时文字不再显示，只等它的定稿句子
            guard current?.token == token else { return }
            volatile = text.isEmpty ? nil : LiveCaptionVolatile(text: text, start: anchor + start)
            volatileOwner = volatile == nil ? nil : token
            if !text.isEmpty { producedResult(token) }
        case .sentence(let s):
            producedResult(token)
            if volatileOwner == token { clearVolatile() }
            lines.append(.sentence(LiveCaption(id: nextID, start: anchor + s.start, end: anchor + s.end, text: s.text)))
            nextID += 1
            trim()
        case .failed(let reason):
            // 收尾中的旧转写出错不影响新的
            guard current?.token == token else { return }
            fail(reason)
        }
    }

    /// 事件流结束。当前的转写意外结束时，下一块音频开新的。
    /// 它留下的浅色字不会再定稿了（如分析器自己停了，没发 `.failed` 也没吐出句子），清掉
    private func ended(_ token: Int) {
        live[token] = nil
        if current?.token == token { current = nil }
        if volatileOwner == token { clearVolatile() }
    }

    private func clearVolatile() {
        volatile = nil
        volatileOwner = nil
    }

    /// 当前转写出了非空的结果。它已经跑了 `healthyAfter` 就重新允许自动重试
    private func producedResult(_ token: Int) {
        guard current?.token == token, let currentStartedAt,
              now().timeIntervalSince(currentStartedAt) >= Self.healthyAfter else { return }
        canAutoRetry = true
    }

    private func fail(_ reason: String) {
        cancelTranscriptions()
        if canAutoRetry {
            canAutoRetry = false
            prepare()
        } else {
            failure = reason
            failedAt = now()
        }
    }

    private func prepare() {
        prepareToken += 1
        let token = prepareToken
        isPrepared = false
        progress = 0
        let engine = engine
        Task { [weak self] in
            do {
                try await engine.prepare { p in
                    Task { @MainActor in
                        guard let self, self.prepareToken == token, !self.isPrepared else { return }
                        self.progress = p
                    }
                }
                guard let self, self.prepareToken == token else { return }
                self.isPrepared = true
            } catch {
                guard let self, self.prepareToken == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func cancelTranscriptions() {
        for transcription in live.values { transcription.cancel() }
        live.removeAll()
        current = nil
        clearVolatile()
    }

    private func insertGap(from start: Date) {
        let start = start.timeIntervalSince(recordingStartedAt)
        let end = now().timeIntervalSince(recordingStartedAt)
        if case .gap(var last) = lines.last {
            // 上次恢复后一句字幕都没出就又停了：合成一行
            last.duration = end - last.start
            lines[lines.count - 1] = .gap(last)
        } else {
            lines.append(.gap(LiveCaptionGap(id: nextID, start: start, duration: end - start)))
            nextID += 1
        }
    }

    /// 只留最近 `Self.limit` 句。丢到最后顶上剩下的分隔行说的是已经看不到的那段，一并丢掉
    private func trim() {
        var excess = lines.count { if case .sentence = $0 { true } else { false } } - Self.limit
        guard excess > 0 else { return }
        var drop = 0
        for line in lines {
            if case .sentence = line {
                if excess == 0 { break }
                excess -= 1
            }
            drop += 1
        }
        lines.removeFirst(drop)
    }
}
