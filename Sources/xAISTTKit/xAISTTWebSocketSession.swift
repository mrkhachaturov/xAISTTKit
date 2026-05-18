//
//  xAISTTWebSocketSession.swift
//  Streaming xAI Speech-to-Text over WebSocket.
//
//  wss://api.x.ai/v1/stt?sample_rate=16000&encoding=pcm&interim_results=true&language=en
//
//  Client -> Server: binary frames (raw audio in `encoding`), then a final
//                    JSON text frame `{"type": "audio.done"}`.
//  Server -> Client: JSON text frames:
//                    { "type": "transcript.created" }                     — ready
//                    { "type": "transcript.partial", "text": "...", ... } — interim / chunk-final
//                    { "type": "transcript.done", "text": "...", ... }    — utterance-final
//                    { "type": "error", "message": "..." }
//

import Foundation

public actor xAISTTWebSocketSession {

    public struct Configuration: Sendable {
        public var baseURL: URL                       // wss://api.x.ai/v1/stt
        public var bearer: String
        public var encoding: xAISTTAudioFormat        // .pcm (default), .mulaw, .alaw
        public var sampleRate: Int                    // 8000, 16000 (default), 22050, 24000, 44100, 48000
        public var language: xAISTTLanguage?
        public var interimResults: Bool?              // default false
        /// Silence duration (ms) before utterance-final event. Range: 0–5000.
        public var endpointingMs: Int?
        public var diarize: Bool?
        public var fillerWords: Bool?
        public var multichannel: Bool?
        public var channels: Int?                     // default 1
        public var keyTerms: [String]
        public var timeoutSeconds: TimeInterval

        public init(
            baseURL: URL = URL(string: "wss://api.x.ai/v1/stt")!,
            bearer: String,
            encoding: xAISTTAudioFormat = .pcm,
            sampleRate: Int = 16_000,
            language: xAISTTLanguage? = nil,
            interimResults: Bool? = nil,
            endpointingMs: Int? = nil,
            diarize: Bool? = nil,
            fillerWords: Bool? = nil,
            multichannel: Bool? = nil,
            channels: Int? = nil,
            keyTerms: [String] = [],
            timeoutSeconds: TimeInterval = 120
        ) {
            self.baseURL = baseURL
            self.bearer = bearer
            self.encoding = encoding
            self.sampleRate = sampleRate
            self.language = language
            self.interimResults = interimResults
            self.endpointingMs = endpointingMs
            self.diarize = diarize
            self.fillerWords = fillerWords
            self.multichannel = multichannel
            self.channels = channels
            self.keyTerms = keyTerms
            self.timeoutSeconds = timeoutSeconds
        }

        /// Build the connection URL with query parameters per the xAI spec.
        /// Exposed for testing.
        public func makeURL() -> URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "sample_rate", value: String(sampleRate)),
                URLQueryItem(name: "encoding", value: encoding.rawValue)
            ]
            if let language { items.append(URLQueryItem(name: "language", value: language.rawValue)) }
            if let interimResults { items.append(URLQueryItem(name: "interim_results", value: interimResults ? "true" : "false")) }
            if let endpointingMs { items.append(URLQueryItem(name: "endpointing", value: String(endpointingMs))) }
            if let diarize { items.append(URLQueryItem(name: "diarize", value: diarize ? "true" : "false")) }
            if let fillerWords { items.append(URLQueryItem(name: "filler_words", value: fillerWords ? "true" : "false")) }
            if let multichannel { items.append(URLQueryItem(name: "multichannel", value: multichannel ? "true" : "false")) }
            if let channels { items.append(URLQueryItem(name: "channels", value: String(channels))) }
            for term in keyTerms { items.append(URLQueryItem(name: "keyterm", value: term)) }
            components.queryItems = items
            return components.url!
        }
    }

    /// Decoded `transcript.partial` or `transcript.done` payload.
    public struct Transcript: Sendable, Equatable {
        public let text: String
        public let isFinal: Bool
        public let speechFinal: Bool
        public let start: Double?
        public let duration: Double?
        public let channelIndex: Int?
        public let words: [xAISTTResponse.Word]?

        public init(
            text: String,
            isFinal: Bool,
            speechFinal: Bool,
            start: Double?,
            duration: Double?,
            channelIndex: Int?,
            words: [xAISTTResponse.Word]?
        ) {
            self.text = text
            self.isFinal = isFinal
            self.speechFinal = speechFinal
            self.start = start
            self.duration = duration
            self.channelIndex = channelIndex
            self.words = words
        }
    }

    public enum Event: Sendable, Equatable {
        /// `transcript.created` — server is ready to receive audio.
        case ready
        /// `transcript.partial` — interim, chunk-final, or utterance-final.
        case partial(Transcript)
        /// `transcript.done` — utterance closed (one per channel when multichannel).
        case done(Transcript)
        /// `error` — server-side problem. Connection may still be open.
        case error(message: String)
    }

    // MARK: - Public stream

    public nonisolated let events: AsyncThrowingStream<Event, Error>

    // MARK: - Internals

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false

    private init(task: URLSessionWebSocketTask) {
        self.task = task
        var local: AsyncThrowingStream<Event, Error>.Continuation!
        self.events = AsyncThrowingStream<Event, Error> { local = $0 }
        self.continuation = local
    }

    deinit {
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Opening

    /// Open a new STT WebSocket session.
    ///
    /// Auth is passed via `Sec-WebSocket-Protocol` (`xai-client-secret.<bearer>`)
    /// because `URLSessionWebSocketTask` strips the `Authorization` header during
    /// the HTTP→WebSocket upgrade on Apple platforms.
    public static func open(
        configuration: Configuration,
        session: URLSession? = nil
    ) async throws -> xAISTTWebSocketSession {
        let urlSession: URLSession = session ?? {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = configuration.timeoutSeconds
            cfg.timeoutIntervalForResource = configuration.timeoutSeconds
            return URLSession(configuration: cfg)
        }()

        let task = urlSession.webSocketTask(
            with: configuration.makeURL(),
            protocols: [Self.authProtocol(bearer: configuration.bearer)]
        )
        task.resume()

        let s = xAISTTWebSocketSession(task: task)
        await s.startReceiveLoop()
        return s
    }

    public static func authProtocol(bearer: String) -> String {
        "xai-client-secret.\(bearer)"
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                let message = try await task.receive()
                handle(message: message)
            } catch is CancellationError {
                continuation.finish(throwing: xAISTTError.canceled)
                return
            } catch {
                if !isClosed {
                    continuation.finish(throwing: error)
                }
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):
            guard let s = String(data: d, encoding: .utf8) else {
                continuation.yield(.error(message: "non-utf8 binary frame from server"))
                return
            }
            text = s
        @unknown default:
            continuation.yield(.error(message: "unknown WebSocket message kind"))
            return
        }
        guard let event = Self.decodeServerEvent(text: text) else {
            continuation.yield(.error(message: "unparseable server frame: \(text)"))
            return
        }
        continuation.yield(event)
    }

    /// Parse a server -> client frame. Exposed for testing.
    public static func decodeServerEvent(text: String) -> Event? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return nil }

        switch type {
        case "transcript.created":
            return .ready
        case "transcript.partial":
            return .partial(decodeTranscript(json: json, fallbackIsFinal: false))
        case "transcript.done":
            return .done(decodeTranscript(json: json, fallbackIsFinal: true))
        case "error":
            return .error(message: (json["message"] as? String) ?? "<unknown error>")
        default:
            return nil
        }
    }

    private static func decodeTranscript(json: [String: Any], fallbackIsFinal: Bool) -> Transcript {
        let words: [xAISTTResponse.Word]?
        if let rawWords = json["words"] as? [[String: Any]],
           let wordData = try? JSONSerialization.data(withJSONObject: rawWords),
           let parsed = try? JSONDecoder().decode([xAISTTResponse.Word].self, from: wordData) {
            words = parsed
        } else {
            words = nil
        }
        return Transcript(
            text: (json["text"] as? String) ?? "",
            isFinal: (json["is_final"] as? Bool) ?? fallbackIsFinal,
            speechFinal: (json["speech_final"] as? Bool) ?? fallbackIsFinal,
            start: json["start"] as? Double,
            duration: json["duration"] as? Double,
            channelIndex: json["channel_index"] as? Int,
            words: words
        )
    }

    // MARK: - Outgoing

    /// Send a chunk of raw audio in the negotiated encoding. Best practice is
    /// 100 ms of audio per frame (e.g. 3200 bytes for 16 kHz PCM16 mono).
    public func send(audio: Data) async throws {
        try await task.send(.data(audio))
    }

    /// Signal end of audio. The server will emit `transcript.done` and close.
    public func endAudio() async throws {
        try await task.send(.string(Self.audioDoneFrame))
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }

    // MARK: - Frame encoders (exposed for testing)

    public static let audioDoneFrame: String = {
        let payload: [String: Any] = ["type": "audio.done"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"type\":\"audio.done\"}" }
        return s
    }()
}

// MARK: - Single-utterance convenience

extension xAISTTWebSocketSession {
    /// Open a session, stream a buffer of audio chunks, mark end-of-audio, and
    /// return the final transcript text from `transcript.done`. Designed for
    /// "I have these PCM samples — give me the transcript" use cases.
    public static func transcribe(
        pcm16Chunks: AsyncStream<Data>,
        configuration: Configuration
    ) async throws -> String {
        let session = try await xAISTTWebSocketSession.open(configuration: configuration)
        // Pump audio in a child Task so we can concurrently read events.
        let pumpTask = Task {
            for await chunk in pcm16Chunks {
                try await session.send(audio: chunk)
            }
            try await session.endAudio()
        }
        defer { pumpTask.cancel() }

        for try await event in session.events {
            switch event {
            case .ready, .partial:
                continue
            case .done(let transcript):
                await session.close()
                return transcript.text
            case .error(let message):
                await session.close()
                throw xAISTTError.http(status: 0, body: message)
            }
        }
        await session.close()
        throw xAISTTError.decoding("WebSocket closed before transcript.done")
    }
}
