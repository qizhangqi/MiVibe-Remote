import AudioToolbox
import CoreAudio
import Foundation

/// A stable source multiplexer for MiRemoteV 2ch.
///
/// Unlike AVAudioEngine, this class opens the virtual output device directly.
/// That avoids macOS constructing a default input/output aggregate when the
/// default input is MiRemoteV and the default output is a Bluetooth headset.
final class StableVirtualAudioOutput {
    private static let remoteSampleRate: Double = 16_000
    private static let outputSampleRate: Double = 48_000
    private static let maximumRemoteQueueFrames = Int(outputSampleRate * 5)
    private static let maximumBuiltInQueueFrames = Int(outputSampleRate / 2)

    private let stateLock = NSLock()
    private let builtInCapture = BuiltInMicrophoneCapture()
    private var outputDeviceID: AudioDeviceID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var pendingOutput: [Float] = []
    private var pendingOutputIndex = 0
    private var pendingCompletion: ((Bool) -> Void)?
    private var remoteActive = false
    private var testToneActive = false
    private var builtInMicrophonePassthroughEnabled = false
    private var rejectedWriteCount = 0
    private var lastRejectedWriteLogDate = Date.distantPast
    /// Mono frames for one render cycle; only touched on the output IO thread,
    /// so render() does not allocate on the real-time thread.
    private var renderScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4_096)

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = "未选择语音输出设备"
    var onConfigurationChange: (() -> Void)?
    var onBuiltInMicrophoneStateChange: ((BuiltInMicrophoneCapture.State) -> Void)?

    init() {
        builtInCapture.onSamples = { [weak self] samples, sampleRate in
            self?.enqueueBuiltIn(samples: samples, sampleRate: sampleRate)
        }
        builtInCapture.onStateChange = { [weak self] state in
            self?.onBuiltInMicrophoneStateChange?(state)
            AppLogger.shared.write("AUDIO BUILTIN_CAPTURE state=\(state.statusText)")
        }
    }

    deinit {
        renderScratch.deallocate()
    }

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        let previousState = diagnosticState()
        stopOutput()
        guard !deviceUID.isEmpty else {
            status = "未选择语音输出设备"
            return false
        }
        let availableDevices = CoreAudioDeviceCatalog.outputDevices()
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            status = "所选语音输出设备不可用"
            AppLogger.shared.write(
                "AUDIO DIRECT_CONFIGURE failed reason=selected_device_unavailable " +
                    "available={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(availableDevices))}"
            )
            return false
        }

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            device.id,
            nil
        ) { [weak self] _, _, _, outputData, _ in
            self?.render(outputData)
        }
        guard createStatus == noErr, let ioProcID else {
            status = "无法打开虚拟麦克风（错误 \(createStatus)）"
            AppLogger.shared.write(
                "AUDIO DIRECT_CONFIGURE failed reason=create_ioproc error=\(createStatus)"
            )
            return false
        }
        // This IOProc only writes. Left on, Core Audio would also hand it the
        // device's loopback input every cycle and run the app's microphone mode
        // (e.g. Voice Isolation) on that input for nothing.
        let inputOffStatus = IOProcInputStreams.turnOff(device: device.id, ioProcID: ioProcID)

        let startStatus = AudioDeviceStart(device.id, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
            status = "无法启动虚拟麦克风（错误 \(startStatus)）"
            AppLogger.shared.write(
                "AUDIO DIRECT_CONFIGURE failed reason=start_device error=\(startStatus)"
            )
            return false
        }

        outputDeviceID = device.id
        outputIOProcID = ioProcID
        selectedDevice = device
        status = "语音输出：\(device.name)"
        updateBuiltInMicrophoneCapture()
        AppLogger.shared.write(
            "AUDIO DIRECT_READY target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                "previous={\(previousState)} state={\(diagnosticState())} " +
                "input_off=\(inputOffStatus == noErr ? "ok" : "error \(inputOffStatus)")"
        )
        return true
    }

    func isHealthy(configuredDeviceUID: String, availableDevices: [AudioDeviceInfo]) -> Bool {
        !configuredDeviceUID.isEmpty &&
            availableDevices.contains(where: { $0.uid == configuredDeviceUID }) &&
            selectedDevice?.uid == configuredDeviceUID &&
            outputDeviceID == selectedDevice?.id &&
            outputIOProcID != nil
    }

    var isReadyForTestTone: Bool {
        outputDeviceID != nil && outputIOProcID != nil
    }

    func retryBuiltInMicrophoneCapture() {
        guard builtInMicrophonePassthroughEnabled else { return }
        builtInCapture.retry()
    }

    func setBuiltInMicrophonePassthroughEnabled(_ enabled: Bool) {
        guard builtInMicrophonePassthroughEnabled != enabled else {
            updateBuiltInMicrophoneCapture()
            return
        }
        builtInMicrophonePassthroughEnabled = enabled
        updateBuiltInMicrophoneCapture()
        AppLogger.shared.write(
            "AUDIO BUILTIN_PASSTHROUGH enabled=\(enabled) output_ready=\(outputIOProcID != nil)"
        )
    }

    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone else { return false }
        let intSamples = TestToneGenerator.samples(sampleRate: Self.remoteSampleRate)
        let floatSamples = intSamples.map { Float($0) / Float(Int16.max) }
        let resampled = Self.resample(
            floatSamples,
            from: Self.remoteSampleRate,
            to: Self.outputSampleRate
        )

        var cancelledCompletion: ((Bool) -> Void)?
        stateLock.lock()
        cancelledCompletion = pendingCompletion
        pendingCompletion = nil
        clearPendingOutputLocked()
        testToneActive = true
        pendingOutput.append(contentsOf: resampled)
        pendingCompletion = { [weak self] played in
            self?.setTestToneActive(false)
            completion(played)
        }
        stateLock.unlock()
        dispatchCompletion(cancelledCompletion, played: false)
        return true
    }

    func cancelTestTone() {
        var completion: ((Bool) -> Void)?
        stateLock.lock()
        testToneActive = false
        completion = pendingCompletion
        pendingCompletion = nil
        clearPendingOutputLocked()
        stateLock.unlock()
        dispatchCompletion(completion, played: false)
    }

    @discardableResult
    func enqueue(samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return true }
        let floatSamples = samples.map { Float($0) / Float(Int16.max) }
        let resampled = Self.resample(
            floatSamples,
            from: Self.remoteSampleRate,
            to: Self.outputSampleRate
        )

        stateLock.lock()
        guard remoteActive, outputIOProcID != nil else {
            stateLock.unlock()
            logRejectedWrite()
            return false
        }
        compactPendingOutputLocked()
        pendingOutput.append(contentsOf: resampled)
        trimPendingOutputLocked(maximumFrames: Self.maximumRemoteQueueFrames)
        stateLock.unlock()

        if rejectedWriteCount > 0 {
            AppLogger.shared.write(
                "AUDIO WRITE resumed rejected_count=\(rejectedWriteCount) state={\(basicDiagnosticState())}"
            )
            rejectedWriteCount = 0
        }
        return true
    }

    /// Switches sources inside the continuously running virtual microphone.
    func setRemoteActive(_ active: Bool) {
        var cancelledCompletion: ((Bool) -> Void)?
        stateLock.lock()
        let changed = remoteActive != active
        remoteActive = active
        if active {
            testToneActive = false
        }
        if changed {
            cancelledCompletion = pendingCompletion
            pendingCompletion = nil
            clearPendingOutputLocked()
        }
        stateLock.unlock()
        dispatchCompletion(cancelledCompletion, played: false)
        if changed {
            AppLogger.shared.write(
                active ? "AUDIO SOURCE switched=remote" : "AUDIO SOURCE switched=builtin"
            )
        }
    }

    func endSession() {
        var completion: ((Bool) -> Void)?
        stateLock.lock()
        completion = pendingCompletion
        pendingCompletion = nil
        clearPendingOutputLocked()
        stateLock.unlock()
        dispatchCompletion(completion, played: false)
    }

    @discardableResult
    func drainSession(
        trailingSilenceDuration: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard isReadyForTestTone else { return false }
        let frameCount = max(
            1,
            Int((Self.outputSampleRate * trailingSilenceDuration).rounded())
        )
        var replacedCompletion: ((Bool) -> Void)?
        stateLock.lock()
        guard remoteActive else {
            stateLock.unlock()
            return false
        }
        replacedCompletion = pendingCompletion
        pendingCompletion = completion
        pendingOutput.append(contentsOf: repeatElement(0, count: frameCount))
        stateLock.unlock()
        dispatchCompletion(replacedCompletion, played: false)
        return true
    }

    func stop() {
        builtInCapture.stop()
        stopOutput()
    }

    /// Releases the virtual microphone IOProc when no source is using it.
    /// Keeping the device selected as the system input does not require the
    /// MiVibe process to hold an active CoreAudio stream while idle.
    @discardableResult
    func suspendWhenIdle() -> Bool {
        stateLock.lock()
        let canSuspend = !remoteActive && !testToneActive && pendingCompletion == nil
        stateLock.unlock()
        guard canSuspend else {
            AppLogger.shared.write("AUDIO IDLE_SUSPEND skipped reason=source_active")
            return false
        }

        let wasRunning = outputIOProcID != nil
        stopOutput()
        status = "虚拟麦克风待命；按住遥控器语音键时启动"
        if wasRunning {
            AppLogger.shared.write("AUDIO IDLE_SUSPEND completed")
        }
        return true
    }

    func diagnosticState() -> String {
        "\(basicDiagnosticState()) \(CoreAudioDeviceCatalog.routeDiagnostic())"
    }

    /// Runs on the microphone's IO thread.
    private func enqueueBuiltIn(samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        // The built-in microphone normally runs at 48 kHz already; then the
        // samples go straight into the queue without allocating anything.
        let resampled: [Float]? = abs(sampleRate - Self.outputSampleRate) < 1
            ? nil
            : Self.resample(Array(samples), from: sampleRate, to: Self.outputSampleRate)

        stateLock.lock()
        guard !remoteActive, !testToneActive, outputIOProcID != nil else {
            stateLock.unlock()
            return
        }
        compactPendingOutputLocked()
        if let resampled {
            pendingOutput.append(contentsOf: resampled)
        } else {
            pendingOutput.append(contentsOf: samples)
        }
        trimPendingOutputLocked(maximumFrames: Self.maximumBuiltInQueueFrames)
        stateLock.unlock()
    }

    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = buffers.first else { return }
        let firstChannels = max(1, Int(first.mNumberChannels))
        let frameCount = Int(first.mDataByteSize) /
            MemoryLayout<Float>.size /
            firstChannels
        guard frameCount > 0 else { return }

        if renderScratch.count < frameCount {
            renderScratch.deallocate()
            renderScratch = .allocate(capacity: frameCount)
        }
        let mono = UnsafeMutableBufferPointer(rebasing: renderScratch[0..<frameCount])
        mono.update(repeating: 0)
        var completion: ((Bool) -> Void)?
        stateLock.lock()
        let available = pendingOutput.count - pendingOutputIndex
        if available > 0 {
            let take = min(frameCount, available)
            pendingOutput.withUnsafeBufferPointer { pending in
                mono.baseAddress!.update(
                    from: pending.baseAddress! + pendingOutputIndex,
                    count: take
                )
            }
            pendingOutputIndex += take
            compactPendingOutputLocked()
        }
        if pendingOutput.count == pendingOutputIndex, pendingCompletion != nil {
            completion = pendingCompletion
            pendingCompletion = nil
            clearPendingOutputLocked()
        }
        stateLock.unlock()

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let writableFrames = min(
                frameCount,
                Int(buffer.mDataByteSize) /
                    MemoryLayout<Float>.size /
                    channelCount
            )
            let output = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<writableFrames {
                for channel in 0..<channelCount {
                    output[frame * channelCount + channel] = mono[frame]
                }
            }
        }
        dispatchCompletion(completion, played: true)
    }

    private func stopOutput() {
        var completion: ((Bool) -> Void)?
        stateLock.lock()
        completion = pendingCompletion
        pendingCompletion = nil
        clearPendingOutputLocked()
        remoteActive = false
        testToneActive = false
        stateLock.unlock()
        dispatchCompletion(completion, played: false)

        if let deviceID = outputDeviceID, let ioProcID = outputIOProcID {
            let stopStatus = AudioDeviceStop(deviceID, ioProcID)
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            AppLogger.shared.write(
                "AUDIO DIRECT_STOP stop=\(stopStatus) destroy=\(destroyStatus)"
            )
        }
        outputIOProcID = nil
        outputDeviceID = nil
        selectedDevice = nil
        builtInCapture.stop()
    }

    private func updateBuiltInMicrophoneCapture() {
        if BuiltInMicrophonePassthroughPolicy.shouldCapture(
            enabled: builtInMicrophonePassthroughEnabled,
            hasVirtualOutput: outputIOProcID != nil
        ) {
            builtInCapture.start()
        } else {
            builtInCapture.stop()
        }
    }

    private func setTestToneActive(_ active: Bool) {
        stateLock.lock()
        testToneActive = active
        stateLock.unlock()
    }

    private func compactPendingOutputLocked() {
        if pendingOutputIndex > 4_096 {
            pendingOutput.removeFirst(pendingOutputIndex)
            pendingOutputIndex = 0
        }
    }

    private func clearPendingOutputLocked() {
        pendingOutput.removeAll(keepingCapacity: true)
        pendingOutputIndex = 0
    }

    private func trimPendingOutputLocked(maximumFrames: Int) {
        let available = pendingOutput.count - pendingOutputIndex
        if available > maximumFrames {
            pendingOutputIndex += available - maximumFrames
            compactPendingOutputLocked()
        }
    }

    private func dispatchCompletion(_ completion: ((Bool) -> Void)?, played: Bool) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(played)
        }
    }

    private func basicDiagnosticState() -> String {
        stateLock.lock()
        let source = remoteActive ? "remote" : "builtin"
        let queued = pendingOutput.count - pendingOutputIndex
        stateLock.unlock()
        return "direct_running=\(outputIOProcID != nil) source=\(source) queued_frames=\(queued) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(selectedDevice))}"
    }

    private func logRejectedWrite() {
        rejectedWriteCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastRejectedWriteLogDate) >= 1 else { return }
        lastRejectedWriteLogDate = now
        AppLogger.shared.write(
            "AUDIO WRITE rejected count=\(rejectedWriteCount) state={\(basicDiagnosticState())}"
        )
    }

    private static func resample(
        _ input: [Float],
        from inputRate: Double,
        to outputRate: Double
    ) -> [Float] {
        guard !input.isEmpty, inputRate > 0, outputRate > 0 else { return [] }
        guard abs(inputRate - outputRate) >= 1 else { return input }
        let ratio = outputRate / inputRate
        let outputCount = max(1, Int((Double(input.count) * ratio).rounded(.down)))
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = input[lower] + (input[upper] - input[lower]) * fraction
        }
        return output
    }
}

