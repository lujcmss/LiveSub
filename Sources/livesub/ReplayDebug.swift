import AVFAudio
import Foundation
import LiveSubCore

/// Read a whole audio file as mono 16 kHz samples.
func loadMono16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let conditioner = AudioConditioner(sampleRate: 16_000, chunkDuration: 0.1)
    var samples: [Float] = []
    let format = file.processingFormat
    while file.framePosition < file.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
        try file.read(into: buf, frameCount: 16_384)
        if buf.frameLength == 0 { break }
        for chunk in conditioner.process(SourceBuffer(buffer: buf, hostTime: 0, receivedHostTime: 0)) {
            samples.append(contentsOf: UnsafeBufferPointer(start: chunk.buffer.floatChannelData![0], count: Int(chunk.buffer.frameLength)))
        }
    }
    return samples
}

/// `livesub sync-test --file A [--against B] [--start-at S] [--gain G]`
/// Fingerprints file A as the saved session, then plays B (default A) from S seconds as if live
/// and reports how quickly and how accurately the matcher finds the position.
func runSyncTest(_ opts: Options) throws {
    guard let path = opts.file else { print("sync-test needs --file"); exit(2) }
    let reference = try loadMono16k(path)
    let saved = AudioFingerprinter().process(reference)
    let livePath = opts.against ?? path
    var liveSamples = try loadMono16k(livePath)
    let startSample = Int(opts.startAt * 16_000)
    liveSamples = Array(liveSamples.dropFirst(startSample))
    if opts.gain != 1 { liveSamples = liveSamples.map { $0 * Float(opts.gain) } }
    print(String(format: "saved: %.1f s, %d frames (%d silent); live starts at %.3f s", Double(reference.count) / 16_000, saved.count,
                 saved.filter { $0 == AudioFingerprinter.silent }.count, opts.startAt))

    var matcher = SessionMatcher(references: [.init(id: "saved", fingerprints: saved)])
    let fp = AudioFingerprinter()
    var fed = 0
    var lockedAt: Double?
    var worst = 0.0
    let t0 = HostClock.now()
    while fed < liveSamples.count {
        let n = min(1600, liveSamples.count - fed)
        let frames = fp.process(Array(liveSamples[fed..<fed + n]))
        fed += n
        let changed = matcher.append(frames)
        let liveTime = Double(fed) / 16_000
        if changed { print(String(format: "  %6.2f s live: %@", liveTime, "\(matcher.state)")) }
        if case let .locked(_, delta) = matcher.state {
            if lockedAt == nil { lockedAt = liveTime }
            // Truth: live frame L started at sample startSample + L*hop of the reference.
            let errorMS = (Double(delta) * AudioFingerprinter.hopSeconds - Double(startSample) / 16_000) * 1000
            worst = max(worst, abs(errorMS))
        }
    }
    let cpu = HostClock.ms(from: t0, to: HostClock.now())
    if let lockedAt {
        print(String(format: "locked after %.2f s of audio; worst position error %.1f ms; last bit error rate %.3f", lockedAt, worst, matcher.lastErrorRate))
    } else {
        print("never locked")
    }
    print(String(format: "processing: %.0f ms for %.1f s of audio", cpu, Double(liveSamples.count) / 16_000))
}

/// `livesub sessions [--delete ID|all]`: list or remove saved subtitle sessions.
func runSessions(_ opts: Options) {
    let store = SessionStore()
    if let target = opts.delete {
        for s in store.loadAll() where target == "all" || s.id.hasPrefix(target) {
            try? store.delete(id: s.id)
            print("Deleted \(s.title)")
        }
    }
    let sessions = store.loadAll()
    print("Saved subtitle sessions in \(store.directory.path):")
    if sessions.isEmpty { print("  (none yet: they are saved automatically while you watch)") }
    for s in sessions {
        let minutes = Int(s.duration) / 60, seconds = Int(s.duration) % 60
        print(String(format: "  %@  %@  %@%@  %d:%02d  %d subtitles", String(s.id.prefix(8)), s.title, s.sourceLanguage,
                     s.targetLanguage.map { "→\($0)" } ?? "", minutes, seconds, s.captions.count))
    }
}
