import AVFoundation
import Foundation

/// 无服务端时间戳时的纯文本两级本地时间轴对齐：
/// 1) 优先调用本机参考转写器获取字级锚点，经单调 DP 与线性插值对齐后按句末标点与停顿切句；
/// 2) 参考转写不可用或无有效锚点时，按音频能量检测静音停顿并按字数比例分配时间轴。
enum TranscriptTimelineAlignment {
    static let pauseThreshold: TimeInterval = SentenceSplitter.pause
    private static let terminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…"]

    static func align(
        onlineText: String,
        audioURL: URL,
        hotwords: [String],
        referenceTranscriber: (any Transcriber)?
    ) async throws -> [TranscribedSentence] {
        let trimmed = onlineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let measuredDuration = await audioDuration(of: audioURL)

        // 第一层：本机参考转写器锚点对齐
        if let referenceTranscriber {
            do {
                try Task.checkCancellation()
                let refSentences = try await referenceTranscriber.transcribe(
                    audio: audioURL,
                    hotwords: hotwords,
                    progress: { _ in }
                )
                try Task.checkCancellation()
                if let aligned = alignWithReference(
                    onlineText: trimmed,
                    referenceSentences: refSentences,
                    audioDuration: measuredDuration
                ) {
                    return aligned
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // 非取消错误：自动回退到第二层静音检测比例对齐
            }
        }

        // 第二层：音频能量/静音停顿检测 + 按字数比例连续分配时间轴
        try Task.checkCancellation()
        return try await alignBySilenceAndProportion(
            onlineText: trimmed,
            audioURL: audioURL,
            fallbackDuration: measuredDuration ?? 0
        )
    }

    static func audioDuration(of url: URL) async -> TimeInterval? {
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            let duration = Double(file.length) / file.processingFormat.sampleRate
            if duration.isFinite && duration >= 0 { return duration }
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration >= 0 {
            return duration
        }
        return nil
    }

    // MARK: - 第一层：参考转写器 DP 锚点对齐

    private struct CharAnchor {
        var char: Character
        var start: TimeInterval
        var end: TimeInterval
    }

    static func alignWithReference(
        onlineText: String,
        referenceSentences: [TranscribedSentence],
        audioDuration: TimeInterval?
    ) -> [TranscribedSentence]? {
        let anchors = buildAnchors(from: referenceSentences, audioDuration: audioDuration)
        guard !anchors.isEmpty else { return nil }

        let onlineChars = Array(onlineText)
        var matchOriginalIndices: [Int] = []
        var onlineMatchChars: [Character] = []
        var matchIndexForOriginal = [Int?](repeating: nil, count: onlineChars.count)

        for (i, ch) in onlineChars.enumerated() {
            if let norm = normalizedMatchChar(ch) {
                matchIndexForOriginal[i] = onlineMatchChars.count
                matchOriginalIndices.append(i)
                onlineMatchChars.append(norm)
            }
        }
        guard !onlineMatchChars.isEmpty else { return nil }

        let refChars = anchors.map(\.char)
        let matchedPairs = hirschbergLCS(onlineMatchChars, refChars)
        guard !matchedPairs.isEmpty else { return nil }

        let maxAnchorEnd = anchors.last?.end ?? 0
        let effectiveDuration: TimeInterval = if let audioDuration, audioDuration > 0 {
            audioDuration
        } else {
            maxAnchorEnd
        }

        let charTimes = interpolateCharTimes(
            matchCount: onlineMatchChars.count,
            matchedPairs: matchedPairs,
            anchors: anchors,
            duration: effectiveDuration
        )

        return splitWithCharTimes(
            onlineChars: onlineChars,
            matchIndexForOriginal: matchIndexForOriginal,
            charTimes: charTimes,
            duration: effectiveDuration
        )
    }

    private static func buildAnchors(
        from sentences: [TranscribedSentence],
        audioDuration: TimeInterval?
    ) -> [CharAnchor] {
        var anchors: [CharAnchor] = []
        var cursor: TimeInterval = 0

        for sentence in sentences {
            let chars = sentence.text.compactMap(normalizedMatchChar)
            guard !chars.isEmpty else { continue }

            var start = max(cursor, max(0, sentence.start))
            var end = max(start, sentence.end)
            if let audioDuration, audioDuration > 0 {
                start = min(start, audioDuration)
                end = min(max(start, end), audioDuration)
            }

            let step = (end - start) / Double(chars.count)
            for (idx, ch) in chars.enumerated() {
                let cStart = start + Double(idx) * step
                let cEnd = idx == chars.count - 1 ? end : start + Double(idx + 1) * step
                anchors.append(CharAnchor(char: ch, start: cStart, end: max(cStart, cEnd)))
            }
            cursor = end
        }
        return anchors
    }

    private static func interpolateCharTimes(
        matchCount: Int,
        matchedPairs: [(online: Int, ref: Int)],
        anchors: [CharAnchor],
        duration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var times = Array(repeating: (start: 0.0, end: 0.0), count: matchCount)
        for (oi, ri) in matchedPairs {
            times[oi] = (anchors[ri].start, anchors[ri].end)
        }

        func fillGap(_ range: Range<Int>, from t0: TimeInterval, to t1: TimeInterval) {
            guard !range.isEmpty else { return }
            let start = max(0, t0)
            let end = max(start, t1)
            let count = Double(range.count)
            for (offset, idx) in range.enumerated() {
                let s = start + (end - start) * (Double(offset) / count)
                let e = offset == range.count - 1 ? end : start + (end - start) * (Double(offset + 1) / count)
                times[idx] = (s, max(s, e))
            }
        }

        let first = matchedPairs[0]
        if first.online > 0 {
            let leadStart = first.ref > 0 ? anchors[0].start : 0.0
            fillGap(0..<first.online, from: leadStart, to: times[first.online].start)
        }

        for k in 0..<(matchedPairs.count - 1) {
            let cur = matchedPairs[k]
            let next = matchedPairs[k + 1]
            if next.online - cur.online > 1 {
                fillGap((cur.online + 1)..<next.online, from: times[cur.online].end, to: times[next.online].start)
            }
        }

        let last = matchedPairs[matchedPairs.count - 1]
        if last.online + 1 < matchCount {
            let tailEnd: TimeInterval = if last.ref + 1 < anchors.count {
                duration > 0 ? min(duration, anchors[anchors.count - 1].end) : anchors[anchors.count - 1].end
            } else {
                max(times[last.online].end, duration)
            }
            fillGap((last.online + 1)..<matchCount, from: times[last.online].end, to: tailEnd)
        }

        // 严格单调与边界夹紧
        var cursor: TimeInterval = 0
        for i in times.indices {
            var s = max(cursor, times[i].start)
            var e = max(s, times[i].end)
            if duration > 0 {
                s = min(s, duration)
                e = min(max(s, e), duration)
            }
            times[i] = (s, e)
            cursor = e
        }
        return times
    }

    private static func splitWithCharTimes(
        onlineChars: [Character],
        matchIndexForOriginal: [Int?],
        charTimes: [(start: TimeInterval, end: TimeInterval)],
        duration: TimeInterval
    ) -> [TranscribedSentence] {
        var sentences: [TranscribedSentence] = []
        var buffer: [Character] = []
        var bufferMatches: [Int] = []

        func closeCurrent() {
            let text = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let firstM = bufferMatches.first, let lastM = bufferMatches.last {
                sentences.append(TranscribedSentence(
                    start: charTimes[firstM].start,
                    end: charTimes[lastM].end,
                    text: text
                ))
            }
            buffer.removeAll(keepingCapacity: true)
            bufferMatches.removeAll(keepingCapacity: true)
        }

        func closeBeforeNextMatch() {
            var carriedOpening: [Character] = []
            while let last = buffer.last, isOpeningPunctuation(last) {
                carriedOpening.insert(buffer.removeLast(), at: 0)
            }
            closeCurrent()
            buffer = carriedOpening
        }

        var i = 0
        while i < onlineChars.count {
            let ch = onlineChars[i]

            if let mIdx = matchIndexForOriginal[i] {
                if let prevM = bufferMatches.last {
                    let gap = charTimes[mIdx].start - charTimes[prevM].end
                    if gap >= pauseThreshold, !isInsideASCIIWord(onlineChars, at: i) {
                        closeBeforeNextMatch()
                    }
                }
                buffer.append(ch)
                bufferMatches.append(mIdx)
                i += 1
                continue
            }

            buffer.append(ch)
            if isSentenceTerminator(ch, in: onlineChars, at: i) {
                appendTrailingTerminatorsAndClosers(from: onlineChars, index: &i, into: &buffer)
                closeCurrent()
            }
            i += 1
        }
        closeCurrent()

        return normalizeSentences(sentences, duration: duration)
    }

    // MARK: - 第二层：音频能量静音检测与字数比例对齐

    private static func alignBySilenceAndProportion(
        onlineText: String,
        audioURL: URL,
        fallbackDuration: TimeInterval
    ) async throws -> [TranscribedSentence] {
        let analysis = try await analyzeSpeechRegions(audioURL: audioURL, fallbackDuration: fallbackDuration)
        let duration = max(analysis.duration, fallbackDuration)
        let initialChunks = splitByPunctuation(onlineText)
        guard !initialChunks.isEmpty else { return [] }

        let chunks = splitChunksAlongPauses(initialChunks, speechRegions: analysis.speechRegions)
        let sentences = allocateSentences(chunks, across: analysis.speechRegions, totalDuration: duration)
        return normalizeSentences(sentences, duration: duration)
    }

    private struct SpeechAnalysis {
        var duration: TimeInterval
        var speechRegions: [(start: TimeInterval, end: TimeInterval)]
    }

    private static func analyzeSpeechRegions(
        audioURL: URL,
        fallbackDuration: TimeInterval
    ) async throws -> SpeechAnalysis {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try computeSpeechRegionsSync(audioURL: audioURL, fallbackDuration: fallbackDuration, flag: flag)
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private static func computeSpeechRegionsSync(
        audioURL: URL,
        fallbackDuration: TimeInterval,
        flag: CancelFlag
    ) throws -> SpeechAnalysis {
        try flag.check()
        guard let file = try? AVAudioFile(forReading: audioURL),
              file.processingFormat.sampleRate > 0,
              file.length > 0
        else {
            let d = max(0, fallbackDuration)
            return SpeechAnalysis(duration: d, speechRegions: d > 0 ? [(0, d)] : [])
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let duration = Double(file.length) / sampleRate
        let windowSeconds = 0.02
        let windowSamples = max(1, Int((sampleRate * windowSeconds).rounded()))
        let channels = max(1, Int(format.channelCount))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            return SpeechAnalysis(duration: duration, speechRegions: [(0, duration)])
        }

        var rmsFrames: [Float] = []
        rmsFrames.reserveCapacity(Int(duration / windowSeconds) + 1)
        var sumSquares = 0.0
        var countInWindow = 0

        while file.framePosition < file.length {
            try flag.check()
            buffer.frameLength = 0
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { break }

            for i in 0..<frameCount {
                var sampleEnergy = 0.0
                for c in 0..<channels {
                    let sample = Double(channelData[c][i])
                    sampleEnergy += sample * sample
                }
                sumSquares += sampleEnergy / Double(channels)
                countInWindow += 1
                if countInWindow >= windowSamples {
                    rmsFrames.append(Float((sumSquares / Double(countInWindow)).squareRoot()))
                    sumSquares = 0
                    countInWindow = 0
                }
            }
        }
        if countInWindow > 0 {
            rmsFrames.append(Float((sumSquares / Double(countInWindow)).squareRoot()))
        }

        guard !rmsFrames.isEmpty else {
            return SpeechAnalysis(duration: duration, speechRegions: [(0, duration)])
        }

        let sorted = rmsFrames.sorted()
        let p10 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.10))]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        guard p95 >= 1e-4 else {
            return SpeechAnalysis(duration: duration, speechRegions: [(0, duration)])
        }

