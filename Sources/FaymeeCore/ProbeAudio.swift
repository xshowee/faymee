import Foundation

/// 在线转写「测试连接」共用的合法短音频（约 1 秒 16 kHz 16-bit 单声道 PCM WAV）
public enum ProbeAudio {
    private static let sampleRate: Int = 16_000
    private static let channelCount: Int = 1
    private static let bitsPerSample: Int = 16
    private static let durationSeconds: Double = 1.0

    public static func wavData() -> Data {
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = sampleCount * channelCount * bytesPerSample

        var data = Data(capacity: 44 + dataByteCount)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data) // PCM fmt chunk size
        appendLittleEndian(UInt16(1), to: &data)  // audio format = 1 (PCM)
        appendLittleEndian(UInt16(channelCount), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * channelCount * bytesPerSample), to: &data)
        appendLittleEndian(UInt16(channelCount * bytesPerSample), to: &data)
        appendLittleEndian(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(dataByteCount), to: &data)

        let fadeDuration = 0.05
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let envelope = min(1.0, t / fadeDuration) * min(1.0, max(0.0, durationSeconds - t) / fadeDuration)
            let harmonic = 0.6 * sin(2.0 * .pi * 220.0 * t)
                + 0.3 * sin(2.0 * .pi * 440.0 * t)
                + 0.1 * sin(2.0 * .pi * 660.0 * t)
            let scaled = harmonic * envelope * 0.25 * Double(Int16.max)
            let sample = Int16(max(Double(Int16.min), min(Double(Int16.max), scaled)))
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    public static func withTemporaryWAV<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faymee-probe-\(UUID().uuidString).wav")
        try wavData().write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
