import Accelerate
import AVFAudio
import Foundation

/// Turns audio into a compact stream of 32-bit "sub-fingerprints" (one every 16 ms), after
/// Haitsma & Kalker's robust audio hashing: each bit says whether the energy difference between
/// two neighbouring frequency bands went up or down since the previous frame.
///
/// The same audio played again produces (almost) the same bits regardless of volume or of where
/// the frame grid happens to fall, so a few seconds of live audio can be located inside a saved
/// session. No audio can be reconstructed from the fingerprint.
///
/// Not thread-safe; use from one queue.
public final class AudioFingerprinter {
    public static let sampleRate: Double = 16_000
    public static let frameLength = 2048          // 128 ms analysis window
    public static let hop = 256                   // one sub-fingerprint every 16 ms
    public static let hopSeconds = Double(hop) / sampleRate
    /// Value stored for frames too quiet to fingerprint.
    public static let silent: UInt32 = 0

    private static let bandCount = 33
    private let log2n = vDSP_Length(11)
    private let fft: FFTSetup
    private var window = [Float](repeating: 0, count: frameLength)
    private var bandEdges: [Int] = []
    private var pending: [Float] = []
    private var previousBands: [Float]?
    /// Mean-square level below which a frame counts as silence (about -66 dBFS).
    private let silenceThreshold: Float = 2.5e-7

    public init() {
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.frameLength), Int32(vDSP_HANN_NORM))
        // 33 logarithmically spaced bands over the range where speech and music carry most detail.
        let low = 300.0, high = 3400.0
        let binHz = Self.sampleRate / Double(Self.frameLength)
        bandEdges = (0...Self.bandCount).map { i in
            Int((low * pow(high / low, Double(i) / Double(Self.bandCount)) / binHz).rounded())
        }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Feed mono 16 kHz audio (Float32 or Int16); returns the sub-fingerprints completed by it.
    public func process(_ buffer: AVAudioPCMBuffer) -> [UInt32] {
        let n = Int(buffer.frameLength)
        if let f = buffer.floatChannelData {
            pending.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
        } else if let i = buffer.int16ChannelData {
            pending.reserveCapacity(pending.count + n)
            for k in 0..<n { pending.append(Float(i[0][k]) / 32768) }
        }
        return drain()
    }

    public func process(_ samples: [Float]) -> [UInt32] {
        pending.append(contentsOf: samples)
        return drain()
    }

    private func drain() -> [UInt32] {
        var out: [UInt32] = []
        var offset = 0
        while pending.count - offset >= Self.frameLength {
            out.append(fingerprint(frameAt: offset))
            offset += Self.hop
        }
        if offset > 0 { pending.removeFirst(offset) }
        return out
    }

    private func fingerprint(frameAt offset: Int) -> UInt32 {
        let n = Self.frameLength
        var frame = [Float](repeating: 0, count: n)
        var meanSquare: Float = 0
        pending.withUnsafeBufferPointer { p in
            vDSP_measqv(p.baseAddress! + offset, 1, &meanSquare, vDSP_Length(n))
            vDSP_vmul(p.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(n))
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = bandEdges[b], hi = max(bandEdges[b + 1], bandEdges[b] + 1)
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo)) }
            bands[b] = sum
        }
        defer { previousBands = bands }
        guard meanSquare >= silenceThreshold, let previous = previousBands else { return Self.silent }
        var bits: UInt32 = 0
        for m in 0..<32 where (bands[m] - bands[m + 1]) - (previous[m] - previous[m + 1]) > 0 {
            bits |= 1 << UInt32(m)
        }
        // 0 is reserved for silence.
        return bits == Self.silent ? 1 : bits
    }
}
