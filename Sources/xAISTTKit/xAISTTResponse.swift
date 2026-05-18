//
//  xAISTTResponse.swift
//  Decoded JSON returned by `POST https://api.x.ai/v1/stt`.
//

import Foundation

public struct xAISTTResponse: Decodable, Sendable {
    public let text: String
    public let language: String?
    public let duration: Double?
    public let words: [Word]?
    public let channels: [Channel]?

    public struct Word: Decodable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        /// Only present when `diarize: true` is sent.
        public let speaker: Int?
    }

    public struct Channel: Decodable, Sendable {
        public let index: Int
        public let text: String
        public let words: [Word]?
    }
}
