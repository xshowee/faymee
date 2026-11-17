import Foundation
import Testing
@testable import FaymeeCore

/// 删除模型前的确认说明：按这个模型现在被哪些用途选着说后果（同一份文件可能同时是会后转写和实时字幕定稿的模型）
@MainActor @Suite struct ModelDeletionTests {
    private let suite = "FaymeeModelDeletionTests-\(UUID().uuidString)"

    private func selections() -> ModelSelections {
        ModelSelections(defaults: UserDefaults(suiteName: suite)!, isExistingInstall: { true })
    }

    private func cleanUp() { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }

    @Test func 只有实时字幕定稿选着时_只是不做定稿_不说会议等下载() {
        #expect(ModelDeletion.message(size: "1.0 GB", selectedFor: [.liveFinalize])
                == "释放约 1.0 GB 空间。删除后，重新下载前不做实时字幕定稿，字幕照常显示。")
    }

    @Test func 声纹_新的会议区分说话人等下载() {
        #expect(ModelDeletion.message(size: "40 MB", selectedFor: [.voiceprint])
                == "释放约 40 MB 空间。删除后，新的会议要等重新下载后才区分说话人。已有会议的说话人不受影响。")
    }

    @Test func 其他用途各说各的后果() {
        #expect(ModelDeletion.message(size: "2.1 GB", selectedFor: [.transcription])
                == "释放约 2.1 GB 空间。删除后，新的会议会等待重新下载再转写。")
        #expect(ModelDeletion.message(size: "2.5 GB", selectedFor: [.minutes])
                == "释放约 2.5 GB 空间。删除后，新的纪要会等待重新下载。已生成的纪要不受影响。")
        #expect(ModelDeletion.message(size: "180 MB", selectedFor: [.liveCaptions])
                == "释放约 180 MB 空间。删除后，实时字幕改用 SpeechAnalyzer（系统自带），直到重新下载。")
    }

    @Test func 几个用途都选着时都说_没有用途选着时只说释放空间() {
        #expect(ModelDeletion.message(size: "1.0 GB", selectedFor: [.transcription, .liveFinalize])
                == "释放约 1.0 GB 空间。删除后，新的会议会等待重新下载再转写；重新下载前不做实时字幕定稿，字幕照常显示。")
        #expect(ModelDeletion.message(size: "1.0 GB", selectedFor: []) == "释放约 1.0 GB 空间。现在没有用途选着它。")
    }

    @Test func 选着这个模型的用途() {
        defer { cleanUp() }
        let s = selections()
        let paraformer = ModelCatalog.builtIn.model(id: LocalModel.paraformer.id)!
        #expect(s.roles(selecting: paraformer) == [])
        s.select(paraformer.id, for: .liveFinalize)
        s.select(paraformer.id, for: .transcription)
        #expect(s.roles(selecting: paraformer) == [.transcription, .liveFinalize])
    }
}
