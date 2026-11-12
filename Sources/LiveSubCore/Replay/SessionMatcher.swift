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
            if savedIndex >= saved.count + tuning.lockWindow {
                // Ran past the end of the saved session.
                unlock()
                return
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

    private mutating func unlock() {
        state = .searching
        failures = 0
        quietRun = 0
        resumed = false
    }

    /// Bit error rate between the last `window` live frames and the saved frames they would
    /// correspond to under `delta`. nil if too few frames have sound on both sides.
    private func errorRate(saved: [UInt32], delta: Int, window: Int) -> Double? {
        let count = min(window, live.count)
        var bits = 0, valid = 0
        let firstLive = live.count - count
        for i in 0..<count {
            let s = liveBase + firstLive + i + delta
            guard s >= 0, s < saved.count else { continue }
            let a = live[firstLive + i], b = saved[s]
            guard a != AudioFingerprinter.silent, b != AudioFingerprinter.silent else { continue }
            bits += (a ^ b).nonzeroBitCount
            valid += 1
        }
        let needed = resumed ? min(tuning.minimumValid, 20) : tuning.minimumValid
        guard valid >= needed else { return nil }
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
            guard value != AudioFingerprinter.silent, let hits = index[value], hits.count < 2000 else { continue }
            for (s, frame) in hits {
                let delta = Int(frame) - (liveBase + firstLive + i)
                votes[Int64(s) << 40 | Int64(delta + (1 << 30)), default: 0] += 1
            }
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
        }
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
            if failures >= tuning.failuresToUnlock { unlock() }
        }
        // Not comparable (mostly silence): keep the lock and wait for sound.
    }
}
