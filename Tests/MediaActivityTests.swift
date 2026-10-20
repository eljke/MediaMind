import Foundation
import XCTest
@testable import MediaMindCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

final class MediaActivityTests: XCTestCase {
    func testBookmarksSurviveUpdates() async throws {
        let path = databaseURL()
        let repo = try MediaRepository(url:path)
        var item = MediaItem(title:"Запись",fileName:"a.mov",duration:100)
        try await repo.save(item)
        var bookmark = MediaBookmark(mediaID:item.id,position:12.5,note:"Обсудить 'SQL'; 100%")
        try await repo.saveBookmark(bookmark)
        bookmark.note = "Исправлено: ёжик 👩‍💻"
        try await repo.saveBookmark(bookmark)
        item.title = "Новое имя"
        try await repo.save(item)
        try await repo.replaceSegments([SpeechSegment(start:0,end:20,text:"Текст")],for:item.id)
        let reopened = try MediaRepository(url:path)
        let saved = try await reopened.bookmarks(for:item.id)
        XCTAssertEqual(saved.map(\.id),[bookmark.id])
        XCTAssertEqual(saved.map(\.note),[bookmark.note])
        XCTAssertEqual(saved.first?.position,12.5)
        try await reopened.removeBookmark(bookmark.id)
        let after = try await repo.bookmarks(for:item.id)
        XCTAssertTrue(after.isEmpty)
    }

