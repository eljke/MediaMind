import Foundation

public struct MediaBookmark: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var position: Double
    public var note: String
    public var createdAt: Date
    public static let noteLimit = 2000

    public init(id: UUID = UUID(), mediaID: UUID, position: Double, note: String = "", createdAt: Date = .now) {
        self.id = id; self.mediaID = mediaID; self.position = position; self.note = note; self.createdAt = createdAt
    }
}

public struct PlaybackPosition: Equatable, Sendable {
    public var position: Double
    public var playedAt: Date
    public init(position: Double, playedAt: Date = .now) {
        self.position = position; self.playedAt = playedAt
    }

    public func canResume(duration: Double) -> Bool {
        position.isFinite && duration.isFinite && position > 0 && duration - position > 1
    }
}

public enum TranscriptStatus: Equatable, Sendable {
    case empty, ready(Int), paused, failed(String)
}

public struct MediaOverview: Equatable, Sendable {
    public var transcript: TranscriptStatus
    public var playback: PlaybackPosition?
    public init(transcript: TranscriptStatus = .empty, playback: PlaybackPosition? = nil) {
        self.transcript = transcript; self.playback = playback
    }
}
