//
//  xAISTTClient.swift
//  xAI Grok Speech-to-Text client.
//
//  POST https://api.x.ai/v1/stt
//  multipart/form-data with fields: language, format, audio_format, sample_rate,
//  multichannel, channels, diarize, keyterm (repeat), filler_words, url, file (LAST).
//  Response: JSON ({ text, language, duration, words[], channels[] }).
//
//  The xAI spec requires `file` to be the final field in the multipart body;
//  `encodeRequestBody` enforces this.
//

import Foundation

public actor xAISTTClient {

    public static let maxFileBytes: Int = 500 * 1024 * 1024   // 500 MB

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var bearer: String
        public var defaultLanguage: xAISTTLanguage?
        public var timeoutSeconds: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://api.x.ai/v1/stt")!,
            bearer: String,
            defaultLanguage: xAISTTLanguage? = nil,
            timeoutSeconds: TimeInterval = 120
        ) {
            self.baseURL = baseURL
            self.bearer = bearer
            self.defaultLanguage = defaultLanguage
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// Optional knobs beyond `audio` + `language`. Fields default to nil — only
    /// non-nil values are added to the multipart body.
    public struct Options: Sendable {
        public var format: Bool?
        public var audioFormat: xAISTTAudioFormat?
        public var sampleRate: Int?
        public var multichannel: Bool?
        public var channels: Int?
        public var diarize: Bool?
        public var fillerWords: Bool?
        public var keyTerms: [String]

        public init(
            format: Bool? = nil,
            audioFormat: xAISTTAudioFormat? = nil,
            sampleRate: Int? = nil,
            multichannel: Bool? = nil,
            channels: Int? = nil,
            diarize: Bool? = nil,
            fillerWords: Bool? = nil,
            keyTerms: [String] = []
        ) {
            self.format = format
            self.audioFormat = audioFormat
            self.sampleRate = sampleRate
            self.multichannel = multichannel
            self.channels = channels
            self.diarize = diarize
            self.fillerWords = fillerWords
            self.keyTerms = keyTerms
        }
    }

    private let config: Configuration
    private let session: URLSession

    public init(config: Configuration) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.timeoutSeconds
        cfg.timeoutIntervalForResource = config.timeoutSeconds
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Transcribe

    /// Transcribe a local audio buffer. Defaults to MP3 — pass `filename` with the
    /// correct extension (or set `options.audioFormat` for headerless PCM/μ-law/A-law).
    public func transcribe(
        audio: Data,
        filename: String = "audio.mp3",
        contentType: String = "audio/mpeg",
        language: xAISTTLanguage? = nil,
        options: Options = Options()
    ) async throws -> xAISTTResponse {
        guard audio.count <= Self.maxFileBytes else {
            throw xAISTTError.fileTooLarge(maxBytes: Self.maxFileBytes, gotBytes: audio.count)
        }
        let resolvedLanguage = language ?? config.defaultLanguage
        if options.format == true && resolvedLanguage == nil {
            throw xAISTTError.formatRequiresLanguage
        }
        if let raw = options.audioFormat, options.sampleRate == nil {
            _ = raw
            throw xAISTTError.rawAudioRequiresSampleRate
        }

        let boundary = "----xai-stt-\(UUID().uuidString)"
        let body = Self.encodeRequestBody(
            boundary: boundary,
            audio: audio,
            filename: filename,
            contentType: contentType,
            language: resolvedLanguage,
            options: options
        )
        return try await send(boundary: boundary, body: body)
    }

    /// Transcribe an audio asset already hosted at a public URL — server downloads it.
    public func transcribe(
        url remoteURL: URL,
        language: xAISTTLanguage? = nil,
        options: Options = Options()
    ) async throws -> xAISTTResponse {
        let resolvedLanguage = language ?? config.defaultLanguage
        if options.format == true && resolvedLanguage == nil {
            throw xAISTTError.formatRequiresLanguage
        }
        let boundary = "----xai-stt-\(UUID().uuidString)"
        let body = Self.encodeRequestBody(
            boundary: boundary,
            audio: nil,
            filename: nil,
            contentType: nil,
            audioURL: remoteURL,
            language: resolvedLanguage,
            options: options
        )
        return try await send(boundary: boundary, body: body)
    }

    /// Convenience: transcribe a 16-bit LE PCM buffer captured at a known sample
    /// rate. Wraps the raw samples with a minimal RIFF/WAVE header so the server
    /// auto-detects the container — no `audio_format`/`sample_rate` fields needed.
    public func transcribePCM16(
        _ pcm: Data,
        sampleRate: Int = 16_000,
        channels: Int = 1,
        language: xAISTTLanguage? = nil,
        options: Options = Options()
    ) async throws -> xAISTTResponse {
        let wav = Self.wrapAsWAV(pcm16: pcm, sampleRate: sampleRate, channels: channels)
        return try await transcribe(
            audio: wav,
            filename: "audio.wav",
            contentType: "audio/wav",
            language: language,
            options: options
        )
    }

    // MARK: - Internals

    private func send(boundary: String, body: Data) async throws -> xAISTTResponse {
        var req = URLRequest(url: config.baseURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw xAISTTError.canceled
        }

        guard let http = response as? HTTPURLResponse else {
            throw xAISTTError.decoding("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(4096), encoding: .utf8)
            throw xAISTTError.http(status: http.statusCode, body: snippet)
        }
        do {
            return try JSONDecoder().decode(xAISTTResponse.self, from: data)
        } catch {
            throw xAISTTError.decoding(String(describing: error))
        }
    }

    // MARK: - Body construction (exposed for tests)

    /// Build the multipart request body. `file` is always last per the xAI spec.
    /// Pass `audio` for direct upload OR `audioURL` for the `url` form field —
    /// not both.
    public static func encodeRequestBody(
        boundary: String,
        audio: Data?,
        filename: String?,
        contentType: String?,
        audioURL: URL? = nil,
        language: xAISTTLanguage?,
        options: Options
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendString(_ s: String) {
            if let bytes = s.data(using: .utf8) { body.append(bytes) }
        }
        func appendField(name: String, value: String) {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            appendString(value)
            appendString(crlf)
        }

        // Order: scalar fields first, then `url` if provided, then `file` (last).
        if let language { appendField(name: "language", value: language.rawValue) }
        if let format = options.format { appendField(name: "format", value: format ? "true" : "false") }
        if let audioFormat = options.audioFormat { appendField(name: "audio_format", value: audioFormat.rawValue) }
        if let sampleRate = options.sampleRate { appendField(name: "sample_rate", value: String(sampleRate)) }
        if let multichannel = options.multichannel { appendField(name: "multichannel", value: multichannel ? "true" : "false") }
        if let channels = options.channels { appendField(name: "channels", value: String(channels)) }
        if let diarize = options.diarize { appendField(name: "diarize", value: diarize ? "true" : "false") }
        if let fillerWords = options.fillerWords { appendField(name: "filler_words", value: fillerWords ? "true" : "false") }
        for term in options.keyTerms { appendField(name: "keyterm", value: term) }

        if let audioURL {
            appendField(name: "url", value: audioURL.absoluteString)
        }

        if let audio, let filename, let contentType {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)")
            appendString("Content-Type: \(contentType)\(crlf)\(crlf)")
            body.append(audio)
            appendString(crlf)
        }

        appendString("--\(boundary)--\(crlf)")
        return body
    }

    /// Minimal RIFF/WAVE header for 16-bit little-endian PCM. Mono by default.
    public static func wrapAsWAV(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var header = Data()
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = UInt16(channels) * bytesPerSample
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(pcm16.count)
        let chunkSize = 36 + dataSize

        func append<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }

        header.append("RIFF".data(using: .ascii)!)
        append(chunkSize)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))               // subchunk1Size for PCM
        append(UInt16(1))                // audioFormat = 1 (PCM)
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        header.append("data".data(using: .ascii)!)
        append(dataSize)
        header.append(pcm16)
        return header
    }
}
