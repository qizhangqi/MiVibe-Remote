import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

/// Builds an AudioBufferList over the given Float arrays (one AudioBuffer per
/// array) and hands it to `body`.
private func withBufferList(
    _ channels: [[Float]],
    channelsPerBuffer: [Int],
    _ body: (UnsafeMutableAudioBufferListPointer) -> Void
) {
    let list = AudioBufferList.allocate(maximumBuffers: channels.count)
    defer { free(list.unsafeMutablePointer) }
    var storage = channels
    storage.withUnsafeMutableBufferPointer { arrays in
        var pointers: [UnsafeMutablePointer<Float>] = []
        for index in arrays.indices {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: arrays[index].count)
            pointer.initialize(from: arrays[index], count: arrays[index].count)
            pointers.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channelsPerBuffer[index]),
                mDataByteSize: UInt32(arrays[index].count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        defer { pointers.forEach { $0.deallocate() } }
        body(list)
    }
}

/// The downmix the AVCaptureSession version did in captureOutput.
private func previousDownmix(_ values: [Float], channels: Int) -> [Float] {
    guard channels > 1 else { return values }
    let frameCount = values.count / channels
    return (0..<frameCount).map { frame in
        var sum: Float = 0
        for channel in 0..<channels {
            sum += values[frame * channels + channel]
        }
        return sum / Float(channels)
    }
}

private func randomSamples(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
    }
}

@Suite("Built-in microphone capture")
struct BuiltInMicrophoneCaptureTests {
    @Test func aMonoBufferIsPassedOnWithoutCopying() {
        let samples = randomSamples(512, seed: 1)
        var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16)
        defer { scratch.deallocate() }
        withBufferList([samples], channelsPerBuffer: [1]) { list in
            let mono = BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch)
            #expect(UnsafeRawPointer(mono?.baseAddress) == UnsafeRawPointer(list[0].mData))
            #expect(mono.map { Array($0) } == samples)
        }
        #expect(scratch.count == 16) // untouched
    }

    @Test func interleavedChannelsAreAveragedExactlyAsBefore() {
        for channels in [2, 3, 4] {
            let samples = randomSamples(512 * channels, seed: UInt64(channels))
            var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4_096)
            defer { scratch.deallocate() }
            withBufferList([samples], channelsPerBuffer: [channels]) { list in
                let mono = BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch)
                #expect(mono.map { Array($0) } == previousDownmix(samples, channels: channels))
            }
        }
    }

    @Test func separateChannelBuffersAreAveragedPerFrame() {
        let left = randomSamples(256, seed: 7)
        let right = randomSamples(256, seed: 8)
        var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4_096)
        defer { scratch.deallocate() }
        withBufferList([left, right], channelsPerBuffer: [1, 1]) { list in
            let mono = BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch)
            #expect(mono.map { Array($0) } == zip(left, right).map { (0 + $0 + $1) / 2 })
        }
    }

    @Test func scratchGrowsForLongCycles() {
        let samples = randomSamples(2 * 6_000, seed: 3)
        var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4_096)
        defer { scratch.deallocate() }
        withBufferList([samples], channelsPerBuffer: [2]) { list in
            let mono = BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch)
            #expect(mono?.count == 6_000)
            #expect(mono.map { Array($0) } == previousDownmix(samples, channels: 2))
        }
        #expect(scratch.count >= 6_000)
    }

    @Test func emptyCyclesProduceNothing() {
        var scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16)
        defer { scratch.deallocate() }
        withBufferList([[]], channelsPerBuffer: [1]) { list in
            #expect(BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch) == nil)
        }
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 64, mData: nil)
        #expect(BuiltInMicrophoneCapture.monoSamples(list, scratch: &scratch) == nil)
    }

    @Test func picksTheBuiltInMicrophoneByUIDThenByName() {
        let headset = AudioDeviceInfo(id: 1, uid: "headset", name: "AirPods")
        let virtual = AudioDeviceInfo(id: 2, uid: "MiRemoteV2ch_UID", name: "MiRemoteV 2ch")
        let builtIn = AudioDeviceInfo(id: 3, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        let renamed = AudioDeviceInfo(id: 4, uid: "other", name: "MacBook Air Microphone")

        #expect(BuiltInMicrophoneCapture.builtInMicrophone(in: [headset, renamed, builtIn, virtual]) == builtIn)
        #expect(BuiltInMicrophoneCapture.builtInMicrophone(in: [headset, renamed, virtual]) == renamed)
        #expect(BuiltInMicrophoneCapture.builtInMicrophone(in: [headset, virtual]) == nil)
    }

    @Test func acceptsOnlyFloat32PCM() {
        func format(_ id: AudioFormatID, bits: UInt32, flags: AudioFormatFlags, rate: Double = 48_000) -> AudioStreamBasicDescription {
            var format = AudioStreamBasicDescription()
            format.mFormatID = id
            format.mBitsPerChannel = bits
            format.mFormatFlags = flags
            format.mSampleRate = rate
            return format
        }
        let float = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        #expect(BuiltInMicrophoneCapture.isSupported(format(kAudioFormatLinearPCM, bits: 32, flags: float)))
        #expect(BuiltInMicrophoneCapture.isSupported(
            format(kAudioFormatLinearPCM, bits: 32, flags: float | kAudioFormatFlagIsNonInterleaved)
        ))
        #expect(!BuiltInMicrophoneCapture.isSupported(
            format(kAudioFormatLinearPCM, bits: 16, flags: kAudioFormatFlagIsSignedInteger)
        ))
        #expect(!BuiltInMicrophoneCapture.isSupported(format(kAudioFormatAppleLossless, bits: 32, flags: float)))
        #expect(!BuiltInMicrophoneCapture.isSupported(format(kAudioFormatLinearPCM, bits: 32, flags: float, rate: 0)))
    }

    @Test func statusTextsAreUnchanged() {
        #expect(BuiltInMicrophoneCapture.State.idle.statusText == "电脑麦克风尚未启动")
        #expect(BuiltInMicrophoneCapture.State.running(deviceName: "MacBook Pro Microphone").statusText
            == "电脑语音：MacBook Pro Microphone → MiRemoteV 2ch")
        #expect(BuiltInMicrophoneCapture.State.permissionDenied.statusText == "未授权电脑麦克风；遥控器语音仍可使用")
        #expect(BuiltInMicrophoneCapture.State.deviceUnavailable.statusText == "未找到 MacBook 内置麦克风")
        #expect(BuiltInMicrophoneCapture.State.failed(message: "x").statusText == "电脑麦克风启动失败：x")
    }

    @Test func aCaptureThatNeverStartedCanBeReleased() {
        var capture: BuiltInMicrophoneCapture? = BuiltInMicrophoneCapture()
        capture?.stop()
        capture = nil
        #expect(capture == nil)
    }
}
