import AVFoundation
import CoreAudio
import Foundation

/// Captures the Mac's physical built-in microphone explicitly, independent of
/// the system default input. This prevents a connected Bluetooth headset or the
/// MiRemoteV virtual device from becoming the idle passthrough source.
///
/// The device is read with a CoreAudio IOProc, the same way
/// StableVirtualAudioOutput writes MiRemoteV 2ch. AVCaptureSession, used
/// before, ran a CoreMediaIO conversion graph that cost about 1.6% of a core
/// while idle.
final class BuiltInMicrophoneCapture {
    enum State: Equatable {
        case idle
        case requestingPermission
        case running(deviceName: String)
        case permissionDenied
        case deviceUnavailable
        case failed(message: String)

        var statusText: String {
            switch self {
            case .idle:
                return "电脑麦克风尚未启动"
            case .requestingPermission:
                return "正在请求电脑麦克风权限"
            case let .running(deviceName):
                return "电脑语音：\(deviceName) → MiRemoteV 2ch"
            case .permissionDenied:
                return "未授权电脑麦克风；遥控器语音仍可使用"
            case .deviceUnavailable:
                return "未找到 MacBook 内置麦克风"
            case let .failed(message):
                return "电脑麦克风启动失败：\(message)"
            }
        }
    }

    /// Called on the CoreAudio IO thread with one IO cycle of mono samples and
    /// the device's sample rate. The buffer is only valid during the call;
    /// handlers must not block.
    var onSamples: ((UnsafeBufferPointer<Float>, Double) -> Void)?
    var onStateChange: ((State) -> Void)?

    private static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    private let queue = DispatchQueue(
        label: "com.mivibe.remote.builtin-microphone",
        qos: .userInteractive
    )
    private var startRequested = false

