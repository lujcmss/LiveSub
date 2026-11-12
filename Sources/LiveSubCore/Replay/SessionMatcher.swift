import Foundation

/// Finds where live audio is inside previously saved fingerprints, and keeps following it.
///
/// Feed it the live sub-fingerprints as they are produced. Once a few seconds agree with a
/// stretch of a saved session it reports a lock: "live frame L corresponds to saved frame
/// L + delta". It keeps checking that the audio still agrees, notices pauses (live audio goes
/// quiet where the saved audio is not) and seeks (agreement is lost), and re-locks.
/// Pure logic on fingerprint arrays; no audio or clocks.
public struct SessionMatcher: Sendable {
    public struct Reference: Sendable {
        public let id: String
        public let fingerprints: [UInt32]
        public init(id: String, fingerprints: [UInt32]) {
            self.id = id
            self.fingerprints = fingerprints
        }
    }

    public enum State: Sendable, Equatable {
        /// Still looking for the live audio in the saved sessions.
        case searching
        /// Live frame `L` plays saved frame `L + delta` of session `id`.
        case locked(id: String, delta: Int)
        /// Locked, but playback is paused: the saved position is frozen at `frame`.
        case paused(id: String, frame: Int)
    }

    public struct Tuning: Sendable {
        /// Frames compared when locking (3 s) and when checking a lock (2 s).
        public var lockWindow = 188
        public var checkWindow = 125
        /// Fewest non-silent frame pairs for a comparison to count.
        public var minimumValid = 40
        /// Bit error rate below which two stretches are the same audio (random audio gives 0.5).
        public var lockThreshold = 0.30
        public var loseThreshold = 0.40
        /// Consecutive failed checks before giving up a lock (checks run every `stride` frames).
        public var failuresToUnlock = 4
        public var stride = 16
        /// Quiet live frames (while the saved audio is not quiet) that mean "paused": 0.4 s.
        public var pauseFrames = 25
        /// Live frames with sound where the saved audio has none that mean "past the end": 0.35 s.
        public var orphanFrames = 22
        public init() {}
    }

    public private(set) var state: State = .searching
    public var tuning = Tuning()

    private var references: [String: [UInt32]] = [:]
    /// sub-fingerprint value → places it occurs (session index, frame).
    private var index: [UInt32: [(Int32, Int32)]] = [:]
    private var referenceIDs: [String] = []
    /// Recent live frames; `live[i]` is live frame `liveBase + i`.
    private var live: [UInt32] = []
    private var liveBase = 0
    private var sinceCheck = 0
    private var failures = 0
    private var quietRun = 0

    public init(references: [Reference] = []) {
        for r in references { add(r) }
    }

    public var hasReferences: Bool { !references.isEmpty }
    /// Total live frames received so far.
    public var liveFrameCount: Int { liveBase + live.count }

    public mutating func add(_ reference: Reference) {
        guard references[reference.id] == nil, !reference.fingerprints.isEmpty else { return }
        let s = Int32(referenceIDs.count)
        referenceIDs.append(reference.id)
        references[reference.id] = reference.fingerprints
        for (frame, value) in reference.fingerprints.enumerated() where value != AudioFingerprinter.silent {
            index[value, default: []].append((s, Int32(frame)))
        }
    }

    /// Append frames to a reference (creating it if needed). Used for the session being
    /// recorded right now, so that skipping back finds the audio heard a moment ago.
    public mutating func extend(id: String, with frames: [UInt32]) {
        guard !frames.isEmpty else { return }
        let s: Int32
        if let existing = referenceIDs.firstIndex(of: id) {
            s = Int32(existing)
        } else {
            s = Int32(referenceIDs.count)
            referenceIDs.append(id)
            references[id] = []
        }
        var base = references[id]!.count
        references[id]!.append(contentsOf: frames)
        for value in frames {
            if value != AudioFingerprinter.silent { index[value, default: []].append((s, Int32(base))) }
            base += 1
        }
    }

