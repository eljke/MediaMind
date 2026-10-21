import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
public actor MediaRepository {
    private var db: OpaquePointer?
    public enum Error: LocalizedError {
        case open, sql, invalidSegment, newerSchema, backup, invalidBookmark, invalidPlayback, transcriptConflict
        public var errorDescription: String? {
            switch self {
            case .open: return "Не удалось открыть локальную библиотеку."
            case .sql: return "Не удалось прочитать или сохранить библиотеку."
            case .invalidSegment: return "В расшифровке недопустимые временные отметки."
            case .newerSchema: return "Библиотека создана более новой версией приложения. Обнови MediaMind."
            case .backup: return "Не удалось создать копию базы перед обновлением. Проверь свободное место."
            case .invalidBookmark: return "Проверь время закладки и длину заметки (до 2000 символов)."
            case .invalidPlayback: return "Не удалось сохранить некорректную позицию воспроизведения."
            case .transcriptConflict: return "Расшифровка уже изменилась. Открой её заново; сохранённые данные не перезаписаны."
            }
        }
    }
    public init(url: URL) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw Error.open
        }
        sqlite3_busy_timeout(db, 5000)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&versionStatement,nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW else {
            sqlite3_finalize(versionStatement)
            sqlite3_close(db)
            db = nil
            throw Error.sql
        }
        let version = sqlite3_column_int(versionStatement,0)
        sqlite3_finalize(versionStatement)
        guard version <= 3 else {
            sqlite3_close(db)
            db = nil
            throw Error.newerSchema
        }
        if existing && version < 3 {
            do { try Self.backup(db, to: url.appendingPathExtension("v\(version)-backup.sqlite")) }
            catch { sqlite3_close(db); db = nil; throw error }
        }
        sqlite3_create_function_v2(db, "media_normalized", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let value = values?[0], let text = sqlite3_value_text(value) else {
                sqlite3_result_null(context); return
            }
            let result = MediaSearch.normalized(String(cString: text))
            result.withCString { sqlite3_result_text(context, $0, -1, sqliteTransient) }
        }, nil, nil, nil)
        let schema = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY,title TEXT NOT NULL,file TEXT NOT NULL,added REAL NOT NULL,duration REAL NOT NULL); CREATE TABLE IF NOT EXISTS segments(id TEXT PRIMARY KEY,media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,start REAL NOT NULL,finish REAL NOT NULL,body TEXT NOT NULL); CREATE INDEX IF NOT EXISTS segment_search ON segments(media_id,start);"
        // Additive v1 migration: existing media/segments remain readable by v0 builds.
        let migration = "BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS transcription_checkpoints(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS media_trash(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,deleted REAL NOT NULL); PRAGMA user_version=1; COMMIT;"
        let schemaStatus = sqlite3_exec(db,schema,nil,nil,nil)
        var migrationStatus = SQLITE_OK
        if schemaStatus == SQLITE_OK && version == 0 { migrationStatus = sqlite3_exec(db,migration,nil,nil,nil) }
        if schemaStatus == SQLITE_OK && migrationStatus == SQLITE_OK && version < 2 {
            let activitySchema = "BEGIN IMMEDIATE; CREATE TABLE bookmarks(id TEXT PRIMARY KEY,media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,position REAL NOT NULL CHECK(position>=0),note TEXT NOT NULL,created REAL NOT NULL); CREATE INDEX bookmark_media ON bookmarks(media_id,position); CREATE TABLE playback(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,position REAL NOT NULL CHECK(position>=0),played REAL NOT NULL); CREATE TABLE transcription_failures(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,message TEXT NOT NULL); PRAGMA user_version=2; COMMIT;"
            migrationStatus = sqlite3_exec(db,activitySchema,nil,nil,nil)
        }
        if schemaStatus == SQLITE_OK && migrationStatus == SQLITE_OK && version < 3 {
            migrationStatus = sqlite3_exec(db,"BEGIN IMMEDIATE; CREATE TABLE summaries(media_id TEXT PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,body TEXT NOT NULL,source TEXT NOT NULL); PRAGMA user_version=3; COMMIT;",nil,nil,nil)
        }
        guard schemaStatus == SQLITE_OK, migrationStatus == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw Error.sql
        }
    }
    private static func backup(_ source: OpaquePointer?, to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK else {
            sqlite3_close(destination)
            throw Error.backup
        }
        defer { sqlite3_close(destination) }
        guard let copy = sqlite3_backup_init(destination, "main", source, "main") else { throw Error.backup }
        let status = sqlite3_backup_step(copy, -1)
        let finished = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw Error.backup }
    }
    deinit { if let db { sqlite3_close(db) } }
    public func snapshot(to url: URL) throws {
        try Self.backup(db,to:url)
    }
    public func checkIntegrity() throws {
        let s = try sql("PRAGMA quick_check")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s,0), String(cString:text) == "ok" else { throw Error.backup }
        let f = try sql("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(f) }
        guard sqlite3_step(f) == SQLITE_DONE else { throw Error.backup }
        let schema = try sql("SELECT COUNT(*) FROM sqlite_schema WHERE type IN ('trigger','view')")
        defer { sqlite3_finalize(schema) }
        guard sqlite3_step(schema) == SQLITE_ROW, sqlite3_column_int(schema,0) == 0 else { throw Error.backup }
    }
    public func restoreSnapshot(from url: URL) throws {
        guard try all().isEmpty, try trashed().isEmpty else { throw LibraryBackupError.notEmpty }
        var source: OpaquePointer?
        guard sqlite3_open_v2(url.path,&source,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { sqlite3_close(source); throw Error.backup }
        defer { sqlite3_close(source) }
        guard let copy = sqlite3_backup_init(db,"main",source,"main") else { throw Error.backup }
        let status = sqlite3_backup_step(copy,-1)
        let finished = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw Error.backup }
    }
    public func summary(for id: UUID) throws -> MediaSummary? {
        let s = try sql("SELECT body,source FROM summaries WHERE media_id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let body = sqlite3_column_text(s,0), let source = sqlite3_column_text(s,1) else { throw Error.sql }
        return MediaSummary(text:String(cString:body),source:try JSONDecoder().decode([SpeechSegment].self,from:Data(String(cString:source).utf8)))
    }
    public func saveSummary(_ summary: MediaSummary, for id: UUID) throws {
        guard summary.text.count <= MediaSummary.textLimit else { throw TranscriptEditing.Error.invalidText }
        let source = String(decoding:try JSONEncoder().encode(summary.source),as:UTF8.self)
        let s = try sql("INSERT INTO summaries(media_id,body,source) VALUES(?,?,?) ON CONFLICT(media_id) DO UPDATE SET body=excluded.body,source=excluded.source")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        _ = summary.text.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
        _ = source.withCString { sqlite3_bind_text(s,3,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    private func sql(_ command: String) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db,command,-1,&p,nil) == SQLITE_OK, let p else { throw Error.sql }
        return p
    }
    public func save(_ item: MediaItem) throws {
        let s = try sql("INSERT INTO media(id,title,file,added,duration) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,file=excluded.file,added=excluded.added,duration=excluded.duration")
        defer { sqlite3_finalize(s) }
        _ = item.id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        _ = item.title.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
        _ = item.fileName.withCString { sqlite3_bind_text(s,3,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,4,item.addedAt.timeIntervalSince1970)
        sqlite3_bind_double(s,5,item.duration)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func all() throws -> [MediaItem] {
        try media(trashed: false)
    }
    public func trashed() throws -> [MediaItem] {
        try media(trashed: true)
    }
    private func media(trashed: Bool) throws -> [MediaItem] {
        let condition = trashed ? "EXISTS" : "NOT EXISTS"
        let s = try sql("SELECT id,title,file,added,duration FROM media WHERE \(condition)(SELECT 1 FROM media_trash WHERE media_id=media.id) ORDER BY added DESC")
        defer { sqlite3_finalize(s) }
        var results: [MediaItem] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(s) }
            guard let i = sqlite3_column_text(s,0), let t = sqlite3_column_text(s,1), let f = sqlite3_column_text(s,2), let id = UUID(uuidString: String(cString:i)) else { continue }
            results.append(MediaItem(id:id,title:String(cString:t),fileName:String(cString:f),addedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,3)),duration:sqlite3_column_double(s,4)))
        }
        guard status == SQLITE_DONE else { throw Error.sql }
        return results
    }
    public func trash(_ id: UUID) throws {
        let s = try sql("INSERT INTO media_trash(media_id,deleted) VALUES(?,?) ON CONFLICT(media_id) DO NOTHING")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,2,Date.now.timeIntervalSince1970)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func restore(_ id: UUID) throws {
        let s = try sql("DELETE FROM media_trash WHERE media_id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func remove(_ id: UUID) throws {
        let s = try sql("DELETE FROM media WHERE id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func replaceSegments(_ parts: [SpeechSegment], for id: UUID) throws {
        try storeSegments(parts,for:id,expecting:nil)
    }
    private func storeSegments(_ parts: [SpeechSegment], for id: UUID, expecting previous: [SpeechSegment]?) throws {
        guard parts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { throw Error.invalidSegment }
        guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { throw Error.sql }
        do {
            if let previous, try segments(for:id) != previous.sorted(by: { ($0.start,$0.end,$0.id.uuidString) < ($1.start,$1.end,$1.id.uuidString) }) { throw Error.transcriptConflict }
            let d = try sql("DELETE FROM segments WHERE media_id=?")
            _ = id.uuidString.withCString { sqlite3_bind_text(d,1,$0,-1,sqliteTransient) }
            let deleted = sqlite3_step(d) == SQLITE_DONE
            sqlite3_finalize(d)
            guard deleted else { throw Error.sql }
            let s = try sql("INSERT INTO segments(id,media_id,start,finish,body) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(s) }
            for part in parts {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                _ = part.id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
                _ = id.uuidString.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
                sqlite3_bind_double(s,3,part.start)
                sqlite3_bind_double(s,4,part.end)
                _ = part.text.withCString { sqlite3_bind_text(s,5,$0,-1,sqliteTransient) }
                guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
            }
            try clearCheckpoint(for: id)
            try clearTranscriptionFailure(for: id)
            guard sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else { throw Error.sql }
        } catch {
            _ = sqlite3_exec(db,"ROLLBACK",nil,nil,nil)
            throw error
        }
    }
    public func segments(for id: UUID) throws -> [SpeechSegment] {
        let s = try sql("SELECT id,start,finish,body FROM segments WHERE media_id=? ORDER BY start,finish,id")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        var result: [SpeechSegment] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(s) }
            guard let i = sqlite3_column_text(s,0), let text = sqlite3_column_text(s,3), let uid = UUID(uuidString:String(cString:i)) else { continue }
            result.append(SpeechSegment(id:uid,start:sqlite3_column_double(s,1),end:sqlite3_column_double(s,2),text:String(cString:text)))
        }
        guard status == SQLITE_DONE else { throw Error.sql }
        return result
    }
    public func checkpoint(for id: UUID) throws -> TranscriptionCheckpoint? {
        let s = try sql("SELECT payload FROM transcription_checkpoints WHERE media_id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let payload = sqlite3_column_text(s,0) else { throw Error.sql }
        return try JSONDecoder().decode(TranscriptionCheckpoint.self, from: Data(String(cString:payload).utf8))
    }
    public func saveCheckpoint(_ checkpoint: TranscriptionCheckpoint, for id: UUID) throws {
        let payload = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
        let s = try sql("INSERT INTO transcription_checkpoints(media_id,payload) VALUES(?,?) ON CONFLICT(media_id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        _ = payload.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func clearCheckpoint(for id: UUID) throws {
        let s = try sql("DELETE FROM transcription_checkpoints WHERE media_id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func recordTranscriptionFailure(_ message: String, for id: UUID) throws {
        let s = try sql("INSERT INTO transcription_failures(media_id,message) VALUES(?,?) ON CONFLICT(media_id) DO UPDATE SET message=excluded.message")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        _ = message.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func clearTranscriptionFailure(for id: UUID) throws {
        let s = try sql("DELETE FROM transcription_failures WHERE media_id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func overview() throws -> [UUID: MediaOverview] {
        let s = try sql("SELECT m.id,COUNT(s.id),c.media_id IS NOT NULL,f.message,p.position,p.played FROM media m LEFT JOIN segments s ON s.media_id=m.id LEFT JOIN transcription_checkpoints c ON c.media_id=m.id LEFT JOIN transcription_failures f ON f.media_id=m.id LEFT JOIN playback p ON p.media_id=m.id GROUP BY m.id")
        defer { sqlite3_finalize(s) }
        var result: [UUID: MediaOverview] = [:]
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(s) }
            guard let value = sqlite3_column_text(s,0), let id = UUID(uuidString:String(cString:value)) else { continue }
            let count = Int(sqlite3_column_int(s,1))
            let transcript: TranscriptStatus
            if let message = sqlite3_column_text(s,3) { transcript = .failed(String(cString:message)) }
            else if sqlite3_column_int(s,2) != 0 { transcript = .paused }
            else { transcript = count > 0 ? .ready(count) : .empty }
            let playback = sqlite3_column_type(s,4) == SQLITE_NULL ? nil : PlaybackPosition(position:sqlite3_column_double(s,4),playedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,5)))
            result[id] = MediaOverview(transcript:transcript,playback:playback)
        }
        guard status == SQLITE_DONE else { throw Error.sql }
        return result
    }
    public func savePlayback(_ playback: PlaybackPosition, for id: UUID) throws {
        guard playback.position.isFinite, playback.position >= 0, playback.playedAt.timeIntervalSince1970.isFinite else { throw Error.invalidPlayback }
        let s = try sql("INSERT INTO playback(media_id,position,played) SELECT id,MIN(?,duration),? FROM media WHERE id=? ON CONFLICT(media_id) DO UPDATE SET position=excluded.position,played=excluded.played WHERE excluded.played>=playback.played")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s,1,playback.position)
        sqlite3_bind_double(s,2,playback.playedAt.timeIntervalSince1970)
        _ = id.uuidString.withCString { sqlite3_bind_text(s,3,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func saveBookmark(_ bookmark: MediaBookmark) throws {
        guard bookmark.position.isFinite, bookmark.position >= 0, bookmark.note.count <= MediaBookmark.noteLimit else { throw Error.invalidBookmark }
        let s = try sql("INSERT INTO bookmarks(id,media_id,position,note,created) SELECT ?,id,?,?,? FROM media WHERE id=? AND duration>=? ON CONFLICT(id) DO UPDATE SET note=excluded.note WHERE bookmarks.media_id=excluded.media_id AND bookmarks.position=excluded.position")
        defer { sqlite3_finalize(s) }
        _ = bookmark.id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,2,bookmark.position)
        _ = bookmark.note.withCString { sqlite3_bind_text(s,3,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,4,bookmark.createdAt.timeIntervalSince1970)
        _ = bookmark.mediaID.uuidString.withCString { sqlite3_bind_text(s,5,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,6,bookmark.position)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
        guard sqlite3_changes(db) == 1 else { throw Error.invalidBookmark }
    }
    public func bookmarks(for id: UUID) throws -> [MediaBookmark] {
        let s = try sql("SELECT id,position,note,created FROM bookmarks WHERE media_id=? ORDER BY position,created,id")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        var result: [MediaBookmark] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(s) }
            guard let value = sqlite3_column_text(s,0), let uid = UUID(uuidString:String(cString:value)), let note = sqlite3_column_text(s,2) else { throw Error.sql }
            result.append(MediaBookmark(id:uid,mediaID:id,position:sqlite3_column_double(s,1),note:String(cString:note),createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,3))))
        }
        guard status == SQLITE_DONE else { throw Error.sql }
        return result
    }
    public func removeBookmark(_ id: UUID) throws {
        let s = try sql("DELETE FROM bookmarks WHERE id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func reviseSegments(_ updated: [SpeechSegment], replacing previous: [SpeechSegment], for id: UUID) throws {
        try storeSegments(updated,for:id,expecting:previous)
    }

    public func search(_ query: String, limit: Int = 200) throws -> [MediaHit] {
        try find(query,scope:.transcripts,limit:limit).compactMap {
            if case .transcript(let segment) = $0.match { return MediaHit(item:$0.item,segment:segment) }
            return nil
        }
    }

    public func find(_ query: String, scope: SearchScope = .all, kind: MediaKind = .all, limit: Int = 50, offset: Int = 0) throws -> [LibrarySearchHit] {
        let query = MediaSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, limit > 0, offset >= 0 else { return [] }
        var sources: [String] = []
        if scope == .all || scope == .titles { sources.append("SELECT id AS mid,id AS rid,0 AS kind,0 AS start,0 AS finish,title AS body,0 AS created FROM media WHERE media_normalized(title) LIKE (SELECT value FROM pattern) ESCAPE '\\'") }
        if scope == .all || scope == .transcripts { sources.append("SELECT media_id,id,1,start,finish,body,0 FROM segments WHERE media_normalized(body) LIKE (SELECT value FROM pattern) ESCAPE '\\'") }
        if scope == .all || scope == .bookmarks { sources.append("SELECT media_id,id,2,position,position,note,created FROM bookmarks WHERE media_normalized(note) LIKE (SELECT value FROM pattern) ESCAPE '\\'") }
        let video = "(lower(m.file) LIKE '%.mov' OR lower(m.file) LIKE '%.mp4' OR lower(m.file) LIKE '%.m4v')"
        let mediaFilter = kind == .all ? "1" : (kind == .video ? video : "NOT \(video)")
        let s = try sql("WITH pattern AS (SELECT ? AS value), matches(mid,rid,kind,start,finish,body,created) AS (\(sources.joined(separator:" UNION ALL "))) SELECT m.id,m.title,m.file,m.added,m.duration,r.rid,r.kind,r.start,r.finish,r.body,r.created FROM matches r JOIN media m ON m.id=r.mid WHERE NOT EXISTS(SELECT 1 FROM media_trash WHERE media_id=m.id) AND \(mediaFilter) ORDER BY m.added DESC,m.id,r.kind,r.start,r.rid LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(s) }
        let escaped = query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")
        _ = ("%" + escaped + "%").withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        sqlite3_bind_int(s,2,Int32(max(1,min(1000,limit))))
        sqlite3_bind_int64(s,3,Int64(offset))
        var hits: [LibrarySearchHit] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(s) }
            func str(_ index: Int32) -> String { guard let c = sqlite3_column_text(s,index) else { return "" }; return String(cString:c) }
            guard let itemID = UUID(uuidString:str(0)), let segID = UUID(uuidString:str(5)) else { continue }
            let item = MediaItem(id:itemID,title:str(1),fileName:str(2),addedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,3)),duration:sqlite3_column_double(s,4))
            let match: LibrarySearchHit.Match
            switch sqlite3_column_int(s,6) {
            case 0: match = .title
            case 1: match = .transcript(SpeechSegment(id:segID,start:sqlite3_column_double(s,7),end:sqlite3_column_double(s,8),text:str(9)))
            case 2: match = .bookmark(MediaBookmark(id:segID,mediaID:itemID,position:sqlite3_column_double(s,7),note:str(9),createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,10))))
            default: throw Error.sql
            }
            hits.append(LibrarySearchHit(item:item,match:match))
        }
        guard status == SQLITE_DONE else { throw Error.sql }
        return hits
    }
}
