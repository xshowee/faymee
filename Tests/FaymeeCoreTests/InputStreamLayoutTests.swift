import AVFoundation
@testable import FaymeeCore
import Testing

struct InputStreamLayoutTests {
    /// 按 IOProc 的样子造一个 AudioBufferList：每个流一个 buffer，流内交错 Float32
    private func withBufferList(_ streams: [[Float]], channels: [Int],
                                _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = streams
        storage.withUnsafeMutableBufferPointer { all in
            for i in all.indices {
                all[i].withUnsafeMutableBytes { bytes in
                    list[i] = AudioBuffer(mNumberChannels: UInt32(channels[i]), mDataByteSize: UInt32(bytes.count),
                                          mData: bytes.baseAddress)
                }
            }
            body(UnsafePointer(list.unsafeMutablePointer))
        }
    }

    private func samples(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    @Test func monoIsCopiedAsIs() throws {
        let layout = InputStreamLayout(sampleRate: 48000, channelsPerStream: [1])
        let format = try #require(layout.makeFormat())
        #expect(format.sampleRate == 48000 && format.channelCount == 1 && !format.isInterleaved)
        withBufferList([[0.1, 0.2, 0.3]], channels: [1]) { list in
            let buffer = layout.deinterleave(list, format: format)
            #expect(buffer?.frameLength == 3)
            #expect(buffer.map { samples($0, channel: 0) } == [0.1, 0.2, 0.3])
        }
    }

    @Test func interleavedStereoIsSplitIntoChannels() throws {
        let layout = InputStreamLayout(sampleRate: 44100, channelsPerStream: [2])
        let format = try #require(layout.makeFormat())
        withBufferList([[1, -1, 2, -2]], channels: [2]) { list in
            let buffer = layout.deinterleave(list, format: format)
            #expect(buffer?.frameLength == 2)
            #expect(buffer.map { samples($0, channel: 0) } == [1, 2])
            #expect(buffer.map { samples($0, channel: 1) } == [-1, -2])
        }
    }

    /// 多流设备（比如聚合设备）：各流的声道按顺序排在后面
    @Test func streamsAreConcatenatedInOrder() throws {
        let layout = InputStreamLayout(sampleRate: 48000, channelsPerStream: [1, 2])
        let format = try #require(layout.makeFormat())
        #expect(format.channelCount == 3)
        withBufferList([[0.5, 0.6], [1, -1, 2, -2]], channels: [1, 2]) { list in
            let buffer = layout.deinterleave(list, format: format)
            #expect(buffer.map { samples($0, channel: 0) } == [0.5, 0.6])
            #expect(buffer.map { samples($0, channel: 1) } == [1, 2])
            #expect(buffer.map { samples($0, channel: 2) } == [-1, -2])
        }
    }

    /// 设备的流配置变了、监听还没来得及重建时，数据和布局对不上：丢掉，不按错的布局写进分片
    @Test func mismatchedDataIsDropped() throws {
        let layout = InputStreamLayout(sampleRate: 48000, channelsPerStream: [1])
        let format = try #require(layout.makeFormat())
        withBufferList([[1, -1, 2, -2]], channels: [2]) { list in
            #expect(layout.deinterleave(list, format: format) == nil)
        }
        withBufferList([[1, 2], [3, 4]], channels: [1, 1]) { list in
            #expect(layout.deinterleave(list, format: format) == nil)
        }
        let stereo = InputStreamLayout(sampleRate: 48000, channelsPerStream: [1, 1])
        let stereoFormat = try #require(stereo.makeFormat())
        // 两个流的帧数不一样
        withBufferList([[1, 2], [3]], channels: [1, 1]) { list in
            #expect(stereo.deinterleave(list, format: stereoFormat) == nil)
        }
    }

    @Test func emptyCallbackGivesNoBuffer() throws {
        let layout = InputStreamLayout(sampleRate: 48000, channelsPerStream: [1])
        let format = try #require(layout.makeFormat())
        withBufferList([[]], channels: [1]) { list in
            #expect(layout.deinterleave(list, format: format) == nil)
        }
    }

    @Test func noChannelsOrRateMeansNoFormat() {
        #expect(InputStreamLayout(sampleRate: 0, channelsPerStream: [1]).makeFormat() == nil)
        #expect(InputStreamLayout(sampleRate: 48000, channelsPerStream: []).makeFormat() == nil)
        #expect(InputStreamLayout(sampleRate: 48000, channelsPerStream: [0]).makeFormat() == nil)
    }

    @Test func moreThanTwoChannelsStillGetsAFormat() throws {
        let layout = InputStreamLayout(sampleRate: 48000, channelsPerStream: [4])
        let format = try #require(layout.makeFormat())
        #expect(format.channelCount == 4 && !format.isInterleaved)
    }
}