    /// Saved frame currently playing, if locked or paused.
    public var position: (id: String, frame: Int)? {
        switch state {
        case .searching: return nil
        case let .locked(id, delta): return (id, liveFrameCount + delta)
        case let .paused(id, frame): return (id, frame)
        }
    }

    /// Add live sub-fingerprints. Returns true if `state` changed.
    @discardableResult
    public mutating func append(_ frames: [UInt32]) -> Bool {
        let before = state
        for f in frames {
            ingest(f)
        }
        return state != before
    }

    private mutating func ingest(_ frame: UInt32) {
        if case let .paused(id, savedFrame) = state {
            // Stay frozen until sound returns, then expect playback to resume where it stopped.
            if frame == AudioFingerprinter.silent { return }
            live.removeAll(keepingCapacity: true)
            liveBase = 0
            live.append(frame)
            // Live frame 0 of the fresh buffer plays `savedFrame`.
            state = .locked(id: id, delta: savedFrame)
            failures = 0
            sinceCheck = 0
            quietRun = 0
            resumed = true
            return
        }
        live.append(frame)
        if live.count > 1024 {
            live.removeFirst(512)
            liveBase += 512
        }
        sinceCheck += 1

        if case let .locked(id, delta) = state, let saved = references[id] {
            // Pause detection: we hear nothing where the saved audio has sound.
            let savedIndex = liveFrameCount - 1 + delta
            let savedIsQuiet = savedIndex < 0 || savedIndex >= saved.count || saved[savedIndex] == AudioFingerprinter.silent
            if frame == AudioFingerprinter.silent, !savedIsQuiet {
                quietRun += 1
                if quietRun >= tuning.pauseFrames {
                    // Freeze at the point where the quiet began.
                    state = .paused(id: id, frame: max(0, savedIndex - quietRun + 1))
                    return
                }
            } else {
                quietRun = 0
            }
            // The opposite of a pause: we hear sound where nothing was saved. Playback has run
            // past the end of the saved audio (or past the point the viewer skipped back from).
            if frame != AudioFingerprinter.silent, savedIsQuiet {
                orphanRun += 1
                if orphanRun >= tuning.orphanFrames {
                    unlockLagFrames = orphanRun
                    unlock()
                    return
                }
            } else if frame != AudioFingerprinter.silent {
                orphanRun = 0
            }
        }
        guard sinceCheck >= tuning.stride else { return }
        sinceCheck = 0
        switch state {
        case .searching: search()
        case let .locked(id, delta): verify(id: id, delta: delta)
        case .paused: break
        }
    }

    /// True right after resuming from a pause, until the first successful check.
    private var resumed = false

    private var orphanRun = 0
    /// How many of the most recent frames were already past the end of the match when the lock
    /// was dropped (they belong to new audio, not to the replay).
    public private(set) var unlockLagFrames = 0

    private mutating func unlock() {
        orphanRun = 0
        state = .searching
        failures = 0
        quietRun = 0
        resumed = false
    }

    /// Bit error rate between the last `window` live frames and the saved frames they would
    /// correspond to under `delta`. nil if too few frames have sound on both sides.
    private func errorRate(saved: [UInt32], delta: Int, window: Int) -> Double? {
        let count = min(window, live.count)
        var bits = 0, valid = 0, orphans = 0
        let firstLive = live.count - count
        for i in 0..<count {
            let s = liveBase + firstLive + i + delta
            guard s >= 0, s < saved.count else { continue }
            let a = live[firstLive + i], b = saved[s]
            if a != AudioFingerprinter.silent, b == AudioFingerprinter.silent { orphans += 1 }
            guard a != AudioFingerprinter.silent, b != AudioFingerprinter.silent else { continue }
            bits += (a ^ b).nonzeroBitCount
            valid += 1
        }
        let needed = resumed ? min(tuning.minimumValid, 20) : tuning.minimumValid
        guard valid >= needed else {
            // We hear sound where the saved session has none: that is a mismatch, not a lack
            // of evidence (e.g. playback ran past the end of what was saved).
            return orphans >= needed ? 0.5 : nil
        }
        return Double(bits) / Double(valid * 32)
    }

