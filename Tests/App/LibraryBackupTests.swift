#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest
@testable import MediaMind

@MainActor
final class LibraryBackupTests: XCTestCase {
    func testFullBackupRoundTrip() async throws {
        let (root,repo,item) = try await fixture()
        let parts = [SpeechSegment(start:1,end:2,text:"Текст")]
        try await repo.replaceSegments(parts,for:item.id)
        try await repo.saveSummary(MediaSummary(text:"Конспект",source:parts),for:item.id)
        try await repo.saveBookmark(MediaBookmark(mediaID:item.id,position:1,note:"Заметка"))
        try await repo.savePlayback(PlaybackPosition(position:3),for:item.id)
        try await repo.saveCheckpoint(TranscriptionCheckpoint(language:"ru-RU",nextOffset:45),for:item.id)
        try await repo.trash(item.id)
        let service = LibraryBackup()
        let backup = try await service.create(repository:repo,root:root)
        defer { try? FileManager.default.removeItem(at:backup) }
        let target = folder()
        let restored = try MediaRepository(url:target.appendingPathComponent("library.sqlite"))
        try await service.restore(from:backup,repository:restored,root:target)
        let trash = try await restored.trashed()
        let summary = try await restored.summary(for:item.id)
        let notes = try await restored.bookmarks(for:item.id)
        let overview = try await restored.overview()
        let checkpoint = try await restored.checkpoint(for:item.id)
        XCTAssertEqual(trash.map(\.id),[item.id])
        XCTAssertEqual(summary?.text,"Конспект")
        XCTAssertEqual(notes.first?.note,"Заметка")
        XCTAssertEqual(overview[item.id]?.playback?.position,3)
        XCTAssertEqual(checkpoint?.nextOffset,45)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("files/a.MOV")),Data("video bytes".utf8))
        do { try await service.restore(from:backup,repository:restored,root:target); XCTFail("Existing data must survive") }
        catch LibraryBackupError.notEmpty {}
    }

    func testCorruptionDoesNotRestorePartialData() async throws {
        let (root,repo,_) = try await fixture()
        let service = LibraryBackup()
        let backup = try await service.create(repository:repo,root:root)
        defer { try? FileManager.default.removeItem(at:backup) }
        try Data("changed!!!!".utf8).write(to:backup.appendingPathComponent("files/a.MOV"))
        let target = folder()
        let restored = try MediaRepository(url:target.appendingPathComponent("library.sqlite"))
        do { try await service.restore(from:backup,repository:restored,root:target); XCTFail("Corruption must fail") }
        catch LibraryBackupError.invalid {}
        let items = try await restored.all()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("files/a.MOV").path))
    }

    func testUnsafePathsAndMissingMediaFail() async throws {
        let (root,repo,item) = try await fixture()
        let service = LibraryBackup()
        let backup = try await service.create(repository:repo,root:root)
        defer { try? FileManager.default.removeItem(at:backup) }
        let manifest = backup.appendingPathComponent("manifest.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var entries = try XCTUnwrap(value["entries"] as? [[String:Any]])
        entries[1]["path"] = "files/../../outside.mov"
        value["entries"] = entries
        try JSONSerialization.data(withJSONObject:value).write(to:manifest)
        let target = folder()
        let restored = try MediaRepository(url:target.appendingPathComponent("library.sqlite"))
        do { try await service.restore(from:backup,repository:restored,root:target); XCTFail("Unsafe paths must fail") }
        catch LibraryBackupError.invalid {}
        try FileManager.default.removeItem(at:root.appendingPathComponent("files/" + item.fileName))
        do { _ = try await service.create(repository:repo,root:root); XCTFail("Incomplete backup must fail") }
        catch {}
    }

    private func fixture() async throws -> (URL,MediaRepository,MediaItem) {
        let root = folder()
        try FileManager.default.createDirectory(at:root.appendingPathComponent("files"),withIntermediateDirectories:true)
        try Data("video bytes".utf8).write(to:root.appendingPathComponent("files/a.MOV"))
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Запись",fileName:"a.MOV",duration:90)
        try await repo.save(item)
        return (root,repo,item)
    }
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
}
#endif
