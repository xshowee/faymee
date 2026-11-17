import Foundation

/// 录音中“没有声音”的判断和提醒。系统声音没在录时只看麦克风；在录时两路都低于阈值、持续到告警时长
/// 才算没有声音，麦克风单独没声音（闭麦旁听线上会议）不算。由 App 在收到电平时喂进来、每秒检查一次
public struct SilenceWatch: Sendable {
    /// 低于此电平视为没有声音（dBFS）。合盖后内置麦克风被硬件断开，读到的是全 0（-160）
    public static let threshold: Float = -65
    /// 持续无声多久后告警
    public static let alertAfter: TimeInterval = 20

    public struct Check: Hashable, Sendable {
        /// 此刻算没有声音（菜单栏图标和面板里显示警告）
        public var isSilent: Bool
        /// 要发的通知；nil 表示不发（有声音、还不够久、已经提醒过、此刻不能提醒）
        public var notice: MeetingNotice?
    }

    /// 麦克风从何时起一直低于阈值；nil 表示最近一次有声音
    private var micQuietSince: Date?
    /// 最近一次系统声音达到阈值的时刻；从没有过为 nil。没有声音播放时系统声音可能完全没有数据，
    /// 所以不记“从何时起安静”，没数据就是安静
    private var systemSoundHeardAt: Date?
    /// 已经提醒过的那段无声从何时算起。有过声音后无声的起点变晚了，才会再提醒
    private var notifiedQuietSince: Date?

    public init() {}

    public mutating func micLevel(_ db: Float, at time: Date) {
        if db < Self.threshold {
            micQuietSince = micQuietSince ?? time
        } else {
            micQuietSince = nil
        }
    }

    /// 系统声音在截至 time 的一小段里的峰值电平（App 每秒取一次）
    public mutating func systemSoundLevel(_ db: Float, at time: Date) {
        if db >= Self.threshold { systemSoundHeardAt = time }
    }

    /// 每秒检查一次。`includesSystemSound`：此刻在录系统声音（开关开着且采集在跑）；
    /// `canNotify`：此刻能发通知（没在合盖，合盖由合盖的提醒负责；屏幕看得见）。不能发时不算提醒过，
    /// 等能发时还会发
    public mutating func check(at now: Date, includesSystemSound: Bool, canNotify: Bool) -> Check {
        guard let since = quietSince(includesSystemSound: includesSystemSound),
              now.timeIntervalSince(since) >= Self.alertAfter else {
            return Check(isSilent: false, notice: nil)
        }
        // 只有起点晚于提醒过的那段（中间有过声音）才再提醒；切换系统声音开关会让起点前后跳，不算
        guard canNotify, notifiedQuietSince.map({ since > $0 }) ?? true else {
            return Check(isSilent: true, notice: nil)
        }
        notifiedQuietSince = since
        let what = includesSystemSound ? "麦克风和系统声音已经 \(Int(Self.alertAfter)) 秒都没有声音了"
                                       : "已经 \(Int(Self.alertAfter)) 秒没有声音了"
        return Check(isSilent: true, notice: MeetingNotice(
            title: "Faymee 可能没录到声音", body: "\(what)。MacBook 合盖时内置麦克风会被断开，请检查麦克风。"))
    }

    /// 要看的几路从何时起都没有声音；nil 表示此刻有声音
    private func quietSince(includesSystemSound: Bool) -> Date? {
        guard let mic = micQuietSince else { return nil }
        guard includesSystemSound, let heard = systemSoundHeardAt else { return mic }
        return max(mic, heard)
    }

    /// 菜单栏面板里没有声音时的提示
    public static func statusText(includesSystemSound: Bool) -> String {
        includesSystemSound ? "麦克风和系统声音都长时间没有声音，请检查麦克风。" : "长时间没有声音，请检查麦克风。"
    }
}
