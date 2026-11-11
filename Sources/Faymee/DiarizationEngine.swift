import Foundation
import FaymeeCore

/// App 用哪个区分说话人引擎。换引擎只改这里；引擎标识、声纹模型标识由引擎自己给出，写进每份转写稿。
/// diarizer 为 nil 表示没有可用的引擎：完整转写跳过区分说话人（不算失败），也不能单独区分说话人。
/// voiceprintThreshold 是这个引擎的声纹库匹配推荐阈值，传给转写管线
enum DiarizationEngine {
    static func make() -> (diarizer: (any SpeakerDiarizer)?, voiceprintThreshold: Float) {
        // 模型由 build.sh 拷进 Contents/Resources/Diarization；直接 swift run（没打包）时没有，不区分说话人
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Diarization", isDirectory: true),
              SherpaOnnxDiarizer.modelsPresent(in: directory)
        else { return (nil, VoiceprintLibrary.defaultMatchThreshold) }
        return (SherpaOnnxDiarizer(modelDirectory: directory), SherpaOnnxDiarizer.recommendedMatchThreshold)
    }
}
