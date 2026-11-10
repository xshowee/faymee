import Foundation
import Testing
@testable import FaymeeCore

@Suite struct HotwordsTests {
    @Test func 一行一个词去掉空行和首尾空白并去重() {
        let text = "飞书\n\n  王总 \r\n\u{3000}Kubernetes\u{3000}\n飞书\n   \nkubernetes\n"
        #expect(Hotwords.parse(text) == ["飞书", "王总", "Kubernetes", "kubernetes"])
    }

    @Test func 空文本没有热词() {
        #expect(Hotwords.parse("").isEmpty)
        #expect(Hotwords.parse("\n \n").isEmpty)
    }
}

@Suite struct HotwordStoreTests {
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true)

    @Test func 没有热词表文件时为空() throws {
        let store = HotwordStore(url: dir.appendingPathComponent("hotwords.txt"))
        #expect(try store.load() == "")
    }

    @Test func 保存的原文能原样读回() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hotwords.txt")
        // 保存用户输入的原文：编辑框里正在输入的空行、空格不能被吞掉
        let text = "飞书\n王总 \n\n"

        try HotwordStore(url: url).save(text, replacing: "")

        #expect(try HotwordStore(url: url).load() == text)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func 第一次保存时没有文件也能存() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HotwordStore(url: dir.appendingPathComponent("hotwords.txt"))

        try store.save("飞书", replacing: "")

        #expect(try store.load() == "飞书")
    }

    @Test func 接着上次读到或存下的内容保存() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HotwordStore(url: dir.appendingPathComponent("hotwords.txt"))
        try store.save("飞书", replacing: "")

        try store.save("飞书\n王总", replacing: "飞书")

        #expect(try store.load() == "飞书\n王总")
    }

    /// 文件被存成了别的编码，编辑框是空的：这时敲一个字不能把整个文件覆盖掉
    @Test func 读不出来的热词表不会被覆盖() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hotwords.txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gbk = Data([0xB7, 0xC9, 0xCA, 0xE9]) // “飞书”的 GBK 编码，不是合法的 UTF-8
        try gbk.write(to: url)
        let store = HotwordStore(url: url)
        #expect(throws: (any Error).self) { try store.load() }

        #expect(throws: (any Error).self) { try store.save("王", replacing: "") }

        #expect(try Data(contentsOf: url) == gbk)
    }

    /// App 开着的时候用户用文本编辑器改了热词表，编辑框里还是旧内容
    @Test func 文件在别处被改过时不覆盖() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hotwords.txt")
        let store = HotwordStore(url: url)
        try store.save("飞书", replacing: "")
        try Data("飞书\nKubernetes".utf8).write(to: url)

        #expect(throws: HotwordStoreError.changedOnDisk) { try store.save("飞书\n王", replacing: "飞书") }

        #expect(try store.load() == "飞书\nKubernetes")
    }
}
