# 麦克风直接在设备上建 IOProc 采集，不用 AVAudioEngine

`Recorder` 用 `AudioDeviceCreateIOProcIDWithBlock` 直接在选中的麦克风上采集，回调里把各输入流交错的 Float32 转成非交错的 `AVAudioPCMBuffer`（`InputStreamLayout`），再写分片、算电平、分给实时字幕，下游的格式不变。不用 `AVAudioEngine`：它的 inputNode 和输出共用一个 IO unit，从系统默认输入起步，再用 `kAudioOutputUnitProperty_CurrentDevice` 换设备。系统默认输入是 AirPods、而麦克风选了别的设备（“自动”选中内置麦克风）时，实测（issue 16）会出现三种情况：

- AirPods 被打开、切到通话模式。引擎随即收到配置变化并停下，麦克风一直没有数据。
- 重建时 inputNode 报的还是 AirPods 的 24 kHz，硬件已经是 48 kHz，`installTap` 抛 Objective-C 异常。
- 引擎拆掉后，它的属性监听回调还在跑，访问野指针崩溃。

Swift 接不住 Objective-C 异常。异常被 `-[NSApplication run]` 吞掉后，主线程上 `MainActor.assumeIsolated` 的状态已经坏了，之后在不相干的地方以 EXC_BAD_ACCESS 崩溃。

## Consequences

- 只碰选中的输入设备：用内置麦克风录音时，戴着的 AirPods 不再被切成通话音质。
- 设备断开、采样率或输入流配置变了，按 `DeviceWatch` 的通知重建采集，从新分片接着录；数据和建立时的布局对不上的回调直接丢掉，不写进旧分片。
- IOProc 每次只给约 10 ms 的数据。电平攒够约 4096 帧再报一次，和原来 tap 的粒度相当，避免频繁切回主线程。
- 写盘仍在 IOProc 的队列上同步进行，和系统声音那一路相同。
