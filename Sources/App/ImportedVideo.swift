import CoreTransferable
import UniformTypeIdentifiers
import Foundation

final class ImportedVideo: Transferable, Sendable {
    let file: URL
    let title: String

    init(file: URL, title: String) { self.file = file; self.title = title }
    deinit { try? FileManager.default.removeItem(at: file) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try await copy(from: received.file)
        }
    }

    static func copy(from source: URL) async throws -> ImportedVideo {
        // The provider's URL is only valid while the transfer closure is running.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImports", isDirectory: true)
        let file = try await MediaFileImport().copyMedia(from: source, to: folder) { _ in }
        return ImportedVideo(file: file, title: source.deletingPathExtension().lastPathComponent)
    }
}