/// The input half of `kAudioDevicePropertyIOProcStreamUsage`: which of a
/// device's input streams Core Audio hands to one IOProc.
enum IOProcInputStreams {
    private static let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
    private static let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    private static let inputUsageAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Whether each input stream is on for `ioProcID`; nil if Core Audio refuses.
    static func areOn(device: AudioDeviceID, ioProcID: AudioDeviceIOProcID) -> [Bool]? {
        usage(device: device, ioProcID: ioProcID)?.withUnsafeBytes { raw in
            (0..<count(raw)).map { raw.load(fromByteOffset: flagsOffset + $0 * 4, as: UInt32.self) != 0 }
        }
    }

    /// Stops Core Audio from handing `device`'s input to `ioProcID`.
    static func turnOff(device: AudioDeviceID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        guard var bytes = usage(device: device, ioProcID: ioProcID) else {
            return kAudioHardwareUnspecifiedError
        }
        var address = inputUsageAddress
        return bytes.withUnsafeMutableBytes { raw in
            for index in 0..<count(UnsafeRawBufferPointer(raw)) {
                raw.storeBytes(of: 0, toByteOffset: flagsOffset + index * 4, as: UInt32.self)
            }
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(raw.count), raw.baseAddress!)
        }
    }

    /// The property's bytes for `ioProcID`, which Core Audio reads from the first field.
    private static func usage(device: AudioDeviceID, ioProcID: AudioDeviceIOProcID) -> [UInt8]? {
        var address = inputUsageAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= flagsOffset else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let status = bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? bytes : nil
    }

    /// Streams listed in `raw`, capped by how many flags actually fit.
    private static func count(_ raw: UnsafeRawBufferPointer) -> Int {
        min(Int(raw.load(fromByteOffset: countOffset, as: UInt32.self)), (raw.count - flagsOffset) / 4)
    }
}

enum BuiltInMicrophonePassthroughPolicy {
    static func shouldCapture(enabled: Bool, hasVirtualOutput: Bool) -> Bool {
        enabled && hasVirtualOutput
    }
}