    // Owned by `queue`.
    private var deviceID: AudioDeviceID?
    private var ioProcID: AudioDeviceIOProcID?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    // Only touched on the IO thread.
    private var downmixScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4_096)

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [weak self, state] in
                self?.onStateChange?(state)
            }
        }
    }

    deinit {
        // No other reference exists any more, so no queue hop is needed (and a
        // sync onto `queue` could deadlock if the last release happened there).
        removeDevicesListener()
        stopDevice()
        downmixScratch.deallocate()
    }

    func start() {
        guard !startRequested else { return }
        startRequested = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    self.state = .permissionDenied
                }
            }
        default:
            state = .permissionDenied
        }
    }

    func stop() {
        startRequested = false
        queue.async { [weak self] in
            guard let self else { return }
            self.removeDevicesListener()
            self.stopDevice()
            self.state = .idle
        }
    }

    func retry() {
        guard !queue.sync(execute: { ioProcID != nil }) else { return }
        startRequested = false
        start()
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self, self.startRequested else { return }
            self.addDevicesListener()
            guard self.ioProcID == nil else { return }
            self.startDevice()
        }
    }

    // MARK: - Device (on `queue`)

    private func startDevice() {
        let inputDevices = CoreAudioDeviceCatalog.inputDevices()
        guard let device = Self.builtInMicrophone(in: inputDevices) else {
            state = .deviceUnavailable
            AppLogger.shared.write("AUDIO BUILTIN_CAPTURE failed reason=device_unavailable")
            return
        }
        guard let format = CoreAudioDeviceCatalog.inputStreamFormat(for: device.id),
              Self.isSupported(format)
        else {
            state = .failed(message: "麦克风格式不受支持")
            AppLogger.shared.write("AUDIO BUILTIN_CAPTURE failed reason=unsupported_format")
            return
        }

        let sampleRate = format.mSampleRate
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            device.id,
            nil
        ) { [weak self] _, inputData, _, _, _ in
            self?.deliver(inputData, sampleRate: sampleRate)
        }
        guard createStatus == noErr, let procID else {
            state = .failed(message: "无法建立采集通道")
            AppLogger.shared.write(
                "AUDIO BUILTIN_CAPTURE failed reason=create_ioproc error=\(createStatus)"
            )
            return
        }
        let startStatus = AudioDeviceStart(device.id, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, procID)
            state = .failed(message: "采集会话未运行")
            AppLogger.shared.write(
                "AUDIO BUILTIN_CAPTURE failed reason=start_device error=\(startStatus)"
            )
            return
        }

        deviceID = device.id
        ioProcID = procID
        addSampleRateListener(deviceID: device.id)
        state = .running(deviceName: device.name)
        AppLogger.shared.write(
            "AUDIO BUILTIN_CAPTURE started device=\(device.name) " +
                "rate=\(Int(sampleRate)) channels=\(format.mChannelsPerFrame)"
        )
    }

    private func stopDevice() {
        guard let deviceID, let ioProcID else { return }
        removeSampleRateListener(deviceID: deviceID)
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.deviceID = nil
        self.ioProcID = nil
    }

    /// The device list changed: let go of a microphone that went away, and
    /// pick it up again when it comes back.
    private func reconcileDevices() {
        guard startRequested else { return }
        if let deviceID {
            guard !CoreAudioDeviceCatalog.inputDevices().contains(where: { $0.id == deviceID }) else {
                return
            }
            stopDevice()
            state = .deviceUnavailable
            AppLogger.shared.write("AUDIO BUILTIN_CAPTURE stopped reason=device_removed")
        } else if state == .deviceUnavailable {
            startDevice()
        }
    }

    /// Another app changed the microphone's sample rate. The IOProc reports
    /// the rate it was started with, so start it again.
    private func restartForNewSampleRate() {
        guard startRequested, ioProcID != nil else { return }
        stopDevice()
        AppLogger.shared.write("AUDIO BUILTIN_CAPTURE restarting reason=sample_rate_change")
        startDevice()
    }

    private func addDevicesListener() {
        guard devicesListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reconcileDevices()
        }
        var address = Self.address(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        ) == noErr {
            devicesListener = listener
        }
    }

    private func removeDevicesListener() {
        guard let listener = devicesListener else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        devicesListener = nil
    }

    private func addSampleRateListener(deviceID: AudioDeviceID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartForNewSampleRate()
        }
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
            sampleRateListener = listener
        }
    }

    private func removeSampleRateListener(deviceID: AudioDeviceID) {
        guard let listener = sampleRateListener else { return }
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        sampleRateListener = nil
    }

    // MARK: - IO thread

    private func deliver(_ inputData: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        guard let onSamples else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let mono = Self.monoSamples(buffers, scratch: &downmixScratch) else { return }
        onSamples(mono, sampleRate)
    }

    // MARK: - Pure helpers

    static func builtInMicrophone(in inputDevices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        inputDevices.first { $0.uid == builtInMicrophoneUID } ?? inputDevices.first {
            $0.name.localizedCaseInsensitiveContains("MacBook")
        }
    }

    static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM &&
            format.mBitsPerChannel == 32 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
            format.mSampleRate > 0
    }

    /// One IO cycle as mono samples. A single mono buffer is returned as is,
    /// without copying; otherwise every channel of every buffer is averaged per
    /// frame into `scratch`, which grows if it is too small.
    static func monoSamples(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        scratch: inout UnsafeMutableBufferPointer<Float>
    ) -> UnsafeBufferPointer<Float>? {
        guard let first = buffers.first, let firstData = first.mData else { return nil }
        let frameCount = Int(first.mDataByteSize) /
            MemoryLayout<Float>.size /
            max(1, Int(first.mNumberChannels))
        guard frameCount > 0 else { return nil }
        if buffers.count == 1, first.mNumberChannels <= 1 {
            return UnsafeBufferPointer(
                start: firstData.assumingMemoryBound(to: Float.self),
                count: frameCount
            )
        }

        if scratch.count < frameCount {
            scratch.deallocate()
            scratch = .allocate(capacity: frameCount)
        }
        let mono = UnsafeMutableBufferPointer(rebasing: scratch[0..<frameCount])
        mono.update(repeating: 0)
        var channelTotal = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let values = data.assumingMemoryBound(to: Float.self)
            let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    mono[frame] += values[frame * channels + channel]
                }
            }
            channelTotal += channels
        }
        guard channelTotal > 0 else { return nil }
        let divisor = Float(channelTotal)
        for frame in 0..<frameCount {
            mono[frame] /= divisor
        }
        return UnsafeBufferPointer(mono)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
