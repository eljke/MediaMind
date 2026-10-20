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
public enum Subtitles {
    public static func decode(_ input: String) -> [SpeechSegment] {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let timeLine = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timeLine].components(separatedBy: "-->")
            guard times.count == 2, let start = parseTime(times[0]), let end = parseTime(times[1]), end >= start else { return nil }
            let body = lines.dropFirst(timeLine+1).filter { !$0.isEmpty && !$0.hasPrefix("NOTE") }.joined(separator: "\n")
            guard !body.isEmpty else { return nil }
            return SpeechSegment(start: start, end: end, text: body)
        }
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
        guard parts.count == 2 || parts.count == 3, let seconds = Double(parts.last!) else { return nil }
        let mins = Double(parts[parts.count - 2]) ?? -1
        let hours = parts.count == 3 ? (Double(parts[0]) ?? -1) : 0
        guard hours >= 0, mins >= 0, seconds >= 0 && seconds < 60, mins < 60 else { return nil }
        return hours * 3600 + mins * 60 + seconds
    }
    private static func timestamp(_ time: Double, decimal: String) -> String {
        let ms = Int((max(0,time) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, decimal, ms % 1000)
    }
}
public struct MediaHit: Identifiable, Sendable {
    public let item: MediaItem
    public let segment: SpeechSegment
    public var id: UUID { segment.id }
}
public enum MediaSearch {
    public static func results(items: [MediaItem], transcripts: [UUID: [SpeechSegment]], query: String) -> [MediaHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return items.flatMap { item in
            (transcripts[item.id] ?? []).filter { $0.text.localizedStandardContains(text) }.map { MediaHit(item: item, segment: $0) }
        }.sorted { $0.item.addedAt > $1.item.addedAt }
    }
}
