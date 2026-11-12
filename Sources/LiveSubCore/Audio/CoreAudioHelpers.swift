import CoreAudio
import Foundation

/// Error wrapper for Core Audio `OSStatus` failures, carrying the call that failed.
public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        "\(operation) failed: OSStatus \(status) (\(fourCC(status)))"
    }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(decoding: bytes, as: UTF8.self)
    }
    return String(status)
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Thin typed accessors over `AudioObjectGetPropertyData`.
enum AudioObject {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
                  "get \(fourCC(OSStatus(bitPattern: selector))) on \(object)")
        return value
    }

    static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            of: T.Type, zero: T) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size of \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: zero, count: count)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &values), "get array \(selector)")
        return values
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get string \(selector)")
        return value?.takeRetainedValue() as String?
    }

    /// Tell the HAL to deliver its notifications on its own thread instead of the main run loop.
    /// Without this, starting a device from a process whose main thread is not spinning a
    /// CFRunLoop (or is busy) can stall for seconds or fail with '!dev'.
    static let useHALNotificationThread: Void = {
        var addr = address(kAudioHardwarePropertyRunLoop)
        var runLoop: UnsafeRawPointer? = nil  // a NULL CFRunLoopRef
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<UnsafeRawPointer?>.size), &runLoop)
    }()

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
    }

    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidIn = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pidIn, &size, &out),
                  "translate pid \(pid)")
        return out
    }
}
