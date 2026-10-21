import Foundation

public enum TranscriptEditing {
    public static let textLimit = 20_000
    public enum Error: LocalizedError {
        case invalidText, missingSegment, noNextSegment, busy, pendingRecognition
        public var errorDescription: String? {
            switch self {
            case .invalidText: return "Текст должен содержать от 1 до 20000 символов."
            case .missingSegment: return "Фрагмент уже изменён. Открой расшифровку заново."
            case .noNextSegment: return "Следующего фрагмента нет."
            case .busy: return "Дождись завершения текущего действия."
            case .pendingRecognition: return "Есть незавершённое распознавание. Сохранение текста сбросит его прогресс."
            }
        }
    }

    public static func replaceText(in parts: [SpeechSegment], id: UUID, text: String) throws -> [SpeechSegment] {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= textLimit else { throw Error.invalidText }
        guard let index = parts.firstIndex(where: { $0.id == id }) else { throw Error.missingSegment }
        var updated = parts
        updated[index].text = text
        return updated
    }

    public static func mergeNext(in parts: [SpeechSegment], id: UUID) throws -> [SpeechSegment] {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { throw Error.missingSegment }
        guard index + 1 < parts.count else { throw Error.noNextSegment }
        let text = parts[index].text.trimmingCharacters(in:.whitespacesAndNewlines) + " " + parts[index+1].text.trimmingCharacters(in:.whitespacesAndNewlines)
        var updated = try replaceText(in:parts,id:id,text:text)
        updated[index].end = max(parts[index].end,parts[index+1].end)
        updated.remove(at:index+1)
        return updated
    }
}

public enum MediaTime {
    public static func label(_ seconds: Double) -> String {
        let n = Int(seconds.isFinite ? min(359_999_999,max(0,seconds)) : 0)
        return n >= 3600 ? String(format:"%d:%02d:%02d",n/3600,n/60%60,n%60) : String(format:"%d:%02d",n/60,n%60)
    }
}

public enum BookmarkExport {
    public static func text(title: String, bookmarks: [MediaBookmark]) -> String {
        ([title] + bookmarks.sorted { $0.position < $1.position }.map {
            "[\(MediaTime.label($0.position))] \($0.note.isEmpty ? "Без заметки" : $0.note)"
        }).joined(separator:"\n\n") + "\n"
    }
}
