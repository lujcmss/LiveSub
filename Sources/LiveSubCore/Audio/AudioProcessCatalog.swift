import AppKit
import CoreAudio
import Foundation

/// One process that Core Audio knows about (i.e. it has opened an audio client).
public struct AudioProcess: Sendable, Hashable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isPlayingAudio: Bool
}

/// A user-facing app and the audio processes that belong to it.
///
/// Browsers rarely play audio from their main process: Safari renders media in
/// `com.apple.WebKit.GPU`, Chrome in `com.google.Chrome.helper`, and so on. We group
/// those helper processes under the app the user actually recognizes.
public struct AudioApp: Sendable, Hashable {
    public let name: String
    public let bundleID: String
    public let processes: [AudioProcess]
    public var isPlayingAudio: Bool { processes.contains { $0.isPlayingAudio } }
}

public enum AudioProcessCatalog {
    /// Every process with a Core Audio process object.
    public static func allProcesses() throws -> [AudioProcess] {
        let ids = try AudioObject.getArray(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyProcessObjectList,
                                           of: AudioObjectID.self, zero: 0)
        return ids.compactMap { id in
            guard let pid = try? AudioObject.get(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let bundle = (try? AudioObject.getString(id, kAudioProcessPropertyBundleID)) ?? nil
            let running = (try? AudioObject.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isPlayingAudio: running != 0)
        }
    }

    /// Bundle-ID prefixes of helper processes that play audio on behalf of an app.
    static func helperPrefixes(for appBundleID: String) -> [String] {
        var prefixes = [appBundleID + "."]
        switch appBundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            prefixes.append("com.apple.WebKit.")
        default:
            break
        }
        return prefixes
    }

    /// Regular (Dock-visible) apps, each with the audio processes we attribute to it.
    @MainActor
    public static func apps() throws -> [AudioApp] {
        let processes = try allProcesses()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return running.compactMap { app -> AudioApp? in
            guard let bundle = app.bundleIdentifier else { return nil }
            let prefixes = helperPrefixes(for: bundle)
            let owned = processes.filter { p in
                if p.pid == app.processIdentifier { return true }
                guard let pb = p.bundleID else { return false }
                return pb == bundle || prefixes.contains { pb.hasPrefix($0) }
            }
            guard !owned.isEmpty else { return nil }
            return AudioApp(name: app.localizedName ?? bundle, bundleID: bundle, processes: owned)
        }
        .sorted { ($0.isPlayingAudio ? 0 : 1, $0.name) < ($1.isPlayingAudio ? 0 : 1, $1.name) }
    }

    /// Find an app by (case-insensitive) name, bundle ID, or PID.
    @MainActor
    public static func findApp(_ query: String) throws -> AudioApp? {
        let all = try apps()
        let q = query.lowercased()
        if let pid = pid_t(query) {
            return all.first { $0.processes.contains { $0.pid == pid } }
        }
        return all.first { $0.bundleID.lowercased() == q }
            ?? all.first { $0.name.lowercased() == q }
            ?? all.first { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }
}
