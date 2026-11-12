import AVFAudio
import Foundation

/// Writes PCM buffers to a 16-bit WAV file. Not thread-safe; use from one queue.
public final class WAVRecorder {
    public let url: URL
    private let file: AVAudioFile
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    public var duration: Double { Double(framesWritten) / file.processingFormat.sampleRate }

    /// AVAudioFile finalizes the header when it is deallocated; this makes that explicit.
    public func close() { file.close() }
}
