import Foundation
import Testing
@testable import FaymeeCore

@Suite struct VoiceprintStoreTests {
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true)
    private var url: URL { dir.appendingPathComponent("Faymee/voiceprints.json") }

    @Test func 没有声纹库文件时为空() throws {
        #expect(try VoiceprintStore(url: url).load() == VoiceprintLibrary())
    }

    @Test func 存下的声纹库能原样读回() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "3dspeaker", samples: [
                VoiceprintSample(voiceprint: Voiceprint([0.5, -1.25, 3]), meetingID: "m1", speechDuration: 12.5,
                                 addedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            ]),
        ])

        try VoiceprintStore(url: url).save(library)

        #expect(try VoiceprintStore(url: url).load() == library)
    }

    /// 声纹按转写稿同样的 float32 小端 base64 写盘（[1, -2] → 0000803F 000000C0）
    @Test func 写盘格式() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "3dspeaker", samples: [
                VoiceprintSample(voiceprint: Voiceprint([1, -2]), meetingID: "m1", speechDuration: 12,
                                 addedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            ]),
        ])

        try VoiceprintStore(url: url).save(library)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let person = (json["people"] as! [[String: Any]])[0]
        #expect(person["id"] as? String == "p1")
        #expect(person["name"] as? String == "张三")
        #expect(person["voiceprintModel"] as? String == "3dspeaker")
        let sample = (person["samples"] as! [[String: Any]])[0]
        #expect(sample["voiceprint"] as? String == "AACAPwAAAMA=")
        #expect(sample["meetingId"] as? String == "m1")
        #expect(sample["speechDuration"] as? Double == 12)
        #expect(sample["addedAt"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test func 读不出来的声纹库抛错且修改不会覆盖它() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("{ not json".utf8)
        try bad.write(to: url)
        let store = VoiceprintStore(url: url)

        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.update { $0.people = [] } }

        #expect(try Data(contentsOf: url) == bad)
    }

    /// 声纹是生物特征：文件坏了也必须能一键清除
    @Test func 全部删除在文件坏了时也能删掉() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = VoiceprintStore(url: url)

        try store.removeAll()

        #expect(try store.load() == VoiceprintLibrary())
    }

    @Test func 修改在读到的声纹库上进行并写回() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = VoiceprintStore(url: url)
        let p1 = VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "m", samples: [])
        let p2 = VoiceprintPerson(id: "p2", name: "李四", voiceprintModel: "m", samples: [])
        try store.save(VoiceprintLibrary(people: [p1]))

        let count = try store.update { library in
            library.people.append(p2)
            return library.people.count
        }

        #expect(count == 2)
        #expect(try store.load().people == [p1, p2])
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// 一场会议的转写稿，只关心说话人列表
private func meeting(model: String = "vp-a", _ speakers: [Speaker]) -> Transcript {
    Transcript(engine: "test", createdAt: t0, hotwords: [], items: [],
               diarization: Diarization(engine: "fake", voiceprintModel: model, speakersCreatedAt: t0,
                                        speakers: speakers))
}

private func ids(_ prefix: String = "p") -> () -> String {
    var n = 0
    return { n += 1; return "\(prefix)\(n)" }
}