        let threshold = max(Float(1e-4), min(Float(0.02), max(p10 * 2.5, p95 * 0.12)))
        let minSilenceFrames = max(1, Int((pauseThreshold / windowSeconds).rounded()))

        guard let firstActive = rmsFrames.firstIndex(where: { $0 > threshold }),
              let lastActive = rmsFrames.lastIndex(where: { $0 > threshold })
        else {
            return SpeechAnalysis(duration: duration, speechRegions: [(0, duration)])
        }

        var regions: [(start: TimeInterval, end: TimeInterval)] = []
        var regionStartFrame = firstActive
        var silenceStart: Int?

        for idx in firstActive...lastActive {
            if rmsFrames[idx] <= threshold {
                if silenceStart == nil { silenceStart = idx }
            } else if let sStart = silenceStart {
                if idx - sStart >= minSilenceFrames {
                    let rStart = min(duration, Double(regionStartFrame) * windowSeconds)
                    let rEnd = min(duration, Double(sStart) * windowSeconds)
                    if rEnd > rStart { regions.append((rStart, rEnd)) }
                    regionStartFrame = idx
                }
                silenceStart = nil
            }
        }
        let tailStart = min(duration, Double(regionStartFrame) * windowSeconds)
        let tailEnd = min(duration, Double(lastActive + 1) * windowSeconds)
        if tailEnd > tailStart {
            regions.append((tailStart, tailEnd))
        }

