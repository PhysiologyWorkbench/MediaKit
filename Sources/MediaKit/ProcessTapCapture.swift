#if os(macOS)
// AppKit for `NSRunningApplication` alone — the bundle-identifier-to-pid
// lookup the tap needs, no UI. Named exception to the family rule that a
// library imports no UI framework (ruled 2026-09-05: baseline, not a seam).
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Explicitly armed capture of another process's audio output via a Core
/// Audio process tap. Nothing captures as a side effect: `arm(bundleIdentifier:)`
/// is the only way the tap opens, and `state` is `.armed` exactly while it is
/// open. The first tap ever created triggers the system-audio recording
/// consent prompt; there is no pre-flight API for this permission class.
@available(macOS 14.4, *)
@MainActor @Observable
public final class ProcessTapCapture {
    public enum State: Equatable, Sendable {
        case idle
        case armed
        case denied
        case failed(String)
    }

    public enum CaptureError: Error {
        case alreadyArmed
        case processNotFound(String)
        case permissionDenied
        case coreAudio(String, OSStatus)
    }

    public private(set) var state: State = .idle

    /// Peak magnitude of the most recent buffer, 0…1, and 0 while idle. The
    /// operator's evidence that the tap is hearing something.
    public private(set) var level: Float = 0

    /// How far the tap's sample clock has drifted from the host clock. A
    /// process tap's clock is synthesised by this process, so a throttled
    /// capture receives stretched audio with unbroken sample time: skew is the
    /// only observable signature of it (CAPTURE-INTEGRITY.md). Detection only
    /// — what to do about a fault is the host's to decide.
    public struct ClockIntegrity: Equatable, Sendable {
        /// Skew over the most recent window, positive when the sample clock
        /// ran ahead. Genuine clocks sit within a few ppm.
        public let skewPPM: Double
        /// Windows whose skew exceeded `skewThresholdPPM` since arming.
        public let faults: Int
    }

    public private(set) var integrity = ClockIntegrity(skewPPM: 0, faults: 0)

    /// Beyond a few hundred ppm the clocks are not merely imprecise; the
    /// benched corruption ran at ~1100.
    public static let skewThresholdPPM: Double = 300

    /// Long enough that per-callback timestamp jitter averages out of the
    /// rate comparison.
    public static let skewWindow: TimeInterval = 10

    private struct Resources {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
    }

    private var resources: Resources?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var activity: NSObjectProtocol?

    public init() {}

    /// Taps the audio output of the running application with the given bundle
    /// identifier and returns the chunk stream. The stream finishes on
    /// `disarm()`; if the consumer stops iterating, capture disarms itself —
    /// a live tap with no consumer is never left behind.
    public func arm(bundleIdentifier: String) throws -> AsyncStream<AudioChunk> {
        guard resources == nil else { throw CaptureError.alreadyArmed }

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first
        else {
            state = .failed("\(bundleIdentifier) is not running")
            throw CaptureError.processNotFound(bundleIdentifier)
        }

        let processObject = try translate(pid: app.processIdentifier)

        let description = CATapDescription(
            stereoMixdownOfProcesses: [processObject])
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            // TCC denial surfaces as an illegal-operation error from tap
            // creation; anything else is a genuine failure.
            if tapStatus == kAudioHardwareIllegalOperationError {
                state = .denied
                throw CaptureError.permissionDenied
            }
            state = .failed("tap creation failed (\(tapStatus))")
            throw CaptureError.coreAudio("AudioHardwareCreateProcessTap", tapStatus)
        }

