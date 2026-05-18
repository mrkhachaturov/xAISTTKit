//
//  xAISTTAudioInputTap.swift
//  AVAudioEngine mic-tap helper that emits 16 kHz mono PCM16 chunks ready for
//  ``xAISTTWebSocketSession/send(audio:)`` or ``xAISTTClient/transcribePCM16(_:sampleRate:channels:language:options:)``.
//
//  Two output modes:
//    - `pcm16Chunks` — every tap callback yields its converted PCM16 buffer
//      (use for streaming WebSocket STT).
//    - `utterances` — internal silence-based segmenter emits an `Utterance`
//      after `silenceThresholdMs` of quiet following ≥`minimumUtteranceMs`
//      of speech (use for batch REST STT).
//
//  Defaults: sampleRate=16 kHz, silenceThresholdMs=700, minimumUtteranceMs=400,
//  voiceRMSThreshold=0.005.
//

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
import Foundation
import os

public final class xAISTTAudioInputTap: @unchecked Sendable {

    public static let defaultSampleRate: Double = 16_000
    public static let defaultBufferSize: AVAudioFrameCount = 2_048
    public static let defaultSilenceThresholdMs: Int = 700
    public static let defaultMinimumUtteranceMs: Int = 400
    public static let defaultVoiceRMSThreshold: Float = 0.005

    /// A single end-of-utterance chunk wrapped as a 16-bit LE PCM WAV — drop
    /// straight into ``xAISTTClient/transcribe(audio:filename:contentType:language:options:)``.
    public struct Utterance: Sendable, Equatable {
        /// Raw PCM16 samples (Int16 LE, mono, at `sampleRate`).
        public let pcm16: Data
        /// Same samples wrapped in a RIFF/WAVE header.
        public let wav: Data
        public let sampleRate: Int
        public let durationSeconds: Double
    }

    /// Every converted PCM16 buffer, in order. Pipe into a WebSocket session.
    public nonisolated let pcm16Chunks: AsyncStream<Data>
    /// Silence-segmented utterances. Pipe into the REST client.
    public nonisolated let utterances: AsyncStream<Utterance>
    /// 0…1 rolling RMS values for level metering UI.
    public nonisolated let rmsLevels: AsyncStream<Float>

    private let chunkCont: AsyncStream<Data>.Continuation
    private let utteranceCont: AsyncStream<Utterance>.Continuation
    private let rmsCont: AsyncStream<Float>.Continuation

    private let targetSampleRate: Double
    private let bufferSize: AVAudioFrameCount
    private let silenceThresholdMs: Int
    private let minimumUtteranceMs: Int
    private let voiceRMSThreshold: Float

    private weak var attachedEngine: AVAudioEngine?
    private let state: SegmenterState

    public init(
        targetSampleRate: Double = defaultSampleRate,
        bufferSize: AVAudioFrameCount = defaultBufferSize,
        silenceThresholdMs: Int = defaultSilenceThresholdMs,
        minimumUtteranceMs: Int = defaultMinimumUtteranceMs,
        voiceRMSThreshold: Float = defaultVoiceRMSThreshold
    ) {
        self.targetSampleRate = targetSampleRate
        self.bufferSize = bufferSize
        self.silenceThresholdMs = silenceThresholdMs
        self.minimumUtteranceMs = minimumUtteranceMs
        self.voiceRMSThreshold = voiceRMSThreshold
        let (s1, c1) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let (s2, c2) = AsyncStream<Utterance>.makeStream(bufferingPolicy: .unbounded)
        let (s3, c3) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.pcm16Chunks = s1
        self.chunkCont = c1
        self.utterances = s2
        self.utteranceCont = c2
        self.rmsLevels = s3
        self.rmsCont = c3
        self.state = SegmenterState()
    }

    deinit {
        chunkCont.finish()
        utteranceCont.finish()
        rmsCont.finish()
    }