        if regions.isEmpty {
            regions = [(0, duration)]
        }
        return SpeechAnalysis(duration: duration, speechRegions: regions)
    }

    private static func splitChunksAlongPauses(
        _ chunks: [String],
        speechRegions: [(start: TimeInterval, end: TimeInterval)]
    ) -> [String] {
        guard speechRegions.count >= 2 else { return chunks }
        let durations = speechRegions.map { max(0, $0.end - $0.start) }
        let totalSpeech = durations.reduce(0, +)
        guard totalSpeech > 0 else { return chunks }

        var pauseFractions: [Double] = []
        var cumSpeech = 0.0
        for i in 0..<(durations.count - 1) {
            cumSpeech += durations[i]
            pauseFractions.append(cumSpeech / totalSpeech)
        }

        let weights = chunks.map { max(1, contentCharacterCount($0)) }
        let totalWeight = Double(weights.reduce(0, +))
        var result: [String] = []
        var cumWeight = 0.0

        for (idx, chunk) in chunks.enumerated() {
            let w = Double(weights[idx])
            let fracStart = cumWeight / totalWeight
            let fracEnd = (cumWeight + w) / totalWeight
            cumWeight += w

            let insidePauses = pauseFractions.filter { $0 > fracStart && $0 < fracEnd }
            result.append(contentsOf: recursivelySplitChunk(
                chunk,
                fracStart: fracStart,
                fracEnd: fracEnd,
                pauses: insidePauses
            ))
        }
        return result
    }

    private static func recursivelySplitChunk(
        _ chunk: String,
        fracStart: Double,
        fracEnd: Double,
        pauses: [Double]
    ) -> [String] {
        guard !pauses.isEmpty, fracEnd > fracStart, contentCharacterCount(chunk) >= 12 else {
            return [chunk]
        }
        let midIdx = pauses.count / 2
        let midPause = pauses[midIdx]
        let relativeTarget = (midPause - fracStart) / (fracEnd - fracStart)

        guard let (left, right) = splitTextNearPause(chunk, targetFraction: relativeTarget) else {
            return [chunk]
        }

        let leftW = Double(max(1, contentCharacterCount(left)))
        let rightW = Double(max(1, contentCharacterCount(right)))
        let actualSplitFrac = fracStart + (fracEnd - fracStart) * (leftW / (leftW + rightW))

        var remaining = pauses
        remaining.remove(at: midIdx)
        let leftPauses = remaining.filter { $0 > fracStart && $0 < actualSplitFrac }
        let rightPauses = remaining.filter { $0 > actualSplitFrac && $0 < fracEnd }
        return recursivelySplitChunk(left, fracStart: fracStart, fracEnd: actualSplitFrac, pauses: leftPauses)
            + recursivelySplitChunk(right, fracStart: actualSplitFrac, fracEnd: fracEnd, pauses: rightPauses)
    }

    private static func splitTextNearPause(_ text: String, targetFraction: Double) -> (String, String)? {
        let chars = Array(text)
        let totalContent = contentCharacterCount(text)
        guard totalContent >= 12 else { return nil }

        let minSide = 6
        let maxLeft = totalContent - minSide
        let targetLeft = min(maxLeft, max(minSide, Int((targetFraction * Double(totalContent)).rounded())))
        let window = max(4, totalContent / 5)

        var prefixContent = [Int](repeating: 0, count: chars.count)
        var running = 0
        for i in chars.indices {
            if isContentCharacter(chars[i]) { running += 1 }
            prefixContent[i] = running
        }

        let softPunctuations: Set<Character> = ["，", ",", "、", "：", ":", "—", "–"]
        var bestSoft: (pos: Int, distance: Int)?
        var bestSpace: (pos: Int, distance: Int)?
        var bestChar: (pos: Int, distance: Int)?

        for pos in 0..<(chars.count - 1) {
            let leftCount = prefixContent[pos]
            let rightCount = totalContent - leftCount
            guard leftCount >= minSide, rightCount >= minSide else { continue }
            guard !isInsideASCIIWord(chars, at: pos + 1) else { continue }
            guard !isOpeningPunctuation(chars[pos]), !isTrailingClosingPunctuation(chars[pos + 1]) else { continue }

            let dist = abs(leftCount - targetLeft)
            if dist <= window {
                if softPunctuations.contains(chars[pos]) {
                    if bestSoft == nil || dist < bestSoft!.distance {
                        bestSoft = (pos, dist)
                    }
                } else if chars[pos].isWhitespace || chars[pos + 1].isWhitespace {
                    if bestSpace == nil || dist < bestSpace!.distance {
                        bestSpace = (pos, dist)
                    }
                }
            }
            if bestChar == nil || dist < bestChar!.distance {
                bestChar = (pos, dist)
            }
        }

        guard let chosen = bestSoft?.pos ?? bestSpace?.pos ?? bestChar?.pos else { return nil }
        let left = String(chars[0...chosen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(chars[(chosen + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    private static func allocateSentences(
        _ chunks: [String],
        across regions: [(start: TimeInterval, end: TimeInterval)],
        totalDuration: TimeInterval
    ) -> [TranscribedSentence] {
        guard !chunks.isEmpty else { return [] }
        if regions.isEmpty {
            return proportionalAcross(chunks, start: 0, end: totalDuration)
        }
        if regions.count == 1 {
            return proportionalAcross(chunks, start: regions[0].start, end: regions[0].end)
        }

        let weights = chunks.map { max(1, contentCharacterCount($0)) }
        let totalWeight = Double(weights.reduce(0, +))

        if chunks.count >= regions.count {
            let boundaries = matchPauseBoundaries(
                weights: weights,
                totalWeight: totalWeight,
                regions: regions
            )
            var result: [TranscribedSentence] = []
            for r in regions.indices {
                let slice = Array(chunks[boundaries[r]..<boundaries[r + 1]])
                result.append(contentsOf: proportionalAcross(slice, start: regions[r].start, end: regions[r].end))
            }
            return result
        }

        // 句子数少于语段数时，按累计字数比例直接映射到有效语段拼接时间轴
        var result: [TranscribedSentence] = []
        var cumWeight = 0.0
        for (idx, chunk) in chunks.enumerated() {
            let f0 = cumWeight / totalWeight
            cumWeight += Double(weights[idx])
            let f1 = cumWeight / totalWeight
            let start = audioTime(forSpeechFraction: f0, in: regions)
            let end = audioTime(forSpeechFraction: f1, in: regions)
            result.append(TranscribedSentence(start: start, end: max(start, end), text: chunk))
        }
        return result
    }

    private static func matchPauseBoundaries(
        weights: [Int],
        totalWeight: Double,
        regions: [(start: TimeInterval, end: TimeInterval)]
    ) -> [Int] {
        let sCount = weights.count
        let kCount = regions.count
        let pauseCount = kCount - 1

        var cumChunkFracs = [Double](repeating: 0, count: sCount)
        var wAcc = 0
        for i in 0..<sCount {
            wAcc += weights[i]
            cumChunkFracs[i] = Double(wAcc) / totalWeight
        }

        let durations = regions.map { max(0, $0.end - $0.start) }
        let totalSpeech = max(1e-9, durations.reduce(0, +))
        var pauseFracs = [Double](repeating: 0, count: pauseCount)
        var tAcc = 0.0
        for i in 0..<pauseCount {
            tAcc += durations[i]
            pauseFracs[i] = tAcc / totalSpeech
        }

        // dp[j][b]: 前 j+1 个停顿对齐到句边界下标 b（1...sCount-1）的最小累计偏差
        let inf = Double.infinity
        var dp = Array(repeating: Array(repeating: inf, count: sCount), count: pauseCount)
        var choice = Array(repeating: Array(repeating: 0, count: sCount), count: pauseCount)

        for b in 1...(sCount - kCount + 1) {
            dp[0][b] = abs(cumChunkFracs[b - 1] - pauseFracs[0])
        }
        if pauseCount > 1 {
            for j in 1..<pauseCount {
                let minB = j + 1
                let maxB = sCount - (kCount - 1 - j)
                for b in minB...maxB {
                    let cost = abs(cumChunkFracs[b - 1] - pauseFracs[j])
                    var bestPrev = minB - 1
                    var bestVal = inf
                    for prev in j..<b {
                        if dp[j - 1][prev] < bestVal {
                            bestVal = dp[j - 1][prev]
                            bestPrev = prev
                        }
                    }
                    dp[j][b] = bestVal + cost
                    choice[j][b] = bestPrev
                }
            }
        }

        var lastBestB = pauseCount
        var lastBestVal = inf
        for b in pauseCount...(sCount - 1) {
            if dp[pauseCount - 1][b] < lastBestVal {
                lastBestVal = dp[pauseCount - 1][b]
                lastBestB = b
            }
        }

        var internalBoundaries = [Int](repeating: 0, count: pauseCount)
        var curr = lastBestB
        for j in (0..<pauseCount).reversed() {
            internalBoundaries[j] = curr
            curr = choice[j][curr]
        }
        return [0] + internalBoundaries + [sCount]
    }

    private static func audioTime(
        forSpeechFraction fraction: Double,
        in regions: [(start: TimeInterval, end: TimeInterval)]
    ) -> TimeInterval {
        let clamped = min(1, max(0, fraction))
        let totalSpeech = regions.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard totalSpeech > 0 else { return regions.first?.start ?? 0 }
        let target = clamped * totalSpeech
        var acc = 0.0
        for (idx, r) in regions.enumerated() {
            let len = max(0, r.end - r.start)
            if idx == regions.count - 1 || acc + len >= target {
                let offset = max(0, min(len, target - acc))
                return r.start + offset
            }
            acc += len
        }
        return regions.last?.end ?? 0
    }

    private static func proportionalAcross(
        _ chunks: [String],
        start: TimeInterval,
        end: TimeInterval
    ) -> [TranscribedSentence] {
        guard !chunks.isEmpty else { return [] }
        let span = max(0, end - start)
        let weights = chunks.map { max(1, contentCharacterCount($0)) }
        let total = Double(weights.reduce(0, +))
        var cursor = start
        var result: [TranscribedSentence] = []
        for (idx, chunk) in chunks.enumerated() {
            let frac = Double(weights[idx]) / total
            let segEnd = idx == chunks.count - 1 ? end : min(end, cursor + span * frac)
            result.append(TranscribedSentence(start: cursor, end: max(cursor, segEnd), text: chunk))
            cursor = max(cursor, segEnd)
        }
        return result
    }

    // MARK: - 文本切句辅助与单调规范化

    private static func splitByPunctuation(_ text: String) -> [String] {
        let chars = Array(text)
        var chunks: [String] = []
        var buffer: [Character] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            buffer.append(ch)
            if isSentenceTerminator(ch, in: chars, at: i) {
                appendTrailingTerminatorsAndClosers(from: chars, index: &i, into: &buffer)
                let trimmed = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                buffer.removeAll(keepingCapacity: true)
            }
            i += 1
        }
        let tail = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    private static func appendTrailingTerminatorsAndClosers(
        from chars: [Character],
        index: inout Int,
        into buffer: inout [Character]
    ) {
        while index + 1 < chars.count {
            let next = chars[index + 1]
            if isSentenceTerminator(next, in: chars, at: index + 1) || isTrailingClosingPunctuation(next) {
                index += 1
                buffer.append(next)
            } else {
                break
            }
        }
    }

    private static func normalizeSentences(_ raw: [TranscribedSentence], duration: TimeInterval) -> [TranscribedSentence] {
        var result: [TranscribedSentence] = []
        var cursor: TimeInterval = 0
        for item in raw {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var start = max(cursor, max(0, item.start))
            var end = max(start, item.end)
            if duration > 0 {
                start = min(start, duration)
                end = min(max(start, end), duration)
            }
            result.append(TranscribedSentence(start: start, end: end, text: trimmed))
            cursor = end
        }
        return result
    }

    private static func isContentCharacter(_ ch: Character) -> Bool {
        !(ch.isWhitespace || ch.isPunctuation)
    }

    private static func normalizedMatchChar(_ ch: Character) -> Character? {
        guard isContentCharacter(ch) else { return nil }
        let lowered = String(ch).lowercased()
        return lowered.first ?? ch
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (isContentCharacter($1) ? 1 : 0) }
    }

    private static func isSentenceTerminator(_ ch: Character, in chars: [Character], at index: Int) -> Bool {
        guard terminators.contains(ch) else { return false }
        if ch == ".", index > 0, index + 1 < chars.count {
            let prev = chars[index - 1]
            let next = chars[index + 1]
            if prev.isASCII && prev.isNumber && next.isASCII && next.isNumber {
                return false
            }
        }
        return true
    }

    private static func isOpeningPunctuation(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains {
            $0.properties.generalCategory == .openPunctuation || $0.properties.generalCategory == .initialPunctuation
        }
    }

    private static func isTrailingClosingPunctuation(_ ch: Character) -> Bool {
        if ch == "\"" || ch == "'" { return true }
        return ch.unicodeScalars.contains {
            $0.properties.generalCategory == .closePunctuation || $0.properties.generalCategory == .finalPunctuation
        }
    }

    private static func isInsideASCIIWord(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let prev = chars[index - 1]
        let curr = chars[index]
        return prev.isASCII && (prev.isLetter || prev.isNumber)
            && curr.isASCII && (curr.isLetter || curr.isNumber)
    }

    // MARK: - Hirschberg 线性空间最优 LCS

    private static func hirschbergLCS(_ a: [Character], _ b: [Character]) -> [(online: Int, ref: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        return hirschberg(a, 0..<a.count, b, 0..<b.count)
    }

    private static func hirschberg(
        _ a: [Character], _ aRange: Range<Int>,
        _ b: [Character], _ bRange: Range<Int>
    ) -> [(online: Int, ref: Int)] {
        guard !aRange.isEmpty, !bRange.isEmpty else { return [] }
        if aRange.count == 1 {
            let target = a[aRange.lowerBound]
            for j in bRange where b[j] == target {
                return [(aRange.lowerBound, j)]
            }
            return []
        }
        if bRange.count == 1 {
            let target = b[bRange.lowerBound]
            for i in aRange where a[i] == target {
                return [(i, bRange.lowerBound)]
            }
            return []
        }

        let mid = aRange.lowerBound + aRange.count / 2
        let left = lcsLengthsForward(a, aRange.lowerBound..<mid, b, bRange)
        let right = lcsLengthsBackward(a, mid..<aRange.upperBound, b, bRange)

        let n = bRange.count
        var bestSplit = 0
        var bestScore: Int32 = -1
        for k in 0...n {
            let score = left[k] + right[n - k]
            if score > bestScore {
                bestScore = score
                bestSplit = k
            }
        }
        let bMid = bRange.lowerBound + bestSplit
        return hirschberg(a, aRange.lowerBound..<mid, b, bRange.lowerBound..<bMid)
            + hirschberg(a, mid..<aRange.upperBound, b, bMid..<bRange.upperBound)
    }

    private static func lcsLengthsForward(
        _ a: [Character], _ aRange: Range<Int>,
        _ b: [Character], _ bRange: Range<Int>
    ) -> [Int32] {
        let n = bRange.count
        var prev = [Int32](repeating: 0, count: n + 1)
        var curr = [Int32](repeating: 0, count: n + 1)
        for i in aRange {
            let ai = a[i]
            curr[0] = 0
            for k in 1...n {
                let bj = b[bRange.lowerBound + k - 1]
                curr[k] = ai == bj ? prev[k - 1] + 1 : max(curr[k - 1], prev[k])
            }
            swap(&prev, &curr)
        }
        return prev
    }

    private static func lcsLengthsBackward(
        _ a: [Character], _ aRange: Range<Int>,
        _ b: [Character], _ bRange: Range<Int>
    ) -> [Int32] {
        let n = bRange.count
        var prev = [Int32](repeating: 0, count: n + 1)
        var curr = [Int32](repeating: 0, count: n + 1)
        for i in aRange.reversed() {
            let ai = a[i]
            curr[0] = 0
            for k in 1...n {
                let bj = b[bRange.upperBound - k]
                curr[k] = ai == bj ? prev[k - 1] + 1 : max(curr[k - 1], prev[k])
            }
            swap(&prev, &curr)
        }
        return prev
    }
}
