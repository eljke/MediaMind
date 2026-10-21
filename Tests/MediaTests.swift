import Foundation
import XCTest
@testable import MediaMindCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
final class MediaTests: XCTestCase {
    func testSRT() {
        let srt="1\n00:00:01,000 --> 00:00:03,100\nПривет, мир\n\n2\n00:01:12,500 --> 00:01:14,000\nВторая строка\n"
        let parsed=Subtitles.decode(srt)
        XCTAssertEqual(parsed.count,2)
        XCTAssertEqual(parsed[1].start,72.5)
        XCTAssertEqual(Subtitles.decode(Subtitles.encodeSRT(parsed)).map(\.text),parsed.map(\.text))
    }
    func testVTT() {
        let input="WEBVTT\n\n00:01.200 --> 00:02.200\nPhrase\n\n"
        let seg=Subtitles.decode(input)
        XCTAssertEqual(seg.count,1)
        XCTAssertEqual(seg[0].start,1.2,accuracy:0.001)
        XCTAssertTrue(Subtitles.encodeVTT(seg).hasPrefix("WEBVTT"))
    }
    func testRepository() async throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("media.sqlite")
        let repo=try MediaRepository(url:path)
        let item=MediaItem(title:"Тест",fileName:"file.mp3")
        try await repo.save(item)
        try await repo.replaceSegments([SpeechSegment(start:10,end:12,text:"Проверка аккумулятора"),SpeechSegment(start:25,end:27,text:"Hello")],for:item.id)
        let hits = try await repo.search("аккумулятор")
        XCTAssertEqual(hits.count,1)
        XCTAssertEqual(hits[0].segment.start,10)
        let all = try await repo.all()
        XCTAssertEqual(all.count,1)
        try await repo.remove(item.id)
        let after = try await repo.search("Hello")
        XCTAssertEqual(after.count,0)
    }
    func testLiteralWildcard() async throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("media.sqlite")
        let repo=try MediaRepository(url:path)
        let i=MediaItem(title:"D",fileName:"a")
        try await repo.save(i)
        try await repo.replaceSegments([SpeechSegment(start:0,end:1,text:"test value")],for:i.id)
        let result = try await repo.search("%")
        XCTAssertTrue(result.isEmpty)
    }
    func testSubtitleEdgeCases() {
        let input = "\u{FEFF}WEBVTT\r\n\r\nNOTE ignored --> invalid\r\ncomment\r\n \t\r\ncue-1\r\n00:02.000 --> 00:03.500 align:start\r\nNOTE is spoken text\r\n\r\n00:01.000 --> 00:01.500\r\nПервая строка\r\nвторая строка\r\n\r\n00:01:NaN --> 00:01:05\r\nBad\r\n\r\n00:1.5:00 --> 00:02:00\r\nBad\r\n\r\n00:05 --> 00:04\r\nBad"
        let parts = Subtitles.decode(input)
        XCTAssertEqual(parts.map(\.start),[1,2])
        XCTAssertEqual(parts.map(\.text),["Первая строка\nвторая строка","NOTE is spoken text"])
        XCTAssertEqual(Subtitles.decode(Subtitles.encodeVTT(parts)).map(\.text),parts.map(\.text))
        XCTAssertTrue(Subtitles.decode("00:00:inf --> 00:00:inf\nBad").isEmpty)
        XCTAssertTrue(Subtitles.decode("9999999999999999:00:00 --> 9999999999999999:00:00\nBad").isEmpty)
    }
    func testUpdateKeepsTranscript() async throws {
        let repo = try MediaRepository(url:databaseURL())
        var item = MediaItem(title:"Запись",fileName:"a.mp3")
        let parts = [SpeechSegment(start:1,end:2,text:"Важная фраза")]
        try await repo.save(item)
        try await repo.replaceSegments(parts,for:item.id)
        item.title = "Новое название"
        try await repo.save(item)
        let saved = try await repo.segments(for:item.id)
        XCTAssertEqual(saved,parts)
        let items = try await repo.all()
        XCTAssertEqual(items.first?.title,item.title)
    }
    func testRussianSearch() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"Русский",fileName:"a")
        try await repo.save(item)
        try await repo.replaceSegments([SpeechSegment(start:0,end:1,text:"ЁЖИК: Съешь ещё 100%_\\ готового")],for:item.id)
        for query in ["  ежик  ","СЪЕШЬ", "ЕЩЁ", "100%_\\"] {
            let hits = try await repo.search(query)
            XCTAssertEqual(hits.count,1,query)
        }
        let empty = try await repo.search("  \n")
        XCTAssertTrue(empty.isEmpty)
        let injection = try await repo.search("' OR 1=1 --")
        XCTAssertTrue(injection.isEmpty)
        let noLimit = try await repo.search("ежик",limit:0)
        XCTAssertTrue(noLimit.isEmpty)
    }
    func testFailedReplaceRollsBack() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"D",fileName:"a")
        let original = [SpeechSegment(start:0,end:1,text:"Original")]
        try await repo.save(item)
        try await repo.replaceSegments(original,for:item.id)
        let duplicate = SpeechSegment(start:2,end:3,text:"Duplicate")
        do {
            try await repo.replaceSegments([duplicate,duplicate],for:item.id)
            XCTFail("Duplicate IDs must fail")
        } catch {}
        let saved = try await repo.segments(for:item.id)
        XCTAssertEqual(saved,original)
        try await repo.replaceSegments([SpeechSegment(start:4,end:5,text:"New")],for:item.id)
        let updated = try await repo.segments(for:item.id)
        XCTAssertEqual(updated.map(\.text),["New"])
    }
    func testTrashAndRestore() async throws {
        let path = databaseURL()
        let repo = try MediaRepository(url:path)
        let item = MediaItem(title:"D",fileName:"a",addedAt:Date(timeIntervalSince1970:1_700_000_000))
        let original = [SpeechSegment(start:0,end:1,text:"Remember")]
        try await repo.save(item)
        try await repo.replaceSegments(original,for:item.id)
        try await repo.trash(item.id)
        let reopened = try MediaRepository(url:path)
        let library = try await reopened.all()
        let hits = try await reopened.search("Remember")
        let trash = try await reopened.trashed()
        XCTAssertTrue(library.isEmpty)
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(trash,[item])
        try await reopened.restore(item.id)
        let restored = try await repo.all()
        let saved = try await repo.segments(for:item.id)
        XCTAssertEqual(restored,[item])
        XCTAssertEqual(saved,original)
        try await repo.trash(item.id)
        try await repo.remove(item.id)
        let deleted = try await repo.trashed()
        let deletedSegments = try await repo.segments(for:item.id)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(deletedSegments.isEmpty)
    }
    func testCheckpointSurvivesRelaunch() async throws {
        let path = databaseURL()
        let repo = try MediaRepository(url:path)
        let item = MediaItem(title:"D",fileName:"a")
        let original = [SpeechSegment(start:0,end:1,text:"Existing subtitles")]
        try await repo.save(item)
        try await repo.replaceSegments(original,for:item.id)
        let checkpoint = TranscriptionCheckpoint(language:"ru-RU",nextOffset:45,segments:[SpeechSegment(start:2,end:3,text:"Partial")])
        try await repo.saveCheckpoint(checkpoint,for:item.id)
        let reopened = try MediaRepository(url:path)
        let loaded = try await reopened.checkpoint(for:item.id)
        let before = try await reopened.segments(for:item.id)
        XCTAssertEqual(loaded,checkpoint)
        XCTAssertEqual(before,original)
        try await reopened.replaceSegments(checkpoint.segments,for:item.id)
        let after = try await repo.checkpoint(for:item.id)
        let completed = try await repo.segments(for:item.id)
        XCTAssertNil(after)
        XCTAssertEqual(completed,checkpoint.segments)
    }
    func testSpeechPhrases() {
        let words = [SpeechSegment(start:0,end:0.5,text:"Привет,"),SpeechSegment(start:0.6,end:1,text:"мир!"),SpeechSegment(start:1.1,end:2,text:"Новая фраза"),SpeechSegment(start:5,end:6,text:"После паузы")]
        let phrases = Transcript.phrases(words)
        XCTAssertEqual(phrases.map(\.text),["Привет, мир!","Новая фраза","После паузы"])
        XCTAssertEqual(phrases.map(\.start),[0,1.1,5])
        XCTAssertEqual(phrases.map(\.end),[1,2,6])
    }
    func testLegacyMigration() async throws {
        let path = databaseURL()
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        let itemID = UUID()
        let segmentID = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&handle),SQLITE_OK)
        let schema = "CREATE TABLE media(id TEXT PRIMARY KEY,title TEXT NOT NULL,file TEXT NOT NULL,added REAL NOT NULL,duration REAL NOT NULL); CREATE TABLE segments(id TEXT PRIMARY KEY,media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,start REAL NOT NULL,finish REAL NOT NULL,body TEXT NOT NULL); INSERT INTO media VALUES('\(itemID)','Legacy','a.mp3',0,60); INSERT INTO segments VALUES('\(segmentID)','\(itemID)',1,2,'Старые субтитры');"
        XCTAssertEqual(sqlite3_exec(handle,schema,nil,nil,nil),SQLITE_OK)
        sqlite3_close(handle)
        let repo = try MediaRepository(url:path)
        let original = try await repo.segments(for:itemID)
        XCTAssertEqual(original.map(\.text),["Старые субтитры"])
        try await repo.trash(itemID)
        let trash = try await repo.trashed()
        XCTAssertEqual(trash.first?.title,"Legacy")
        try await repo.restore(itemID)
        let hits = try await repo.search("СТАРЫЕ")
        XCTAssertEqual(hits.count,1)
    }
    func testNewerSchemaIsPreserved() throws {
        let path = databaseURL()
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&handle),SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle,"PRAGMA user_version=4",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try MediaRepository(url:path))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,"PRAGMA user_version",-1,&statement,nil),SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement,0),4)
    }
    private func databaseURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        return folder.appendingPathComponent("media.sqlite")
    }
}