    func testBookmarkBounds() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"D",fileName:"a",duration:60)
        try await repo.save(item)
        for position in [-1,61,Double.nan,Double.infinity] {
            do {
                try await repo.saveBookmark(MediaBookmark(mediaID:item.id,position:position))
                XCTFail("Invalid time must fail")
            } catch MediaRepository.Error.invalidBookmark {} catch { XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await repo.saveBookmark(MediaBookmark(mediaID:item.id,position:1,note:String(repeating:"a",count:2001)))
            XCTFail("Oversized notes must fail")
        } catch MediaRepository.Error.invalidBookmark {} catch { XCTFail("Unexpected error: \(error)") }
        try await repo.saveBookmark(MediaBookmark(mediaID:item.id,position:0))
        try await repo.saveBookmark(MediaBookmark(mediaID:item.id,position:60,note:String(repeating:"👩‍💻",count:2000)))
        let saved = try await repo.bookmarks(for:item.id)
        XCTAssertEqual(saved.map(\.position),[0,60])
    }

    func testPlaybackIgnoresStaleWrites() async throws {
        let path = databaseURL()
        let repo = try MediaRepository(url:path)
        let item = MediaItem(title:"D",fileName:"a",duration:100)
        try await repo.save(item)
        try await repo.savePlayback(PlaybackPosition(position:45,playedAt:Date(timeIntervalSince1970:200)),for:item.id)
        try await repo.savePlayback(PlaybackPosition(position:10,playedAt:Date(timeIntervalSince1970:100)),for:item.id)
        let reopened = try MediaRepository(url:path)
        let overview = try await reopened.overview()
        XCTAssertEqual(overview[item.id]?.playback?.position,45)
        XCTAssertEqual(overview[item.id]?.playback?.playedAt,Date(timeIntervalSince1970:200))
        try await reopened.savePlayback(PlaybackPosition(position:150,playedAt:Date(timeIntervalSince1970:300)),for:item.id)
        let completed = try await repo.overview()
        XCTAssertEqual(completed[item.id]?.playback?.position,100)
        XCTAssertEqual(completed[item.id]?.playback?.canResume(duration:100),false)
        XCTAssertTrue(PlaybackPosition(position:1).canResume(duration:100))
        XCTAssertFalse(PlaybackPosition(position:0).canResume(duration:100))
        XCTAssertFalse(PlaybackPosition(position:99.5).canResume(duration:100))
    }

    func testTranscriptStates() async throws {
        let path = databaseURL()
        let repo = try MediaRepository(url:path)
        let item = MediaItem(title:"D",fileName:"a",duration:100)
        try await repo.save(item)
        var overview = try await repo.overview()
        XCTAssertEqual(overview[item.id]?.transcript,.empty)
        let parts = [SpeechSegment(start:0,end:1,text:"Оригинал")]
        try await repo.replaceSegments(parts,for:item.id)
        overview = try await repo.overview()
        XCTAssertEqual(overview[item.id]?.transcript,.ready(1))
        try await repo.saveCheckpoint(TranscriptionCheckpoint(language:"ru-RU",nextOffset:45),for:item.id)
        overview = try await repo.overview()
        XCTAssertEqual(overview[item.id]?.transcript,.paused)
        try await repo.recordTranscriptionFailure("Модель недоступна",for:item.id)
        let reopened = try MediaRepository(url:path)
        overview = try await reopened.overview()
        XCTAssertEqual(overview[item.id]?.transcript,.failed("Модель недоступна"))
        let original = try await repo.segments(for:item.id)
        XCTAssertEqual(original,parts)
        try await reopened.replaceSegments(parts,for:item.id)
        overview = try await repo.overview()
        XCTAssertEqual(overview[item.id]?.transcript,.ready(1))
    }

    func testTrashPreservesActivity() async throws {
        let repo = try MediaRepository(url:databaseURL())
        let item = MediaItem(title:"D",fileName:"a",duration:100)
        try await repo.save(item)
        let bookmark = MediaBookmark(mediaID:item.id,position:15,note:"Важно")
        try await repo.saveBookmark(bookmark)
        try await repo.savePlayback(PlaybackPosition(position:20),for:item.id)
        try await repo.trash(item.id)
        let hidden = try await repo.all()
        XCTAssertTrue(hidden.isEmpty)
        try await repo.restore(item.id)
        let saved = try await repo.bookmarks(for:item.id)
        let overview = try await repo.overview()
        XCTAssertEqual(saved.first?.id,bookmark.id)
        XCTAssertEqual(overview[item.id]?.playback?.position,20)
        try await repo.remove(item.id)
        let deleted = try await repo.bookmarks(for:item.id)
        let after = try await repo.overview()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(after[item.id])
    }

    func testVersionOneBackup() async throws {
        let path = databaseURL()
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        let id = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&handle),SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = "PRAGMA journal_mode=WAL; CREATE TABLE media(id TEXT PRIMARY KEY,title TEXT NOT NULL,file TEXT NOT NULL,added REAL NOT NULL,duration REAL NOT NULL); CREATE TABLE segments(id TEXT PRIMARY KEY,media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,start REAL NOT NULL,finish REAL NOT NULL,body TEXT NOT NULL); CREATE TABLE transcription_checkpoints(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,payload TEXT NOT NULL); CREATE TABLE media_trash(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,deleted REAL NOT NULL); INSERT INTO media VALUES('\(id)','Legacy','a.mov',0,100); PRAGMA user_version=1;"
        XCTAssertEqual(sqlite3_exec(handle,schema,nil,nil,nil),SQLITE_OK)
        let repo = try MediaRepository(url:path)
        try await repo.saveBookmark(MediaBookmark(mediaID:id,position:10,note:"После обновления"))
        let backup = path.appendingPathExtension("v1-backup.sqlite")
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path,&copy,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        defer { sqlite3_close(copy) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy,"SELECT title,(SELECT user_version FROM pragma_user_version) FROM media",-1,&statement,nil),SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        XCTAssertEqual(String(cString:try XCTUnwrap(sqlite3_column_text(statement,0))),"Legacy")
        XCTAssertEqual(sqlite3_column_int(statement,1),1)
        let saved = try await repo.bookmarks(for:id)
        XCTAssertEqual(saved.count,1)
    }

    private func databaseURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        return folder.appendingPathComponent("media.sqlite")
    }
}
