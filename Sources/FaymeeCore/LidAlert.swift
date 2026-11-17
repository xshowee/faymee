import Foundation

/// 录音中合盖的提醒文字。合盖当下按此刻在不在录系统声音说（由 App 传入：采集在跑才算，开关开着但没建起来
/// 不算）；开盖后和面板摘要说的是已经过去的合盖，按会议数据里记的时段推，与详情页的分组一致。
/// 系统声音没在录时，文字与以前逐字相同
public enum LidAlert {
    /// 合盖、内置麦克风被断开时的通知（屏幕看得见时才发）
    public static func closedNotice(capturingSystemSound: Bool) -> MeetingNotice {
        MeetingNotice(title: "内置麦克风已断开",
                      body: "MacBook 合盖后内置麦克风无法收音，\(now(capturingSystemSound))。请打开盖子，或改用外接麦克风。")
    }

    /// 合盖中菜单栏面板里的提示
    public static func closedStatus(capturingSystemSound: Bool) -> String {
        "已合盖，内置麦克风被断开，\(now(capturingSystemSound))。请打开盖子，或改用外接麦克风。"
    }

    private static func now(_ capturingSystemSound: Bool) -> String {
        capturingSystemSound ? "现在只录到系统声音" : "现在没有在录"
    }
}

extension Meeting {
    /// 一段合盖结束（开盖）后的通知：整段只录到系统声音、整段什么都没录到、部分时段没录到三种说法
    public func lidReopenedNotice(for gap: Gap) -> MeetingNotice {
        let kinds = Set(lidGapPieces(gap).map(\.kind))
        let title = if kinds == [.systemSoundOnly] {
            "合盖期间只录到系统声音"
        } else if kinds.contains(.systemSoundOnly) {
            "合盖期间部分时段没有录到声音"
        } else {
            "合盖期间没有录到声音"
        }
        return MeetingNotice(title: title, body: formatTimeRange(gap))
    }

    /// 菜单栏面板里本次已经结束的合盖的摘要；没有时为 nil。段数按详情页里列出的段数
    /// （一段合盖跨过系统声音的切换时拆开算）
    public var lidGapSummary: String? {
        let kinds = lidGaps.filter { $0.end != nil }.flatMap(lidGapPieces).map(\.kind)
        let systemSoundOnly = kinds.count { $0 == .systemSoundOnly }
        let missed = kinds.count - systemSoundOnly
        var parts: [String] = []
        if missed > 0 { parts.append("\(missed) 段因合盖没有录到声音") }
        if systemSoundOnly > 0 {
            parts.append(missed > 0 ? "\(systemSoundOnly) 段只录到系统声音" : "\(systemSoundOnly) 段合盖时只录到系统声音")
        }
        guard !parts.isEmpty else { return nil }
        return "本次有 \(parts.joined(separator: "、"))，可在会议记录里查看"
    }
}