/// 记住这个声音：从某场会议的已命名说话人登记声纹
@Suite struct 登记声纹 {
    @Test func 第一次登记时新建人员() throws {
        var library = VoiceprintLibrary()
        let t = meeting([
            Speaker(id: "spk1", voiceprint: Voiceprint([1, 0]), speechDuration: 30),
            Speaker(id: "spk2", name: " 张三 ", nameSource: .user, voiceprint: Voiceprint([0, 1]), speechDuration: 12),
        ])

        let id = try library.enroll(speaker: "spk2", from: t, meetingID: "m1", now: t0, newID: ids())

        #expect(id == "p1")
        #expect(library.people == [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [
                VoiceprintSample(voiceprint: Voiceprint([0, 1]), meetingID: "m1", speechDuration: 12, addedAt: t0),
            ]),
        ])
    }

    @Test func 同名已有人员时加样本而不是新建() throws {
        var library = VoiceprintLibrary()
        let first = meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 0]), speechDuration: 20)])
        let second = meeting([Speaker(id: "spk3", name: "张三", voiceprint: Voiceprint([0, 1]), speechDuration: 15)])
        try library.enroll(speaker: "spk1", from: first, meetingID: "m1", now: t0, newID: ids())

        let id = try library.enroll(speaker: "spk3", from: second, meetingID: "m2", now: t0 + 60, newID: ids("q"))

        #expect(id == "p1")
        #expect(library.people.count == 1)
        #expect(library.people[0].samples == [
            VoiceprintSample(voiceprint: Voiceprint([1, 0]), meetingID: "m1", speechDuration: 20, addedAt: t0),
            VoiceprintSample(voiceprint: Voiceprint([0, 1]), meetingID: "m2", speechDuration: 15, addedAt: t0 + 60),
        ])
    }

    /// 合并说话人后声纹变了，再登记一次：同一场会议只留一份样本
    @Test func 同一场会议再登记时替换这场的样本() throws {
        var library = VoiceprintLibrary()
        try library.enroll(speaker: "spk1",
                           from: meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 0]), speechDuration: 20)]),
                           meetingID: "m1", now: t0, newID: ids())
        try library.enroll(speaker: "spk1",
                           from: meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 0]), speechDuration: 20)]),
                           meetingID: "m2", now: t0 + 1, newID: ids())

        try library.enroll(speaker: "spk1",
                           from: meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 1]), speechDuration: 40)]),
                           meetingID: "m1", now: t0 + 2, newID: ids())

        #expect(library.people[0].samples.map(\.meetingID) == ["m2", "m1"])
        #expect(library.people[0].samples[1] ==
            VoiceprintSample(voiceprint: Voiceprint([1, 1]), meetingID: "m1", speechDuration: 40, addedAt: t0 + 2))
    }

    @Test func 每人最多十个样本超出时丢最早的() throws {
        var library = VoiceprintLibrary()
        for i in 1...11 {
            let t = meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([Float(i), 1]), speechDuration: 10)])
            try library.enroll(speaker: "spk1", from: t, meetingID: "m\(i)", now: t0 + Double(i), newID: ids())
        }

        #expect(library.people[0].samples.map(\.meetingID) == (2...11).map { "m\($0)" })
    }

    /// 换了声纹模型的旧人员：新旧声纹不可比，重新登记时丢掉旧样本、换成新模型
    @Test func 同名但声纹模型不同时重新登记() throws {
        var library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-old", samples: [
                VoiceprintSample(voiceprint: Voiceprint([1, 2, 3]), meetingID: "m0", speechDuration: 30, addedAt: t0),
            ]),
        ])
        let t = meeting(model: "vp-a", [Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([0, 1]), speechDuration: 12)])

        let id = try library.enroll(speaker: "spk1", from: t, meetingID: "m1", now: t0 + 5, newID: ids("q"))

        #expect(id == "p1")
        #expect(library.people == [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [
                VoiceprintSample(voiceprint: Voiceprint([0, 1]), meetingID: "m1", speechDuration: 12, addedAt: t0 + 5),
            ]),
        ])
    }

    @Test func 有效发言不足十秒时拒绝并说明原因() {
        var library = VoiceprintLibrary()
        let t = meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 0]), speechDuration: 9.6)])

        #expect(throws: VoiceprintEnrollmentError.tooShort(name: "张三", speechDuration: 9.6)) {
            try library.enroll(speaker: "spk1", from: t, meetingID: "m1", now: t0, newID: ids())
        }
        #expect(library.people.isEmpty)
        #expect(VoiceprintEnrollmentError.tooShort(name: "张三", speechDuration: 9.6).localizedDescription
            == "张三在这场会议里的有效发言只有 9 秒，至少需要 10 秒才能记住声音")
    }

    @Test func 正好十秒可以登记() throws {
        var library = VoiceprintLibrary()
        let t = meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([1, 0]), speechDuration: 10)])

        try library.enroll(speaker: "spk1", from: t, meetingID: "m1", now: t0, newID: ids())

        #expect(library.people.count == 1)
    }

    /// 登记按名字找人，不能把“说话人 2”登记进去
    @Test func 没命名的说话人不能登记() {
        var library = VoiceprintLibrary()
        let t = meeting([
            Speaker(id: "spk1", voiceprint: Voiceprint([1, 0]), speechDuration: 30),
            Speaker(id: "spk2", name: "  ", voiceprint: Voiceprint([1, 0]), speechDuration: 30),
        ])

        #expect(throws: VoiceprintEnrollmentError.unnamed) {
            try library.enroll(speaker: "spk1", from: t, meetingID: "m1", now: t0, newID: ids())
        }
        #expect(throws: VoiceprintEnrollmentError.unnamed) {
            try library.enroll(speaker: "spk2", from: t, meetingID: "m1", now: t0, newID: ids())
        }
        #expect(library.people.isEmpty)
    }

    /// 单句改给“新说话人”建出来的人、引擎没给声纹的人，声纹是空向量
    @Test func 没有声纹的说话人不能登记() {
        var library = VoiceprintLibrary()
        let t = meeting([Speaker(id: "spk1", name: "张三", voiceprint: Voiceprint([]), speechDuration: 30)])

        #expect(throws: VoiceprintEnrollmentError.noVoiceprint(name: "张三")) {
            try library.enroll(speaker: "spk1", from: t, meetingID: "m1", now: t0, newID: ids())
        }
        #expect(library.people.isEmpty)
    }

    @Test func 说话人不存在或没区分过时不能登记() {
        var library = VoiceprintLibrary()
        let plain = Transcript(engine: "test", createdAt: t0, hotwords: [], items: [])

        #expect(throws: VoiceprintEnrollmentError.speakerNotFound) {
            try library.enroll(speaker: "spk1", from: plain, meetingID: "m1", now: t0, newID: ids())
        }
        #expect(throws: VoiceprintEnrollmentError.speakerNotFound) {
            try library.enroll(speaker: "spk9", from: meeting([]), meetingID: "m1", now: t0, newID: ids())
        }
    }
}

