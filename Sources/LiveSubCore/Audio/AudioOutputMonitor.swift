import CoreAudio
import Foundation

/// Calls back when the Mac's default output device changes (headphones plugged in, AirPods
/// connected, …). A process tap is bound to the device it was created on, so capture has to be
/// restarted when that happens.
public final class AudioOutputMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LiveSub.AudioOutputMonitor")
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)

    public init(onChange: @escaping @Sendable () -> Void) {
        AudioObject.useHALNotificationThread
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}
