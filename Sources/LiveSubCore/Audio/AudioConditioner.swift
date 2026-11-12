import AVFAudio
import Foundation

/// A fixed-length block of recognizer-ready audio.
public struct AudioChunk: @unchecked Sendable {
    /// Mono PCM in `AudioConditioner.outputFormat`.
    public let buffer: AVAudioPCMBuffer
    /// Host time of the chunk's first and last samples (when they were captured from the app).
    public let startHostTime: UInt64
    public let endHostTime: UInt64
    /// Host time at which the chunk was handed downstream.
    public let emittedHostTime: UInt64
    /// RMS level in dBFS.
    public let levelDB: Float
    /// Whether the level cleared the voice-activity threshold.
    public let isLoud: Bool
}

/// Downmixes, resamples and slices source audio into fixed-size chunks, and measures level.
///
/// Not thread-safe; call from one serial queue.
public final class AudioConditioner {
    /// Format of emitted chunks (mono; Float32 or Int16).
    public let outputFormat: AVAudioFormat
    /// Internal working format: mono Float32 at the output rate.
    private let floatFormat: AVAudioFormat
    public let chunkFrames: AVAudioFrameCount
    public var gateThresholdDB: Float

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pending: [Float] = []
    /// Host time corresponding to the end of `pending`.
    private var pendingEndHostTime: UInt64 = 0

    /// - Parameters:
    ///   - sampleRate: rate the recognizer wants (16 kHz for most on-device ASR).
    ///   - chunkDuration: seconds per emitted chunk. Smaller = lower latency, more overhead.
    ///   - gateThresholdDB: chunks quieter than this are flagged `isLoud == false`.
    public convenience init(sampleRate: Double = 16_000, chunkDuration: Double = 0.1, gateThresholdDB: Float = -50) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        self.init(format: fmt, chunkDuration: chunkDuration, gateThresholdDB: gateThresholdDB)
    }

    /// - Parameter format: the exact format the recognizer asked for (e.g. 16 kHz mono Int16).
    public init(format: AVAudioFormat, chunkDuration: Double = 0.1, gateThresholdDB: Float = -50) {
        precondition(format.channelCount == 1, "recognizer formats are mono")
        precondition(format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16)
        let sampleRate = format.sampleRate
        outputFormat = format
        floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        chunkFrames = AVAudioFrameCount((sampleRate * chunkDuration).rounded())
        self.gateThresholdDB = gateThresholdDB
    }

    public func process(_ input: SourceBuffer) -> [AudioChunk] {
        let mono = resample(input.buffer)
        guard !mono.isEmpty else { return [] }
        pending.append(contentsOf: mono)
        let inputDuration = Double(input.buffer.frameLength) / input.buffer.format.sampleRate
        pendingEndHostTime = input.hostTime + HostClock.ticks(seconds: inputDuration)

        var chunks: [AudioChunk] = []
        let n = Int(chunkFrames)
        let now = HostClock.now()
        while pending.count >= n {
            // Samples remaining after this chunk tell us how far back in time it ended.
            let after = pending.count - n
            let end = pendingEndHostTime &- HostClock.ticks(seconds: Double(after) / outputFormat.sampleRate)
            let start = end &- HostClock.ticks(seconds: Double(n) / outputFormat.sampleRate)
            let buf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrames)!
            buf.frameLength = chunkFrames
            let level = pending.withUnsafeBufferPointer { src -> Float in
                if let dst = buf.floatChannelData {
                    dst[0].update(from: src.baseAddress!, count: n)
                } else if let dst = buf.int16ChannelData {
                    for i in 0..<n { dst[0][i] = Int16(max(-1, min(1, src[i])) * 32767) }
                }
                return Self.rmsDB(UnsafeBufferPointer(rebasing: src[0..<n]))
            }
            chunks.append(AudioChunk(buffer: buf, startHostTime: start, endHostTime: end, emittedHostTime: now,
                                     levelDB: level, isLoud: level >= gateThresholdDB))
            pending.removeFirst(n)
        }
        return chunks
    }

    /// Converts any PCM buffer to mono Float32 at `outputFormat.sampleRate`.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let inFormat = buffer.format
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: floatFormat)
            // Mixing all channels into one is what we want for speech.
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            converterInputFormat = inFormat
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    public static func rmsDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}
