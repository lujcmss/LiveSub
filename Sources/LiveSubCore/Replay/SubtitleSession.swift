import Foundation

/// Subtitles saved from one viewing, with enough information to show them again in sync:
/// each sentence with its timing and translation, and a fingerprint of the audio (not the audio).
public struct SubtitleSession: Codable, Sendable, Identifiable {
    public struct Caption: Codable, Sendable, Equatable {
        /// Seconds from the start of the session's audio.
        public var start: Double
        public var end: Double
        public var source: String
        public var translation: String?

        public init(start: Double, end: Double, source: String, translation: String?) {
            self.start = start
            self.end = end
            self.source = source
            self.translation = translation
        }
    }

    public var id: String
    public var title: String
    public var createdAt: Date
    /// Speech locale of the audio ("ja-JP") and translation target ("en"), if any.
    public var sourceLanguage: String
    public var targetLanguage: String?
    /// Seconds of audio covered.
    public var duration: Double
    public var captions: [Caption]
    /// One sub-fingerprint per `AudioFingerprinter.hopSeconds` of audio.
    public var fingerprints: [UInt32]

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), sourceLanguage: String,
                targetLanguage: String?, duration: Double, captions: [Caption], fingerprints: [UInt32]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.duration = duration
        self.captions = captions
        self.fingerprints = fingerprints
    }

    // Fingerprints are stored as base64 of little-endian UInt32s to keep files small.
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, sourceLanguage, targetLanguage, duration, captions, fingerprints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sourceLanguage = try c.decode(String.self, forKey: .sourceLanguage)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage)
        duration = try c.decode(Double.self, forKey: .duration)
        captions = try c.decode([Caption].self, forKey: .captions)
        let data = try c.decode(Data.self, forKey: .fingerprints)
        fingerprints = data.withUnsafeBytes { raw in
            (0..<raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(sourceLanguage, forKey: .sourceLanguage)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        try c.encode(duration, forKey: .duration)
        try c.encode(captions, forKey: .captions)
        var data = Data(capacity: fingerprints.count * 4)
        for f in fingerprints { withUnsafeBytes(of: f.littleEndian) { data.append(contentsOf: $0) } }
        try c.encode(data, forKey: .fingerprints)
    }

    /// Captions to show at `time`, appearing `lead` seconds early. A caption stays until
    /// `linger` seconds after it ends; consecutive captions closer than `linger` stay together
    /// (the overlay then keeps as many of them as fit).
    public func captions(at time: Double, lead: Double = 0, linger: Double = 5) -> [Caption] {
        // Last caption that has started.
        var lo = 0, hi = captions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if captions[mid].start - lead <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return [] }
        let last = lo - 1
        guard time <= captions[last].end + linger else { return [] }
        var first = last
        while first > 0, captions[first].start - captions[first - 1].end < linger, last - first < 8 { first -= 1 }
        return Array(captions[first...last])
    }
}

/// Saved sessions on disk: one JSON file each.
public struct SessionStore: Sendable {
    public let directory: URL

    /// Default: ~/Library/Application Support/LiveSub/Sessions (override with LIVESUB_SESSIONS_DIR).
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment["LIVESUB_SESSIONS_DIR"] {
            self.directory = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("LiveSub/Sessions", isDirectory: true)
        }
    }

    public func url(for id: String) -> URL { directory.appendingPathComponent("\(id).livesub.json") }

    public func save(_ session: SubtitleSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func loadAll() -> [SubtitleSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasSuffix(".livesub.json") }
            .compactMap { try? decoder.decode(SubtitleSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}
