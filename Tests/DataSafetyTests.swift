import XCTest
@testable import MediaMindCore

final class DataSafetyTests: XCTestCase {
    func testSummaryDraftAndPersistence() async throws {
        let root = folder()
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Лекция",fileName:"a.mov",duration:100)
        try await repo.save(item)
        let parts = (0..<30).map { SpeechSegment(start:Double($0),end:Double($0+1),text:"Фрагмент \($0)") }
        try await repo.replaceSegments(parts,for:item.id)
        var draft = MediaSummary.draft(from:parts)
        XCTAssertEqual(draft.text.split(separator:"\n").count,12)
        XCTAssertTrue(draft.text.contains("[0:00] Фрагмент 0"))
        XCTAssertEqual(MediaSummary.draft(from:[]).text,"")
        draft.text = "Мой конспект\n- [0:20] Вывод"
        try await repo.saveSummary(draft,for:item.id)
        let reopened = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let saved = try await reopened.summary(for:item.id)
        XCTAssertEqual(saved,draft)
        let edited = try TranscriptEditing.replaceText(in:parts,id:parts[0].id,text:"Исправление")
        try await repo.replaceSegments(edited,for:item.id)
        let retained = try await repo.summary(for:item.id)
        XCTAssertEqual(retained,draft)
        XCTAssertNotEqual(retained?.source,edited)
        try await repo.trash(item.id)
        let inTrash = try await repo.summary(for:item.id)
        XCTAssertEqual(inTrash,draft)
        try await repo.remove(item.id)
        let removed = try await repo.summary(for:item.id)
        XCTAssertNil(removed)
    }

    func testSnapshotRestoresCommittedWAL() async throws {
        let root = folder()
        let repo = try MediaRepository(url:root.appendingPathComponent("source.sqlite"))
        let item = MediaItem(title:"В корзине",fileName:"a.MOV",duration:100)
        try await repo.save(item)
        let parts = [SpeechSegment(start:1,end:5,text:"Текст")]
        try await repo.replaceSegments(parts,for:item.id)
        try await repo.saveSummary(MediaSummary(text:"Конспект",source:parts),for:item.id)
        try await repo.saveCheckpoint(TranscriptionCheckpoint(language:"ru-RU",nextOffset:45),for:item.id)
        try await repo.trash(item.id)
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try await repo.snapshot(to:snapshot)
        let restored = try MediaRepository(url:root.appendingPathComponent("restored.sqlite"))
        try await restored.restoreSnapshot(from:snapshot)
        try await restored.checkIntegrity()
        let trash = try await restored.trashed()
        let checkpoint = try await restored.checkpoint(for:item.id)
        let summary = try await restored.summary(for:item.id)
        XCTAssertEqual(trash.map(\.id),[item.id])
        XCTAssertEqual(checkpoint?.nextOffset,45)
        XCTAssertEqual(summary?.text,"Конспект")
        do { try await restored.restoreSnapshot(from:snapshot); XCTFail("Nonempty library must be preserved") }
        catch LibraryBackupError.notEmpty {}
    }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
}