    private mutating func search() {
        guard live.count >= tuning.minimumValid else { return }
        // Vote: every exact sub-fingerprint hit suggests an alignment.
        var votes: [Int64: Int] = [:]
        let count = min(tuning.lockWindow, live.count)
        let firstLive = live.count - count
        for i in 0..<count {
            let value = live[firstLive + i]
            guard value != AudioFingerprinter.silent else { continue }
            // Look up the value itself and every one-bit variation of it: a stream replayed at
            // a different quality rarely reproduces all 32 bits of a frame exactly.
            for bit in -1..<32 {
                let probe = bit < 0 ? value : value ^ (1 << UInt32(bit))
                guard let hits = index[probe], hits.count < 2000 else { continue }
                for (s, frame) in hits {
                    let delta = Int(frame) - (liveBase + firstLive + i)
                    votes[Int64(s) << 40 | Int64(delta + (1 << 30)), default: 0] += bit < 0 ? 3 : 1
                }
            }
        }
        searches += 1
        // Every couple of seconds, also compare against everything directly: this finds audio
        // too degraded for the index. (Kept infrequent and bounded so a large library of saved
        // sessions costs about 1% of a core.)
        if searches % 8 == 0, let found = exhaustiveSearch() {
            votes[Int64(found.session) << 40 | Int64(found.delta + (1 << 30)), default: 0] += 1000
        }
        // Check the most-voted alignments properly.
        let candidates = votes.sorted { $0.value > $1.value }.prefix(8)
        var best: (id: String, delta: Int, rate: Double)?
        for (key, _) in candidates {
            let id = referenceIDs[Int(key >> 40)]
            let delta = Int(key & ((1 << 40) - 1)) - (1 << 30)
            guard let saved = references[id] else { continue }
            // Neighbouring alignments can score better than the voted one by a frame.
            for d in (delta - 1)...(delta + 1) {
                // An alignment whose newest audio falls where nothing was saved is one we have
                // already played past: older frames still agree, but it is over.
                guard !isPastEnd(saved: saved, delta: d) else { continue }
                if let rate = errorRate(saved: saved, delta: d, window: tuning.lockWindow), rate < (best?.rate ?? tuning.lockThreshold) {
                    best = (id, d, rate)
                }
            }
        }
        // For diagnostics: the closest alignment found, whether or not it was good enough.
        var closest = 1.0
        for (key, _) in candidates.prefix(3) {
            let id = referenceIDs[Int(key >> 40)]
            let delta = Int(key & ((1 << 40) - 1)) - (1 << 30)
            if let saved = references[id], let rate = errorRate(saved: saved, delta: delta, window: tuning.lockWindow) { closest = min(closest, rate) }
        }
        lastSearchBest = candidates.isEmpty ? nil : closest
        if let best {
            state = .locked(id: best.id, delta: best.delta)
            lastErrorRate = best.rate
            failures = 0
            quietRun = 0
            lockStartFrame = matchStart(id: best.id, delta: best.delta)
        }
    }

    private var searches = 0

    /// Whether, under `delta`, the most recent live frames with sound all fall where the saved
    /// session has none.
    private func isPastEnd(saved: [UInt32], delta: Int) -> Bool {
        var sounding = 0, orphans = 0
        for i in stride(from: live.count - 1, through: max(0, live.count - tuning.orphanFrames * 2), by: -1) {
            guard live[i] != AudioFingerprinter.silent else { continue }
            sounding += 1
            let s = liveBase + i + delta
            if s < 0 || s >= saved.count || saved[s] == AudioFingerprinter.silent { orphans += 1 }
            if sounding >= tuning.orphanFrames { break }
        }
        return sounding >= tuning.orphanFrames / 2 && orphans * 5 >= sounding * 4
    }

    /// Live frame at which the audio began to follow the current lock's alignment: where the
    /// viewer jumped (found by walking back from now until the audio stops agreeing).
    public private(set) var lockStartFrame = 0

