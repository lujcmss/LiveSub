import AppKit
import AVFAudio
import CoreAudio
import Foundation

/// Captures app or system audio with a Core Audio process tap (macOS 14.2+).
///
/// Why a process tap rather than ScreenCaptureKit: it needs only the "System Audio Recording"
/// permission (not Screen Recording), delivers ~10 ms buffers straight from the HAL, can target
/// specific processes, and never touches video (so DRM-protected playback is irrelevant).
///
/// The tap is mixed down to mono by Core Audio itself, wrapped in a private aggregate device,
/// and read with an IO proc.
public final class ProcessTapSource: AudioSource, @unchecked Sendable {
    public enum Target: Sendable, CustomStringConvertible {
        /// Everything the Mac plays, except LiveSub itself.
        case systemWide
        /// One app, including helper processes (e.g. Safari's WebKit GPU process).
        case app(bundleID: String, name: String)
        /// Specific processes by PID (for command-line players and testing).
        case pids([pid_t])

        public var description: String {
            switch self {
            case .systemWide: "all system audio"
            case let .app(_, name): name
            case let .pids(pids): "pid " + pids.map(String.init).joined(separator: ", ")
            }
        }
    }

    public let target: Target
    public var label: String { target.description }
    public private(set) var format: AVAudioFormat?

    private let queue = DispatchQueue(label: "LiveSub.ProcessTap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var tappedObjects: [AudioObjectID] = []

    public init(target: Target) {
        self.target = target
        AudioObject.useHALNotificationThread
    }

    deinit { stop() }

    // MARK: Start / stop

    public func start(_ onBuffer: @escaping @Sendable (SourceBuffer) -> Void) throws {
        precondition(tapID == kAudioObjectUnknown, "already started")
        do {
            let t0 = HostClock.now()
            func ms() -> String { String(format: "%.0f ms", HostClock.ms(from: t0, to: HostClock.now())) }
            try createTap()
            Log.debug("tap \(tapID) created at \(ms()), format \(format.map { "\($0)" } ?? "?")")
            try createAggregateDevice()
            Log.debug("aggregate device \(aggregateID) created at \(ms())")
            try startIO(onBuffer)
            Log.debug("IO started at \(ms())")
            if case .app = target { installProcessListener() }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        removeProcessListener()
        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Tap

    private func currentTargetObjects() -> [AudioObjectID] {
        switch target {
        case .systemWide:
            // Exclude ourselves so we never subtitle our own sounds.
            if let me = try? AudioObject.processObject(forPID: getpid()), me != kAudioObjectUnknown { return [me] }
            return []
        case let .app(bundleID, _):
            let prefixes = AudioProcessCatalog.helperPrefixes(for: bundleID)
            let appPIDs = Set(NSRunningApplicationPIDs(bundleID: bundleID))
            return ((try? AudioProcessCatalog.allProcesses()) ?? []).filter { p in
                if appPIDs.contains(p.pid) { return true }
                guard let b = p.bundleID else { return false }
                return b == bundleID || prefixes.contains { b.hasPrefix($0) }
            }.map(\.objectID)
        case let .pids(pids):
            return pids.compactMap { try? AudioObject.processObject(forPID: $0) }.filter { $0 != kAudioObjectUnknown }
        }
    }

    private func createTap() throws {
        let objects = currentTargetObjects()
        let desc: CATapDescription
        switch target {
        case .systemWide:
            desc = CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        case .app, .pids:
            desc = CATapDescription(monoMixdownOfProcesses: objects)
        }
        desc.name = "LiveSub tap (\(target))"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        tappedObjects = objects
        tapDescription = desc

        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &id), "AudioHardwareCreateProcessTap")
        tapID = id

        var asbd = try AudioObject.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(status: -1, operation: "AVAudioFormat from tap ASBD")
        }
        format = fmt
    }

    private func createAggregateDevice() throws {
        let outputID = try AudioObject.defaultOutputDevice()
        guard let outputUID = try AudioObject.getString(outputID, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, operation: "default output device UID")
        }
        let tapUID = tapDescription!.uuid.uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveSub Capture",
            kAudioAggregateDeviceUIDKey: "LiveSub-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "AudioHardwareCreateAggregateDevice")
        aggregateID = id
    }

    private func startIO(_ onBuffer: @escaping @Sendable (SourceBuffer) -> Void) throws {
        guard let format else { return }
        let block: AudioDeviceIOBlock = { _, inInputData, inInputTime, _, _ in
            let received = mach_absolute_time()
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, first.mDataByteSize > 0 else { return }
            let frames = AVAudioFrameCount(first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for (i, src) in abl.enumerated() where i < dst.count {
                let n = min(src.mDataByteSize, dst[i].mDataByteSize)
                if let s = src.mData, let d = dst[i].mData { memcpy(d, s, Int(n)) }
            }
            let ts = inInputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : received
            onBuffer(SourceBuffer(buffer: pcm, hostTime: host, receivedHostTime: received))
        }
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue, block), "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = proc
        // A freshly created aggregate device can take a moment to become startable.
        var status = AudioDeviceStart(aggregateID, proc)
        var attempts = 0
        while status != noErr, attempts < 100 {
            usleep(100_000)
            attempts += 1
            status = AudioDeviceStart(aggregateID, proc)
        }
        if attempts > 0 { Log.debug("AudioDeviceStart needed \(attempts) retries") }
        try check(status, "AudioDeviceStart")
    }

    // MARK: Following an app's helper processes

    /// Browsers spin up / replace their audio helper process when playback starts or a tab
    /// crashes. Re-point the tap whenever the system's process list changes.
    private func installProcessListener() {
        var addr = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshTappedProcesses() }
        processListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
    }

    private func removeProcessListener() {
        guard let listener = processListener else { return }
        var addr = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        processListener = nil
    }

    private func refreshTappedProcesses() {
        guard tapID != kAudioObjectUnknown, let desc = tapDescription else { return }
        let objects = currentTargetObjects()
        guard Set(objects) != Set(tappedObjects) else { return }
        desc.processes = objects
        var addr = AudioObject.address(kAudioTapPropertyDescription)
        // The property value is the object pointer itself.
        var ref = Unmanaged.passUnretained(desc).toOpaque()
        let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        if status == noErr {
            tappedObjects = objects
            Log.info("tap now follows \(objects.count) process(es) for \(target)")
        } else {
            Log.warn("could not update tap processes: \(fourCC(status))")
        }
    }
}

/// PIDs of running apps with a bundle ID, usable off the main thread.
func NSRunningApplicationPIDs(bundleID: String) -> [pid_t] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
}
