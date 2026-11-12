import AVFAudio
import CoreAudio
import Foundation

/// A block of audio exactly as the source delivered it.
public struct SourceBuffer: @unchecked Sendable {
    /// PCM in the source's native format (for the process tap: mono Float32 at the output device rate).
    public let buffer: AVAudioPCMBuffer
    /// Host time (mach ticks) at which the first sample of `buffer` was captured.
    public let hostTime: UInt64
    /// Host time at which our code received the buffer.
    public let receivedHostTime: UInt64
}

/// Anything that can produce live PCM. Swappable so the pipeline doesn't care where audio comes from.
public protocol AudioSource: AnyObject, Sendable {
    /// Human-readable description of what is being captured.
    var label: String { get }
    /// Native format; valid after `start`.
    var format: AVAudioFormat? { get }
    func start(_ onBuffer: @escaping @Sendable (SourceBuffer) -> Void) throws
    func stop()
}

public enum HostClock {
    public static func now() -> UInt64 { mach_absolute_time() }
    public static func seconds(_ ticks: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(ticks)) / 1e9 }
    public static func ticks(seconds: Double) -> UInt64 { AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1e9)) }
    /// Milliseconds from `earlier` to `later` (negative if out of order).
    public static func ms(from earlier: UInt64, to later: UInt64) -> Double {
        later >= earlier ? seconds(later - earlier) * 1000 : -seconds(earlier - later) * 1000
    }
}
