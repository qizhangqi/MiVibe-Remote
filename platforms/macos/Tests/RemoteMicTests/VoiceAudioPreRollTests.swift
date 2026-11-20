import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice audio pre-roll")
struct VoiceAudioPreRollTests {
    @Test func buffersTheBeginningAndReleasesItInOrder() {
        var preRoll = VoiceAudioPreRoll(maximumSampleCount: 8)

        preRoll.begin()
        #expect(preRoll.accept([1, 2, 3]) == nil)
        #expect(preRoll.accept([4, 5]) == nil)
        #expect(preRoll.bufferedSamples == [1, 2, 3, 4, 5])
        #expect(preRoll.release() == [1, 2, 3, 4, 5])
        #expect(!preRoll.isBuffering)
        #expect(preRoll.accept([6, 7]) == [6, 7])
    }

    @Test func keepsTheNewestAudioWhenTheSafetyLimitIsReached() {
        var preRoll = VoiceAudioPreRoll(maximumSampleCount: 5)

        preRoll.begin()
        _ = preRoll.accept([1, 2, 3])
        _ = preRoll.accept([4, 5, 6, 7])

        #expect(preRoll.release() == [3, 4, 5, 6, 7])
    }

    @Test func resetDropsPendingAudioAndReturnsToPassThrough() {
        var preRoll = VoiceAudioPreRoll(maximumSampleCount: 8)

        preRoll.begin()
        _ = preRoll.accept([1, 2, 3])
        preRoll.reset()

        #expect(!preRoll.isBuffering)
        #expect(preRoll.bufferedSamples.isEmpty)
        #expect(preRoll.accept([4]) == [4])
    }

    /// If the voice output never becomes healthy (for example no virtual mic
    /// is selected), the pre-roll used to re-check every capture-settle
    /// interval forever, so the voice shortcut stayed held after the key was
    /// released. Once the key is up it must drop the buffered audio (reset,
    /// tested above) and start the normal drain instead of retrying.
    @Test func stopsWaitingForAudioOnceTheVoiceKeyIsReleased() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func scheduleVoicePreRollRelease("))
        let end = try #require(source.range(
            of: "private func releaseVoicePreRoll(",
            range: start.upperBound..<source.endIndex
        ))
        let body = source[start.upperBound..<end.lowerBound]

        let released = try #require(body.range(of: "guard self.isStreaming else {"))
        let retry = try #require(body.range(of: "self.ensureAudioReadyForVoice()"))
        #expect(released.upperBound <= retry.lowerBound)
        let releasedBranch = body[released.upperBound..<retry.lowerBound]
        #expect(releasedBranch.contains("self.voicePreRoll.reset()"))
        #expect(releasedBranch.contains(
            "self.scheduleVoiceDrainAfterPacketSettle(generation: self.voiceStopGeneration)"
        ))
        #expect(releasedBranch.contains("return"))
    }
}
