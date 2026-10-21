import Foundation
import CryptoKit

actor LibraryBackup {
    private struct Entry: Codable { let path: String; let bytes: Int; let sha256: String }
    private struct Manifest: Codable { let format: Int; let entries: [Entry] }
    private let fm = FileManager.default

    func create(repository: MediaRepository, root: URL) async throws -> URL {
        let folder = fm.temporaryDirectory.appendingPathComponent("MediaMind-backup-\(UUID())",isDirectory:true)
        try fm.createDirectory(at:folder.appendingPathComponent("files"),withIntermediateDirectories:true)
        do {
            let snapshot = folder.appendingPathComponent("library.sqlite")
            try await repository.snapshot(to:snapshot)
            let copy = try MediaRepository(url:snapshot)
            try await copy.checkIntegrity()
            let media = try await copy.all() + copy.trashed()
            var entries = [Entry(path:"library.sqlite",bytes:try size(snapshot,maximum:512*1024*1024),sha256:try digest(snapshot))]
            for item in media {
                try validateName(item.fileName)
                let source = root.appendingPathComponent("files").appendingPathComponent(item.fileName)
                let relative = "files/" + item.fileName
                let bytes = try size(source,maximum:2*1024*1024*1024)
                let hash = try copyFile(source,to:folder.appendingPathComponent(relative),bytes:bytes)
                entries.append(Entry(path:relative,bytes:bytes,sha256:hash))
            }
            let data = try JSONEncoder().encode(Manifest(format:1,entries:entries))
            try data.write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
            return folder
        } catch { try? fm.removeItem(at:folder); throw error }
    }

    func restore(from folder: URL, repository: MediaRepository, root: URL) async throws {
        guard try await repository.all().isEmpty, try await repository.trashed().isEmpty else { throw LibraryBackupError.notEmpty }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let stage = fm.temporaryDirectory.appendingPathComponent("MediaMind-restore-\(UUID())",isDirectory:true)
        try fm.createDirectory(at:stage.appendingPathComponent("files"),withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:stage) }
        _ = try size(folder.appendingPathComponent("manifest.json"),maximum:4*1024*1024)
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
        guard manifest.format == 1, manifest.entries.count <= 20_001,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              manifest.entries.filter({ $0.path == "library.sqlite" }).count == 1 else { throw LibraryBackupError.invalid }
        try regularDirectory(folder)
        try regularDirectory(folder.appendingPathComponent("files"))
        for entry in manifest.entries {
            if entry.path != "library.sqlite" {
                guard entry.path.hasPrefix("files/") else { throw LibraryBackupError.invalid }
                try validateName(String(entry.path.dropFirst(6)))
            }
            let source = folder.appendingPathComponent(entry.path)
            let maximum = entry.path == "library.sqlite" ? 512*1024*1024 : 2*1024*1024*1024
            guard try size(source,maximum:maximum) == entry.bytes else { throw LibraryBackupError.invalid }
            let hash = try copyFile(source,to:stage.appendingPathComponent(entry.path),bytes:entry.bytes)
            guard hash == entry.sha256 else { throw LibraryBackupError.invalid }
        }
        let snapshot = stage.appendingPathComponent("library.sqlite")
        let copy = try MediaRepository(url:snapshot)
        try await copy.checkIntegrity()
        let media = try await copy.all() + copy.trashed()
        let expected = Set(media.map { "files/" + $0.fileName }).union(["library.sqlite"])
        guard expected == Set(manifest.entries.map(\.path)), media.count + 1 == manifest.entries.count else { throw LibraryBackupError.invalid }
        for item in media { try validateName(item.fileName) }
        let files = root.appendingPathComponent("files",isDirectory:true)
        try fm.createDirectory(at:files,withIntermediateDirectories:true)
        var installed: [URL] = []
        do {
            for item in media {
                try Task.checkCancellation()
                let target = files.appendingPathComponent(item.fileName)
                try fm.moveItem(at:stage.appendingPathComponent("files/" + item.fileName),to:target)
                installed.append(target)
            }
            // Snapshot the staged connection again so migrated WAL pages are included.
            let ready = stage.appendingPathComponent("ready.sqlite")
            try await copy.snapshot(to:ready)
            try Task.checkCancellation()
            try await repository.restoreSnapshot(from:ready)
        } catch {
            for url in installed { try? fm.removeItem(at:url) }
            throw error
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw LibraryBackupError.invalid }
    }
    private func regularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryBackupError.invalid }
    }
    private func size(_ url: URL, maximum: Int) throws -> Int {
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes >= 0, bytes <= maximum else { throw LibraryBackupError.invalid }
        return bytes
    }
    private func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom:url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount:1024*1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data:data)
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private func copyFile(_ source: URL, to destination: URL, bytes: Int) throws -> String {
        let available = try destination.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < Int64(bytes) + 50*1024*1024 { throw MediaFileImport.ImportError.noSpace }
        guard fm.createFile(atPath:destination.path,contents:nil) else { throw LibraryBackupError.invalid }
        let input = try FileHandle(forReadingFrom:source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo:destination)
        defer { try? output.close() }
        var hash = SHA256(), copied = 0
        while let data = try input.read(upToCount:1024*1024), !data.isEmpty {
            try Task.checkCancellation()
            copied += data.count
            guard copied <= bytes else { throw LibraryBackupError.invalid }
            try output.write(contentsOf:data)
            hash.update(data:data)
        }
        guard copied == bytes else { throw LibraryBackupError.invalid }
        try output.synchronize()
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
