import Foundation

actor MediaFileImport {
    enum ImportError: LocalizedError {
        case unsupported, tooLarge, noSpace, unreadable, noCues
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Выбери аудио или видео: MP3, M4A, MP4, MOV, WAV, AAC, CAF, AIFF, M4V."
            case .tooLarge: return "Максимальный размер медиа — 2 ГБ, субтитров — 10 МБ."
            case .noSpace: return "Недостаточно свободного места для копии файла."
            case .unreadable: return "Не удалось прочитать файл. Для субтитров используй UTF-8 или UTF-16."
            case .noCues: return "В файле нет читаемых временных отметок SRT/VTT."
            }
        }
    }

    func copyMedia(from source: URL, to folder: URL, progress: @Sendable (Double) -> Void) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard ["m4a", "mp3", "mp4", "mov", "wav", "aac", "caf", "aiff", "m4v"].contains(ext) else { throw ImportError.unsupported }
        let size = try fileSize(source, maximum: 2 * 1024 * 1024 * 1024)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < Int64(size) + 50 * 1024 * 1024 { throw ImportError.noSpace }
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard let input = InputStream(url: source), let output = OutputStream(url: destination, append: false) else { throw ImportError.unreadable }
        input.open(); output.open()
        defer { input.close(); output.close() }
        do {
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            var copied = 0
            while true {
                try Task.checkCancellation()
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw input.streamError ?? ImportError.unreadable }
                if count == 0 { break }
                guard copied + count <= 2 * 1024 * 1024 * 1024 else { throw ImportError.tooLarge }
                try buffer.withUnsafeBufferPointer { bytes in
                    var written = 0
                    while written < count {
                        let amount = output.write(bytes.baseAddress!.advanced(by: written), maxLength: count - written)
                        guard amount > 0 else { throw output.streamError ?? ImportError.noSpace }
                        written += amount
                    }
                }
                copied += count
                progress(min(1, Double(copied) / Double(max(1, size))))
            }
            try Task.checkCancellation()
            return destination
        } catch {
            output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func subtitles(from url: URL) throws -> [SpeechSegment] {
        _ = try fileSize(url, maximum: 10 * 1024 * 1024)
        try Task.checkCancellation()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ImportError.unreadable }
        let parts = Subtitles.decode(text)
        try Task.checkCancellation()
        guard !parts.isEmpty else { throw ImportError.noCues }
        return parts
    }

    private func fileSize(_ url: URL, maximum: Int) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw ImportError.unreadable }
        guard size <= maximum else { throw ImportError.tooLarge }
        return size
    }
}
