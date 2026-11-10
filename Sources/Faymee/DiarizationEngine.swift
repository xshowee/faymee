import FaymeeCore

/// App 用哪个区分说话人引擎。换引擎只改这里；引擎标识、声纹模型标识由引擎自己给出，写进每份转写稿。
/// 返回 nil 表示没有可用的引擎：完整转写跳过区分说话人（不算失败），也不能单独区分说话人
enum DiarizationEngine {
    static func make() -> (any SpeakerDiarizer)? {
        // 占位：真实引擎由 ticket 05 接入
        nil
    }
}
