import Foundation

public enum SearchScope: String, CaseIterable, Sendable {
    case all = "Везде", titles = "Названия", transcripts = "Расшифровки", bookmarks = "Заметки"
}

public enum MediaKind: String, CaseIterable, Sendable {
    case all = "Все файлы", audio = "Аудио", video = "Видео"
}

public struct LibrarySearchHit: Identifiable, Sendable {
    public enum Match: Sendable { case title, transcript(SpeechSegment), bookmark(MediaBookmark) }
    public let item: MediaItem
    public let match: Match
    public var id: String {
        switch match {
        case .title: return "title-\(item.id)"
        case .transcript(let segment): return "text-\(segment.id)"
        case .bookmark(let bookmark): return "note-\(bookmark.id)"
        }
    }
    public var text: String {
        switch match {
        case .title: return item.title
        case .transcript(let segment): return segment.text
        case .bookmark(let bookmark): return bookmark.note
        }
    }
    public var position: Double? {
        switch match {
        case .title: return nil
        case .transcript(let segment): return segment.start
        case .bookmark(let bookmark): return bookmark.position
        }
    }
}

extension MediaSearch {
    public static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of:query,options:[.caseInsensitive,.diacriticInsensitive],range:start..<text.endIndex,locale:Locale(identifier:"ru_RU")) {
            guard !range.isEmpty else { break }
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
