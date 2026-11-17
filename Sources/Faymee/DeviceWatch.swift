import CoreAudio
import Foundation

/// 监听一次采集所用 Core Audio 对象（设备、tap）的属性变化，在主线程回调。停止后、或已经换了一次建立，
/// 迟到的通知一律丢掉（每次 start 换一代）。只在主线程用（SystemSoundCapture、Recorder）
final class DeviceWatch: @unchecked Sendable {
    private var registered: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var generation = 0

    func start(_ properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)],
               onChange: @escaping @MainActor () -> Void) {
        stop()
        let generation = generation
        for (object, selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    onChange()
                }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                registered.append((object, address, block))
            }
        }
    }

    func stop() {
        generation += 1
        for (object, address, block) in registered {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        registered = []
    }
}
