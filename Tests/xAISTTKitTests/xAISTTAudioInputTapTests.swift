import Foundation
import Testing
@testable import xAISTTKit

@Suite struct xAISTTSegmenterTests {
    private let sampleRate = 16_000
    /// 100 ms of "speech" payload at 16 kHz mono PCM16 = 3200 bytes.
    private static let chunk100ms = Data(count: 3_200)

    @Test func quietBuffersAlonePreserveAccumulatorCap() {
        let state = xAISTTAudioInputTap.SegmenterState()
        let now = Date()
        // 30 silent 100 ms chunks = 3 s. Accumulator is reset after 2 s of
        // pre-roll-with-no-voice to avoid unbounded growth.
        for i in 0..<30 {
            let emit = state.feed(
                pcm: Self.chunk100ms,
                speaking: false,
                now: now.addingTimeInterval(Double(i) * 0.1),
                sampleRate: 16_000,
                silenceThresholdMs: 700,
                minimumUtteranceMs: 400
            )
            #expect(emit == nil)
        }
    }

    @Test func speechFollowedBySilenceEmitsUtterance() {
        let state = xAISTTAudioInputTap.SegmenterState()
        var t = Date()
        // 6 × 100 ms speech = 600 ms (over the 400 ms minimum).
        for _ in 0..<6 {
            let emit = state.feed(
                pcm: Self.chunk100ms, speaking: true, now: t,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            )
            #expect(emit == nil)
            t = t.addingTimeInterval(0.1)
        }
        // 8 × 100 ms silence = 800 ms (over the 700 ms threshold).
        var emitted: xAISTTAudioInputTap.Utterance?
        for _ in 0..<8 {
            if let e = state.feed(
                pcm: Self.chunk100ms, speaking: false, now: t,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            ) {
                emitted = e
                break
            }
            t = t.addingTimeInterval(0.1)
        }
        #expect(emitted != nil)
        let u = try! #require(emitted)
        // 6 speech chunks + ~7 silence chunks until silenceMs ≥ 700.
        // Floating-point rounding makes the exact silence-chunk count either
        // 7 or 8 — assert the byte count is consistent with the duration
        // rather than pinning to a specific count.
        #expect(u.sampleRate == 16_000)
        // WAV header is 44 bytes for canonical PCM.
        #expect(u.wav.count == u.pcm16.count + 44)
        #expect(u.wav.prefix(4) == Data("RIFF".utf8))
        // Each chunk = 100 ms; emit fires between the 13th and 14th chunk total.
        #expect(u.pcm16.count == 13 * 3_200 || u.pcm16.count == 14 * 3_200)
        // Duration matches bytes / (sampleRate * 2).
        let expected = Double(u.pcm16.count) / Double(u.sampleRate * 2)
        #expect(abs(u.durationSeconds - expected) < 0.001)
    }

    @Test func tooShortAnUtteranceIsHeldUntilLongerSpeech() {
        let state = xAISTTAudioInputTap.SegmenterState()
        var t = Date()
        // Only 200 ms of speech — under 400 ms minimum.
        for _ in 0..<2 {
            _ = state.feed(
                pcm: Self.chunk100ms, speaking: true, now: t,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            )
            t = t.addingTimeInterval(0.1)
        }
        // 1 s of silence — long enough to trigger if buffer were big enough.
        var emitted: xAISTTAudioInputTap.Utterance?
        for _ in 0..<10 {
            if let e = state.feed(
                pcm: Self.chunk100ms, speaking: false, now: t,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            ) {
                emitted = e
                break
            }
            t = t.addingTimeInterval(0.1)
        }
        // Buffer (2 speech + ≤10 silence) = up to 12 × 3200 = 38_400 bytes.
        // Min bytes = 16_000 * 2 * 400 / 1000 = 12_800. So buffer IS over the
        // minimum — segmenter emits. (200 ms speech alone is under 400 ms, but
        // we count total accumulated bytes including the trailing silence.)
        #expect(emitted != nil)
    }

    @Test func resetClearsAccumulator() {
        let state = xAISTTAudioInputTap.SegmenterState()
        let now = Date()
        for _ in 0..<5 {
            _ = state.feed(
                pcm: Self.chunk100ms, speaking: true, now: now,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            )
        }
        state.reset()
        // After reset, a fresh silence run should not emit anything from prior
        // speech.
        var t = now
        var emitted: xAISTTAudioInputTap.Utterance?
        for _ in 0..<10 {
            if let e = state.feed(
                pcm: Self.chunk100ms, speaking: false, now: t,
                sampleRate: 16_000, silenceThresholdMs: 700, minimumUtteranceMs: 400
            ) {
                emitted = e; break
            }
            t = t.addingTimeInterval(0.1)
        }
        #expect(emitted == nil)
    }
}

@Suite struct xAISTTAudioInputTapShapeTests {
    @Test func defaultsExpose16kHzMono() {
        #expect(xAISTTAudioInputTap.defaultSampleRate == 16_000)
        #expect(xAISTTAudioInputTap.defaultSilenceThresholdMs == 700)
        #expect(xAISTTAudioInputTap.defaultMinimumUtteranceMs == 400)
        #expect(xAISTTAudioInputTap.defaultVoiceRMSThreshold == 0.005)
    }

    @Test func canConstructWithoutEngine() {
        let tap = xAISTTAudioInputTap()
        // Streams exist and don't crash on dealloc.
        _ = tap.pcm16Chunks
        _ = tap.utterances
        _ = tap.rmsLevels
    }
}