    @MainActor
    public func install(on engine: AVAudioEngine) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw xAISTTError.decoding("audio input has zero sample rate (mic not configured?)")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw xAISTTError.decoding("could not create target PCM16 format at \(Int(targetSampleRate)) Hz")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw xAISTTError.decoding("could not create AVAudioConverter (\(inputFormat) → \(targetFormat))")
        }

        let box = ConverterBox(converter: converter, source: inputFormat, target: targetFormat)
        let chunkCont = self.chunkCont
        let utteranceCont = self.utteranceCont
        let rmsCont = self.rmsCont
        let segmenter = self.state
        let sampleRate = Int(targetSampleRate)
        let silenceThresholdMs = self.silenceThresholdMs
        let minimumUtteranceMs = self.minimumUtteranceMs
        let voiceRMSThreshold = self.voiceRMSThreshold

        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            let rms = Self.computeRMS(buffer: buffer)
            rmsCont.yield(rms)
            guard let pcm = Self.toPCM16(buffer: buffer, box: box) else { return }
            chunkCont.yield(pcm)

            // Silence-based segmentation. Emit an utterance after
            // silenceThresholdMs of quiet following ≥ minimumUtteranceMs of audio.
            let now = Date()
            let speaking = rms > voiceRMSThreshold
            if let emit = segmenter.feed(
                pcm: pcm,
                speaking: speaking,
                now: now,
                sampleRate: sampleRate,
                silenceThresholdMs: silenceThresholdMs,
                minimumUtteranceMs: minimumUtteranceMs
            ) {
                utteranceCont.yield(emit)
            }
        }
        self.attachedEngine = engine
    }

    @MainActor
    public func stop() {
        attachedEngine?.inputNode.removeTap(onBus: 0)
        attachedEngine = nil
    }

    @MainActor
    public func finish() {
        stop()
        chunkCont.finish()
        utteranceCont.finish()
        rmsCont.finish()
    }

    // MARK: - Internals

    private struct ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        let source: AVAudioFormat
        let target: AVAudioFormat
    }

    private final class OneShotFlag: @unchecked Sendable {
        var consumed = false
    }

    /// Lock-protected segmenter state shared between the render thread and any
    /// future inspection. Exposed at file scope so it can be unit-tested
    /// without an AVAudioEngine.
    final class SegmenterState: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<State>(initialState: State())
        private struct State {
            var accumulator = Data()
            var lastVoice: Date = .distantPast
            var hasSpoken = false
        }

        /// Append `pcm`, check whether silence has persisted long enough, and
        /// optionally return an `Utterance` to emit (resetting internal state).
        func feed(
            pcm: Data,
            speaking: Bool,
            now: Date,
            sampleRate: Int,
            silenceThresholdMs: Int,
            minimumUtteranceMs: Int
        ) -> Utterance? {
            lock.withLock { state in
                state.accumulator.append(pcm)
                if speaking {
                    state.lastVoice = now
                    state.hasSpoken = true
                    return nil
                }
                guard state.hasSpoken else {
                    // No voice yet — never let the pre-roll buffer grow huge.
                    if state.accumulator.count > sampleRate * 2 * 2 {   // 2 s
                        state.accumulator.removeAll(keepingCapacity: true)
                    }
                    return nil
                }
                let silenceMs = Int(now.timeIntervalSince(state.lastVoice) * 1000)
                guard silenceMs >= silenceThresholdMs else { return nil }
                let minBytes = sampleRate * 2 * minimumUtteranceMs / 1000
                guard state.accumulator.count >= minBytes else { return nil }

                let payload = state.accumulator
                state.accumulator.removeAll(keepingCapacity: true)
                state.hasSpoken = false
                state.lastVoice = .distantPast

                let durationSeconds = Double(payload.count) / Double(sampleRate * 2)
                let wav = xAISTTClient.wrapAsWAV(pcm16: payload, sampleRate: sampleRate, channels: 1)
                return Utterance(
                    pcm16: payload,
                    wav: wav,
                    sampleRate: sampleRate,
                    durationSeconds: durationSeconds
                )
            }
        }

        /// Reset state without emitting. For tests / barge-in scenarios.
        func reset() {
            lock.withLock { state in
                state.accumulator.removeAll(keepingCapacity: false)
                state.lastVoice = .distantPast
                state.hasSpoken = false
            }
        }
    }

    static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let floats = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count { sum += floats[i] * floats[i] }
            return sqrt(sum / Float(count))
        }
        if let int16s = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count {
                let v = Float(int16s[i]) / Float(Int16.max)
                sum += v * v
            }
            return sqrt(sum / Float(count))
        }
        return 0
    }

    private static func toPCM16(buffer: AVAudioPCMBuffer, box: ConverterBox) -> Data? {
        let scale = box.target.sampleRate / box.source.sampleRate
        let estimated = AVAudioFrameCount(Double(buffer.frameLength) * scale)
        let capacity = max(estimated, AVAudioFrameCount(box.target.sampleRate))
        guard let out = AVAudioPCMBuffer(pcmFormat: box.target, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let flag = OneShotFlag()
        box.converter.convert(to: out, error: &error) { _, status in
            if flag.consumed { status.pointee = .noDataNow; return nil }
            flag.consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let int16s = out.int16ChannelData?[0] else { return nil }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16s, count: byteCount)
    }
}