private func person(_ id: String, _ name: String, model: String = "vp-a", _ vectors: [[Float]] = [[1, 0]]) -> VoiceprintPerson {
    VoiceprintPerson(id: id, name: name, voiceprintModel: model, samples: vectors.enumerated().map { i, v in
        VoiceprintSample(voiceprint: Voiceprint(v), meetingID: "m\(i)", speechDuration: 20, addedAt: t0)
    })
}

/// 声纹管理窗口的操作
@Suite struct 管理声纹库 {
    @Test func 改名() throws {
        var library = VoiceprintLibrary(people: [person("p1", "张三"), person("p2", "李四")])

        try library.rename("p1", to: "  张三丰 ")

        #expect(library.people.map(\.name) == ["张三丰", "李四"])
        #expect(library.people[0].samples == person("p1", "张三").samples)
    }

    /// 登记按名字找人：两个人同名会让以后的登记不知道加给谁
    @Test func 不能改成另一个人的名字或空名字() {
        var library = VoiceprintLibrary(people: [person("p1", "张三"), person("p2", "李四")])

        #expect(throws: VoiceprintLibraryError.duplicateName("李四")) { try library.rename("p1", to: " 李四") }
        #expect(throws: VoiceprintLibraryError.emptyName) { try library.rename("p1", to: "  ") }
        #expect(throws: VoiceprintLibraryError.personNotFound) { try library.rename("p9", to: "王五") }
        #expect(library.people.map(\.name) == ["张三", "李四"])
        #expect(VoiceprintLibraryError.duplicateName("李四").localizedDescription == "声纹库里已经有“李四”了")
    }

    @Test func 改成自己原来的名字不算重名() throws {
        var library = VoiceprintLibrary(people: [person("p1", "张三")])

        try library.rename("p1", to: "张三")

        #expect(library.people.map(\.name) == ["张三"])
    }

    @Test func 删除某人() {
        var library = VoiceprintLibrary(people: [person("p1", "张三"), person("p2", "李四")])

        library.remove("p1")

        #expect(library.people == [person("p2", "李四")])
    }

    @Test func 声纹模型与当前不同的人需要重新登记() {
        let library = VoiceprintLibrary(people: [
            person("p1", "张三", model: "vp-old"), person("p2", "李四", model: "vp-a"), person("p3", "王五", model: "vp-x"),
        ])

        #expect(library.peopleNeedingReenrollment(voiceprintModel: "vp-a").map(\.id) == ["p1", "p3"])
        #expect(library.people[0].needsReenrollment(voiceprintModel: "vp-a"))
        #expect(!library.people[1].needsReenrollment(voiceprintModel: "vp-a"))
    }
}

private func spk(_ n: Int, _ v: [Float], name: String? = nil, source: SpeakerNameSource? = nil,
                 personID: String? = nil) -> Speaker {
    Speaker(id: "spk\(n)", name: name, nameSource: source, personID: personID, voiceprint: Voiceprint(v),
            speechDuration: 30)
}

