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

    /// Start playback this many seconds into the file (simulates seeking).
    public var startAt: Double = 0
    /// Simulate the viewer pausing: at `pauseAt` seconds of playback, wait `pauseFor` seconds.
    /// `pauseDeliversSilence` chooses between silent buffers and no buffers at all.
    public var pauseAt: Double?
    public var pauseFor: Double = 0
    public var pauseDeliversSilence = false
    /// Simulate the viewer skipping back: at `rewindAt` seconds of playback, jump back `rewindBy`.
    public var rewindAt: Double?
    public var rewindBy: Double = 0

    public init(url: URL, bufferDuration: Double = 0.01) {
        self.url = url
        self.bufferDuration = bufferDuration
    }

    public func start(_ onBuffer: @escaping @Sendable (SourceBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        format = fmt
        let frames = AVAudioFrameCount(fmt.sampleRate * bufferDuration)
        let audioFile = file
        audioFile.framePosition = min(audioFile.length, AVAudioFramePosition(startAt * fmt.sampleRate))
        let firstHost = HostClock.now() + HostClock.ticks(seconds: 0.05)
        let pauseAt = self.pauseAt
        queue.async { [self] in
            var startHost = firstHost
            var pause = pauseAt
            var rewind = rewindAt
            var position: Double = 0
            while !stopped, audioFile.framePosition < audioFile.length {
                if let at = rewind, position >= at {
                    rewind = nil
                    audioFile.framePosition = max(0, audioFile.framePosition - AVAudioFramePosition(rewindBy * fmt.sampleRate))
                }
                if let at = pause, position >= at {
                    pause = nil
                    if pauseDeliversSilence {
                        var waited = 0.0
                        while waited < pauseFor, !stopped, let quiet = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) {
                            quiet.frameLength = frames
                            Thread.sleep(forTimeInterval: bufferDuration)
                            waited += bufferDuration
                            let now = HostClock.now()
                            onBuffer(SourceBuffer(buffer: quiet, hostTime: now - HostClock.ticks(seconds: bufferDuration), receivedHostTime: now))
                        }
                    } else {
                        Thread.sleep(forTimeInterval: pauseFor)
                    }
                    // Resume: later audio is stamped later by the length of the pause.
                    startHost = HostClock.now() - HostClock.ticks(seconds: position)
                }
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