    private func matchStart(id: String, delta: Int) -> Int {
        guard let saved = references[id] else { return liveFrameCount }
        var earliest = live.count
        var misses = 0
        for i in stride(from: live.count - 1, through: 0, by: -1) {
            let s = liveBase + i + delta
            guard s >= 0, s < saved.count else { break }
            let a = live[i], b = saved[s]
            if a == AudioFingerprinter.silent || b == AudioFingerprinter.silent {
                // Silence on both sides is consistent; sound on one side only is not.
                if a != b { misses += 1 } else { continue }
            } else if (a ^ b).nonzeroBitCount <= 11 {
                earliest = i
                misses = 0
                continue
            } else {
                misses += 1
            }
            if misses >= 6 { break }
        }
        return liveBase + earliest
    }

    /// Slide the recent live audio along every saved session, using a sample of its frames,
    /// and return the best alignment if it is clearly not chance.
    private func exhaustiveSearch() -> (session: Int, delta: Int)? {
        let count = min(tuning.lockWindow, live.count)
        let firstLive = live.count - count
        // Up to 40 evenly spread non-silent live frames.
        let candidates = (0..<count).filter { live[firstLive + $0] != AudioFingerprinter.silent }
        guard candidates.count >= tuning.minimumValid else { return nil }
        let step = max(1, candidates.count / 40)
        let sample = stride(from: 0, to: candidates.count, by: step).map { candidates[$0] }
        var best: (session: Int, delta: Int, rate: Double)?
        var budget = 600_000   // frames examined per pass: about 2.5 hours of saved audio
        // Newest sessions first (the one being recorded is last in the list).
        for (s, id) in referenceIDs.enumerated().reversed() {
            guard budget > 0, let saved = references[id], saved.count > count else { continue }
            budget -= saved.count
            saved.withUnsafeBufferPointer { savedPtr in
                for start in 0...(saved.count - count) {
                    var bits = 0, valid = 0
                    for offset in sample {
                        let b = savedPtr[start + offset]
                        guard b != AudioFingerprinter.silent else { continue }
                        bits += (live[firstLive + offset] ^ b).nonzeroBitCount
                        valid += 1
                    }
                    guard valid >= sample.count / 2, valid >= 16 else { continue }
                    let rate = Double(bits) / Double(valid * 32)
                    if rate < (best?.rate ?? tuning.lockThreshold) {
                        best = (s, start - (liveBase + firstLive), rate)
                    }
                }
            }
        }
        return best.map { ($0.session, $0.delta) }
    }

    /// Closest bit error rate found by the last search (nil: nothing even resembled the audio).
    public private(set) var lastSearchBest: Double?
    /// Bit error rate of the most recent successful comparison (diagnostics).
    public private(set) var lastErrorRate: Double = 1

    private mutating func verify(id: String, delta: Int) {
        guard let saved = references[id] else { unlock(); return }
        // Allow one frame of drift either way and follow it.
        var best: (delta: Int, rate: Double)?
        var comparable = false
        // Right after a pause the exact frame is uncertain (frames overlap the silence), so
        // look a little further around the expected position.
        let reach = resumed ? 24 : 1
        let offsets = [0] + (1...reach).flatMap { [-$0, $0] }
        for d in offsets.map({ delta + $0 }) {
            guard let rate = errorRate(saved: saved, delta: d, window: tuning.checkWindow) else { continue }
            comparable = true
            if rate < (best?.rate ?? tuning.loseThreshold) { best = (d, rate) }
        }
        if let best {
            failures = 0
            let wasResumed = resumed
            resumed = false
            _ = wasResumed
            lastErrorRate = best.rate
            // Only move on clear evidence, to avoid jitter.
            let current = errorRate(saved: saved, delta: delta, window: tuning.checkWindow) ?? 1
            if best.delta != delta, best.rate < current - 0.03 {
                state = .locked(id: id, delta: best.delta)
            }
        } else if comparable {
            failures += 1
            if failures >= tuning.failuresToUnlock {
                unlockLagFrames = failures * tuning.stride + tuning.checkWindow / 2
                unlock()
            }
        }
        // Not comparable (mostly silence): keep the lock and wait for sound.
    }
}