        do {
            let format = try tapFormat(of: tapID)
            let aggregateID = try makeAggregate(around: description, named: bundleIdentifier)

            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioChunk.self, bufferingPolicy: .bufferingNewest(16))
            let relay = ProcessTapRelay(
                format: format, continuation: continuation,
                skewWindow: Self.skewWindow,
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.level = level }
                },
                onSkew: { [weak self] ppm in
                    Task { @MainActor in
                        guard let self else { return }
                        let faults = self.integrity.faults
                            + (abs(ppm) > Self.skewThresholdPPM ? 1 : 0)
                        self.integrity = ClockIntegrity(skewPPM: ppm, faults: faults)
                    }
                })

            var procID: AudioDeviceIOProcID?
            // Audio-adjacent work: explicit QoS keeps the IO queue out of the
            // throttled band and away from priority inversion.
            let queue = DispatchQueue(label: "MediaKit.ProcessTapCapture",
                                      qos: .userInteractive)
            // `@Sendable` keeps the block out of this actor's isolation, as
            // with the microphone tap: the IO proc fires on `queue`, not here.
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
                @Sendable _, inputData, inputTime, _, _ in
                relay.relay(bufferList: inputData, timestamp: inputTime)
            }
            guard procStatus == noErr, let procID else {
                continuation.finish()
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw CaptureError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", procStatus)
            }
            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                continuation.finish()
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw CaptureError.coreAudio("AudioDeviceStart", startStatus)
            }

            resources = Resources(tapID: tapID, aggregateID: aggregateID, procID: procID)
            self.continuation = continuation
            // A throttled process receives corrupted audio that no gap
            // detection can see, and the tap is the exposed case: its
            // aggregate device is hosted here, so throttling this process
            // throttles the device. The library asserts for the exact extent
            // of the capture rather than leaving it to every host.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "MediaKit process tap capture")
            state = .armed
            continuation.onTermination = { _ in
                Task { @MainActor in self.disarm() }
            }
            return stream
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            if case CaptureError.coreAudio(let what, let status) = error {
                state = .failed("\(what) failed (\(status))")
            }
            throw error
        }
    }

    public func disarm() {
        guard let resources else { return }
        self.resources = nil
        AudioDeviceStop(resources.aggregateID, resources.procID)
        AudioDeviceDestroyIOProcID(resources.aggregateID, resources.procID)
        AudioHardwareDestroyAggregateDevice(resources.aggregateID)
        AudioHardwareDestroyProcessTap(resources.tapID)
        continuation?.finish()
        continuation = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        level = 0
        integrity = ClockIntegrity(skewPPM: 0, faults: 0)
        state = .idle
    }

    /// The HAL audio object standing for the process with the given pid.
    private func translate(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            state = .failed("pid translation failed (\(status))")
            throw CaptureError.coreAudio("TranslatePIDToProcessObject", status)
        }
        return object
    }

    /// The PCM format the tap delivers, read back from the created tap.
    private func tapFormat(of tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.coreAudio("kAudioTapPropertyFormat", status)
        }
        return format
    }

    /// A private aggregate device whose only member is the tap; the IO proc
    /// runs against it and receives the tapped process's output as input.
    private func makeAggregate(around description: CATapDescription,
                               named name: String) throws -> AudioObjectID {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MediaKit tap: \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw CaptureError.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }
        return aggregateID
    }
}

/// Bridges the aggregate device's IO queue to the chunk stream. `@unchecked
/// Sendable`: `window` is touched only from the IO proc's serial queue. Unlike
/// the microphone relay this one copies — the HAL owns its buffer list only
/// for the duration of the callback, and a yielded chunk must outlive it.
private final class ProcessTapRelay: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let onSkew: @Sendable (Double) -> Void
    private let skewWindow: TimeInterval
    /// Established at arm time, not at the first callback, so no chunk start
    /// carries the scheduling latency of whichever callback happened to be it.
    private let hostClock = HostClock()
    /// Start of the open skew window: the two clocks' readings at its edge.
    private var window: (sampleTime: Double, hostTicks: UInt64)?

    init(format: AVAudioFormat,
         continuation: AsyncStream<AudioChunk>.Continuation,
         skewWindow: TimeInterval,
         onLevel: @escaping @Sendable (Float) -> Void,
         onSkew: @escaping @Sendable (Double) -> Void) {
        self.format = format
        self.continuation = continuation
        self.skewWindow = skewWindow
        self.onLevel = onLevel
        self.onSkew = onSkew
    }

    func relay(bufferList: UnsafePointer<AudioBufferList>,
               timestamp: UnsafePointer<AudioTimeStamp>) {
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0, let first = source.first else { return }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        copy.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(min(source[index].mDataByteSize,
                                     destination[index].mDataByteSize)))
        }

        let stamp = timestamp.pointee
        let hostTimeValid = stamp.mFlags.contains(.hostTimeValid)
        let start = hostTimeValid
            ? hostClock.date(forHostTime: stamp.mHostTime)
            : Date()

        if hostTimeValid, stamp.mFlags.contains(.sampleTimeValid) {
            measureSkew(sampleTime: stamp.mSampleTime, hostTicks: stamp.mHostTime)
        }
        onLevel(peakMagnitude(of: copy))
        continuation.yield(AudioChunk(buffer: copy, start: start))
    }

    /// Compares what the two clocks say has elapsed, once per closed window.
    private func measureSkew(sampleTime: Double, hostTicks: UInt64) {
        guard let open = window else {
            window = (sampleTime, hostTicks)
            return
        }
        let hostSeconds = hostClock.seconds(from: open.hostTicks, to: hostTicks)
        guard hostSeconds >= skewWindow else { return }
        onSkew(clockSkewPPM(audioSeconds: (sampleTime - open.sampleTime) / format.sampleRate,
                            hostSeconds: hostSeconds))
        window = (sampleTime, hostTicks)
    }
}
#endif
