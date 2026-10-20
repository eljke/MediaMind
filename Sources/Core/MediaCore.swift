import Foundation

public struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var fileName: String
    public var addedAt: Date
    public var duration: Double
    public init(id: UUID = UUID(), title: String, fileName: String, addedAt: Date = .now, duration: Double = 0) {
        self.id = id; self.title = title; self.fileName = fileName; self.addedAt = addedAt; self.duration = duration
    }
}
public struct SpeechSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }
}
public struct TranscriptionCheckpoint: Codable, Equatable, Sendable {
    public var language: String
    public var nextOffset: Double
    public var segments: [SpeechSegment]
    public init(language: String, nextOffset: Double = 0, segments: [SpeechSegment] = []) {
        self.language = language; self.nextOffset = nextOffset; self.segments = segments
    }
}
public enum Subtitles {
    public static func decode(_ input: String) -> [SpeechSegment] {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        let blocks = normalized.components(separatedBy: .newlines).reduce(into: [String]()) { blocks, line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if blocks.last != "" { blocks.append("") }
            } else if blocks.isEmpty { blocks.append(line) }
            else { blocks[blocks.count - 1] += "\n" + line }
        }
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let first = lines.first(where: { !$0.isEmpty }) ?? ""
            guard first != "STYLE", first != "REGION", first != "NOTE", !first.hasPrefix("NOTE ") else { return nil }
            guard let timeLine = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timeLine].components(separatedBy: "-->")
            guard times.count == 2, let start = parseTime(times[0]), let end = parseTime(times[1]), end >= start else { return nil }
            let body = lines.dropFirst(timeLine+1).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { return nil }
            return SpeechSegment(start: start, end: end, text: body)
        }.sorted { $0.start < $1.start }
    }
    public static func encodeSRT(_ segments: [SpeechSegment]) -> String {
        segments.enumerated().map { i,s in "\(i + 1)\n\(timestamp(s.start, decimal: ",")) --> \(timestamp(s.end, decimal: ","))\n\(s.text)" }.joined(separator: "\n\n") + "\n"
    }
    public static func encodeVTT(_ segments: [SpeechSegment]) -> String {
        "WEBVTT\n\n" + segments.map { "\(timestamp($0.start, decimal: ".")) --> \(timestamp($0.end, decimal: "."))\n\($0.text)" }.joined(separator: "\n\n") + "\n"
    }
    private static func parseTime(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).first ?? ""
        let parts = cleaned.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let last = parts.last, let seconds = Double(last), seconds.isFinite,
              let mins = Int(parts[parts.count - 2]), (0..<60).contains(mins),
              let hours = parts.count == 3 ? Int(parts[0]) : 0, hours >= 0,
              seconds >= 0 && seconds < 60 else { return nil }
        let time = Double(hours) * 3600 + Double(mins) * 60 + seconds
        return time <= 359_999_999 ? time : nil
    }
    private static func timestamp(_ time: Double, decimal: String) -> String {
        let safeTime = time.isFinite ? min(359_999_999, max(0, time)) : 0
        let ms = Int((safeTime * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, decimal, ms % 1000)
    }
}
public enum Transcript {
    public static func phrases(_ words: [SpeechSegment]) -> [SpeechSegment] {
        var result: [SpeechSegment] = []
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let previous = result.last,
               word.start - previous.end < 1,
               word.end - previous.start <= 12,
               ![".", "!", "?", "…"].contains(where: { previous.text.hasSuffix($0) }) {
                result[result.count - 1].end = max(previous.end, word.end)
                result[result.count - 1].text += " " + word.text
            } else {
                result.append(word)
            }
        }
        return result
    }
}
public struct MediaHit: Identifiable, Sendable {
    public let item: MediaItem
    public let segment: SpeechSegment
    public var id: UUID { segment.id }
}
public enum MediaSearch {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }
    public static func results(items: [MediaItem], transcripts: [UUID: [SpeechSegment]], query: String) -> [MediaHit] {
        let text = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return [] }
        return items.flatMap { item in
            (transcripts[item.id] ?? []).filter { normalized($0.text).contains(text) }.map { MediaHit(item: item, segment: $0) }
        }.sorted { $0.item.addedAt > $1.item.addedAt }
    }
}
