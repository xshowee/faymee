import Foundation

/// 会后在后台用 onnxruntime 的任务：会后转写（`SherpaOfflineTranscriber`）、区分说话人和重算声纹库（`SherpaOnnxDiarizer`）。
///
/// onnxruntime 还在建会话（加载模型）时进程退出，会崩在已析构的全局表上（ticket 07 在实时字幕里发现；
/// 会后转写在测试进程里复现过：开始转写后 0.3–0.6 秒退出，崩在 `OrtApis::CreateSession`）。
/// 所以 App 退出前先取消这些任务（取消在下一段、下一句之前生效，加载模型打断不了），再调用 `waitUntilReleased`
/// 等它们放掉模型。与实时字幕的 `SherpaStreamingTranscriber.waitUntilReleased` 分开计：
/// 测试里会后转写的契约测试与实时字幕的取消测试并行，算在一起会互相拖长等待
public enum SherpaBackgroundWork {
    /// 正在用 onnxruntime（或已排进后台队列、马上要用）的会后任务。交给后台队列前进入，放掉模型后离开
    static let inFlight = DispatchGroup()

    /// 等所有会后任务放掉模型。App 退出前、取消这些任务之后在主线程调用；任务不需要主线程。超时返回 false
    @discardableResult
    public static func waitUntilReleased(timeout: TimeInterval) -> Bool {
        inFlight.wait(timeout: .now() + timeout) == .success
    }
}
