import FaymeeCore

/// 程序入口。带着查授权的参数启动时是 Faymee 自己起的子进程（见 `SystemSoundAuthorizationQuery`）：
/// 只查“系统录音”授权、打印结果就退出，不启动界面、不建 AppModel、不碰会议数据。
/// 这个判断必须在 `FaymeeApp.main()` 之前，否则每次查授权都会多起一个完整的 Faymee
@main
enum FaymeeMain {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == SystemSoundAuthorization.queryArgument {
            SystemSoundAuthorizationQuery.runChildQuery()
        }
        FaymeeApp.main()
    }
}
