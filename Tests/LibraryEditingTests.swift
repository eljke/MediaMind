import XCTest
@testable import MediaMindCore

final class LibraryEditingTests: XCTestCase {
    func testSearchSourcesAndFilters() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let video = MediaItem(title:"Ёжик — лекция",fileName:"a.MOV",duration:100)
        let audio = MediaItem(title:"Интервью",fileName:"b.wav",duration:100)
        try await repo.save(video); try await repo.save(audio)
        try await repo.replaceSegments([SpeechSegment(start:12,end:14,text:"Ёжик говорит")],for:video.id)
        try await repo.saveBookmark(MediaBookmark(mediaID:audio.id,position:25,note:"Ёжик 100%_\\"))
        let all = try await repo.find("ежик")
        XCTAssertEqual(all.count,3)
        let titles = try await repo.find("ежик",scope:.titles)
        XCTAssertEqual(titles.count,1)
        XCTAssertNil(titles.first?.position)
        let notes = try await repo.find("ежик",scope:.bookmarks,kind:.audio)
        XCTAssertEqual(notes.first?.position,25)
        let movies = try await repo.find("ежик",kind:.video)
        XCTAssertEqual(movies.count,2)
        let literal = try await repo.find("100%_\\")
        XCTAssertEqual(literal.count,1)
        try await repo.trash(video.id)
        let hidden = try await repo.find("ежик")
        XCTAssertEqual(hidden.count,1)
        try await repo.restore(video.id)
        let restored = try await repo.find("ежик")
        XCTAssertEqual(restored.count,3)
    }

    func testSearchPagesAreStable() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"Запись",fileName:"a.mov",duration:500)
        try await repo.save(item)
        let parts = (0..<121).map { SpeechSegment(start:Double($0),end:Double($0+1),text:"Совпадение") }
        try await repo.replaceSegments(parts,for:item.id)
        var hits: [LibrarySearchHit] = []
        for offset in [0,50,100] { hits += try await repo.find("совпадение",limit:50,offset:offset) }
        XCTAssertEqual(hits.count,121)
        XCTAssertEqual(Set(hits.map(\.id)).count,121)
        XCTAssertEqual(hits.compactMap(\.position),(0..<121).map(Double.init))
    }

    func testRevisionAndUndoPreserveBookmarks() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"Запись",fileName:"a.mov",duration:100)
        try await repo.save(item)
        let original = [SpeechSegment(start:1,end:3,text:"Первая"),SpeechSegment(start:4,end:5,text:"фраза.")]
        try await repo.replaceSegments(original,for:item.id)
        let bookmark = MediaBookmark(mediaID:item.id,position:4,note:"Заметка")
        try await repo.saveBookmark(bookmark)
        let merged = try TranscriptEditing.mergeNext(in:original,id:original[0].id)
        try await repo.reviseSegments(merged,replacing:original,for:item.id)
        XCTAssertEqual(merged.first?.id,original.first?.id)
        XCTAssertEqual(merged.first?.text,"Первая фраза.")
        XCTAssertEqual(merged.first?.end,5)
        let notes = try await repo.bookmarks(for:item.id)
        XCTAssertEqual(notes,[bookmark])
        try await repo.reviseSegments(original,replacing:merged,for:item.id)
        let restored = try await repo.segments(for:item.id)
        XCTAssertEqual(restored,original)
        let replaced = try TranscriptEditing.replaceText(in:original,id:original[0].id,text:"Исправлено")
        try await repo.replaceSegments(replaced,for:item.id)
        do { try await repo.reviseSegments(merged,replacing:original,for:item.id); XCTFail("Stale edits must fail") }
        catch MediaRepository.Error.transcriptConflict {}
        let preserved = try await repo.segments(for:item.id)
        XCTAssertEqual(preserved,replaced)
    }

    func testEditingAndHighlightBounds() throws {
        let segment = SpeechSegment(start:1,end:2,text:"Оригинал")
        XCTAssertThrowsError(try TranscriptEditing.replaceText(in:[segment],id:segment.id,text:" \n "))
        XCTAssertThrowsError(try TranscriptEditing.replaceText(in:[segment],id:segment.id,text:String(repeating:"a",count:20_001)))
        XCTAssertThrowsError(try TranscriptEditing.mergeNext(in:[segment],id:segment.id))
        let updated = try TranscriptEditing.replaceText(in:[segment],id:segment.id,text:"  Новый текст  ")
        XCTAssertEqual(updated.first?.start,segment.start)
        XCTAssertEqual(updated.first?.end,segment.end)
        XCTAssertEqual(updated.first?.text,"Новый текст")
        let text = "Ёжик ёжик 👩‍💻"
        XCTAssertEqual(MediaSearch.ranges(in:text,query:"ежик").map { String(text[$0]) },["Ёжик","ёжик"])
        XCTAssertTrue(MediaSearch.ranges(in:text,query:" ").isEmpty)
    }

    func testBookmarkExport() {
        let id = UUID()
        let result = BookmarkExport.text(title:"Лекция",bookmarks:[MediaBookmark(mediaID:id,position:3661,note:"Тезис\nДетали"),MediaBookmark(mediaID:id,position:25)])
        XCTAssertEqual(result,"Лекция\n\n[0:25] Без заметки\n\n[1:01:01] Тезис\nДетали\n")
    }

    func testLargeTranscriptSearch() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"Большая запись",fileName:"a.mov",duration:10_000)
        try await repo.save(item)
        try await repo.replaceSegments((0..<10_000).map { SpeechSegment(start:Double($0),end:Double($0+1),text:$0 == 9999 ? "Контрольная фраза" : "Другой текст") },for:item.id)
        let start = ContinuousClock.now
        let hits = try await repo.find("контрольная")
        print("Search 10000 segments: \(ContinuousClock.now - start)")
        XCTAssertEqual(hits.first?.position,9999)
    }

    private func databaseURL() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root.appendingPathComponent("library.sqlite")
    }
}
