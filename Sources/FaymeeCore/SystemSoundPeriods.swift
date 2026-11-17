import Foundation

/// 录音中系统声音的记录：开关打开的时段、系统声音分片。由 App 模型在录音中、停止和中断恢复时调用
extension Meeting {
    /// 系统声音开关打开了一段、还没结束
    public var isSystemSoundPeriodOpen: Bool {
        systemSoundPeriodList.last.map { $0.end == nil } ?? false
    }

    /// 开关打开（或开着开始录音）。已经有一段没结束时不再开
    public mutating func beginSystemSoundPeriod(at date: Date) {
        guard !isSystemSoundPeriodOpen else { return }
        systemSoundPeriodList.append(WallClockPeriod(start: date))
    }

    /// 开关关闭。没有在进行的时段时什么也不做
    public mutating func endSystemSoundPeriod(at date: Date) {
        guard isSystemSoundPeriodOpen else { return }
        systemSoundPeriodList[systemSoundPeriodList.count - 1].end = date
    }

    /// 记下一个刚打开的系统声音分片。已经记过（按文件名）时不再记，返回 false
    @discardableResult
    public mutating func addSystemSoundSegment(_ segment: SystemSoundSegment) -> Bool {
        guard !systemSoundSegmentList.contains(where: { $0.file == segment.file }) else { return false }
        systemSoundSegmentList.append(segment)
        return true
    }

    /// 录音结束（停止，或中断后恢复）：结束仍在进行的合盖空白、系统声音时段、系统声音不可用时段。
    /// 中断恢复时 date 只是估计，可能早于之后才开始的那段，这时结束在起点
    public mutating func endOpenPeriods(at date: Date) {
        if let i = openGap { lidGaps[i].end = max(date, lidGaps[i].start) }
        // 空列表经 …List 写回仍是 nil，没开过系统声音的会议不会多出字段
        systemSoundPeriodList = Self.ending(systemSoundPeriodList, at: date)
        systemSoundUnavailablePeriodList = Self.ending(systemSoundUnavailablePeriodList, at: date)
    }

    private static func ending(_ periods: [WallClockPeriod], at date: Date) -> [WallClockPeriod] {
        periods.map { p in
            var p = p
            if p.end == nil { p.end = max(date, p.start) }
            return p
        }
    }
}

extension SystemSoundSegment {
    /// 写盘模块交出的分片，记进会议数据
    public init(_ segment: SystemSoundWriter.Segment) {
        self.init(file: segment.file, startedAt: segment.startedAt, sampleRate: segment.sampleRate,
                  channels: segment.channels)
    }
}
