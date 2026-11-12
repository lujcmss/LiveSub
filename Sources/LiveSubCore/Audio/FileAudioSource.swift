import AVFAudio
import Foundation

/// Plays an audio file into the pipeline at real-time pace, without making any sound.
///
/// Used for repeatable tests: each buffer is stamped with the host time at which it "would
/// have been heard", so latency numbers are comparable with a live capture.
public final class FileAudioSource: AudioSource, @unchecked Sendable {
    public let url: URL
    public var label: String { url.lastPathComponent }
    public private(set) var format: AVAudioFormat?
    /// Called once the whole file has been delivered.
    public var onEnd: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "LiveSub.FileAudioSource", qos: .userInteractive)
    private var stopped = false
    private let bufferDuration: Double

    public init(url: URL, bufferDuration: Double = 0.01) {
        self.url = url
        self.bufferDuration = bufferDuration
    }

    public func start(_ onBuffer: @escaping @Sendable (SourceBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        format = fmt
        let frames = AVAudioFrameCount(fmt.sampleRate * bufferDuration)
        let startHost = HostClock.now() + HostClock.ticks(seconds: 0.05)
        let audioFile = file
        queue.async { [self] in
            var position: Double = 0
            while !stopped, audioFile.framePosition < audioFile.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
                      (try? audioFile.read(into: buf, frameCount: frames)) != nil, buf.frameLength > 0 else { break }
                let host = startHost + HostClock.ticks(seconds: position)
                position += Double(buf.frameLength) / fmt.sampleRate
                // A live tap hands over a buffer once its last sample has played; do the same.
                let due = startHost + HostClock.ticks(seconds: position)
                let now = HostClock.now()
                if due > now { Thread.sleep(forTimeInterval: HostClock.seconds(due - now)) }
                onBuffer(SourceBuffer(buffer: buf, hostTime: host, receivedHostTime: HostClock.now()))
            }
            if !stopped { onEnd?() }
        }
    }

    public func stop() { stopped = true }
}
