import Foundation

public struct MediaSummary: Equatable, Sendable {
    public static let textLimit = 50_000
    public var text: String
    public var source: [SpeechSegment]
    public init(text: String, source: [SpeechSegment]) { self.text = text; self.source = source }

    public static func draft(from segments: [SpeechSegment]) -> MediaSummary {
        let nonempty = segments.filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        let count = min(12,nonempty.count)
        let selected = (0..<count).map { nonempty[$0 * nonempty.count / count] }
        let text = selected.map { "- [\(MediaTime.label($0.start))] \(String($0.text.prefix(2000)))" }.joined(separator:"\n")
        return MediaSummary(text:text,source:segments)
    }
}

public enum LibraryBackupError: LocalizedError {
    case invalid, notEmpty, noBookmarks
    public var errorDescription: String? {
        switch self {
        case .invalid: return "Копия неполная, повреждена или создана неподдерживаемой версией. Библиотека не изменена."
        case .notEmpty: return "Восстановление доступно только в пустую библиотеку, включая корзину. Текущие данные не перезаписаны."
        case .noBookmarks: return "У этой записи пока нет закладок для экспорта."
        }
    }
}