/// 相似度用手算得出的向量：相同为 1；(1,1) 与 (1,0) 为 √2/2 ≈ 0.707；(2,1) 与 (1,0) 为 2/√5 ≈ 0.894、
/// 与 (0,1) 为 1/√5 ≈ 0.447；正交为 0
@Suite struct 声纹匹配 {
    private func pairs(_ matches: [VoiceprintMatch]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: matches.map { ($0.speakerID, $0.personID) })
    }

    @Test func 超过阈值的认作此人() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]])])
        let speakers = [spk(1, [1, 1]), spk(2, [0, 1])]

        #expect(library.match(speakers, voiceprintModel: "vp-a", threshold: 0.8).isEmpty)

        let matches = library.match(speakers, voiceprintModel: "vp-a", threshold: 0.6)
        #expect(matches.map(\.speakerID) == ["spk1"])
        #expect(matches[0].personID == "p1")
        #expect(matches[0].name == "张三")
        #expect(abs(matches[0].similarity - 0.70710678) < 1e-5)
    }

    @Test func 每人取与各样本相似度的最大值() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[0, 1], [1, 0]])])

        let matches = library.match([spk(1, [1, 0])], voiceprintModel: "vp-a", threshold: 0.9)

        #expect(pairs(matches) == ["spk1": "p1"])
        #expect(abs(matches[0].similarity - 1) < 1e-6)
    }

    /// spk2 与张三最像（1），先分给 spk2；spk1 与张三也像（0.894），但张三已被占，退而认作第二像的李四（0.447）
    @Test func 一个人只认给一个说话人按相似度从高到低分配() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]]), person("p2", "李四", [[0, 1]])])
        let speakers = [spk(1, [2, 1]), spk(2, [1, 0])]

        #expect(pairs(library.match(speakers, voiceprintModel: "vp-a", threshold: 0.4)) == ["spk1": "p2", "spk2": "p1"])
        #expect(pairs(library.match(speakers, voiceprintModel: "vp-a", threshold: 0.5)) == ["spk2": "p1"])
    }

    /// 两个说话人和同一个人一样像：认给列表里靠前的（先开口的）
    @Test func 相似度相同时认给先开口的说话人() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]])])

        let matches = library.match([spk(1, [1, 0]), spk(2, [1, 0])], voiceprintModel: "vp-a", threshold: 0.5)

        #expect(pairs(matches) == ["spk1": "p1"])
    }

    @Test func 声纹模型不同的人不参与识别() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", model: "vp-old", [[1, 0]])])

        #expect(library.match([spk(1, [1, 0])], voiceprintModel: "vp-a", threshold: 0.5).isEmpty)
    }

    @Test func 手动命名的说话人不被覆盖() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]]), person("p2", "李四", [[0, 1]])])
        let speakers = [spk(1, [1, 0], name: "老板", source: .user), spk(2, [0, 1])]

        #expect(pairs(library.match(speakers, voiceprintModel: "vp-a", threshold: 0.5)) == ["spk2": "p2"])
    }

    /// 手动命名的说话人已经是张三（同名，或沿用来的声纹库关联）：不再把张三认给别的说话人，免得出现两个张三
    @Test func 手动命名已占用的人不再认给别的说话人() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]]), person("p2", "李四", [[0, 1]])])

        let byName = [spk(1, [0, 1], name: " 张三", source: .user), spk(2, [1, 0])]
        #expect(library.match(byName, voiceprintModel: "vp-a", threshold: 0.5).isEmpty)

        let byLink = [spk(1, [0, 1], name: "老张", source: .user, personID: "p1"), spk(2, [1, 0])]
        #expect(library.match(byLink, voiceprintModel: "vp-a", threshold: 0.5).isEmpty)
    }

    /// 声纹认出的名字每次识别都重算，可以换人
    @Test func 声纹认出的说话人重新参与识别() {
        let library = VoiceprintLibrary(people: [person("p2", "李四", [[0, 1]])])
        let speakers = [spk(1, [0, 1], name: "张三", source: .voiceprint, personID: "p1")]

        #expect(pairs(library.match(speakers, voiceprintModel: "vp-a", threshold: 0.5)) == ["spk1": "p2"])
    }

    @Test func 没有声纹的说话人不会被认出() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]])])

        #expect(library.match([spk(1, [])], voiceprintModel: "vp-a").isEmpty)
    }

    @Test func 默认阈值是保守的() {
        let library = VoiceprintLibrary(people: [person("p1", "张三", [[1, 0]])])

        #expect(library.match([spk(1, [1, 1])], voiceprintModel: "vp-a").isEmpty)
        #expect(pairs(library.match([spk(1, [1, 0])], voiceprintModel: "vp-a")) == ["spk1": "p1"])
    }
}
