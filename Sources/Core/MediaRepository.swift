import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
public actor MediaRepository {
    private var db: OpaquePointer?
    public enum Error: Swift.Error { case open, sql }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Error.open }
        let schema = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY,title TEXT NOT NULL,file TEXT NOT NULL,added REAL NOT NULL,duration REAL NOT NULL); CREATE TABLE IF NOT EXISTS segments(id TEXT PRIMARY KEY,media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,start REAL NOT NULL,finish REAL NOT NULL,body TEXT NOT NULL); CREATE INDEX IF NOT EXISTS segment_search ON segments(media_id,start);"
        guard sqlite3_exec(db,schema,nil,nil,nil) == SQLITE_OK else { throw Error.sql }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func sql(_ command: String) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db,command,-1,&p,nil) == SQLITE_OK, let p else { throw Error.sql }
        return p
    }
    public func save(_ item: MediaItem) throws {
        let s = try sql("INSERT OR REPLACE INTO media(id,title,file,added,duration) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(s) }
        _ = item.id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        _ = item.title.withCString { sqlite3_bind_text(s,2,$0,-1,sqliteTransient) }
        _ = item.fileName.withCString { sqlite3_bind_text(s,3,$0,-1,sqliteTransient) }
        sqlite3_bind_double(s,4,item.addedAt.timeIntervalSince1970)
        sqlite3_bind_double(s,5,item.duration)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func all() throws -> [MediaItem] {
        let s = try sql("SELECT id,title,file,added,duration FROM media ORDER BY added DESC")
        defer { sqlite3_finalize(s) }
        var results: [MediaItem] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let i = sqlite3_column_text(s,0), let t = sqlite3_column_text(s,1), let f = sqlite3_column_text(s,2), let id = UUID(uuidString: String(cString:i)) else { continue }
            results.append(MediaItem(id:id,title:String(cString:t),fileName:String(cString:f),addedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,3)),duration:sqlite3_column_double(s,4)))
        }
        return results
    }
    public func remove(_ id: UUID) throws {
        let s = try sql("DELETE FROM media WHERE id=?")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Error.sql }
    }
    public func replaceSegments(_ parts: [SpeechSegment], for id: UUID) throws {
        guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { throw Error.sql }
        do {
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
            guard sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else { throw Error.sql }
        } catch {
            _ = sqlite3_exec(db,"ROLLBACK",nil,nil,nil)
            throw error
        }
    }
    public func segments(for id: UUID) throws -> [SpeechSegment] {
        let s = try sql("SELECT id,start,finish,body FROM segments WHERE media_id=? ORDER BY start")
        defer { sqlite3_finalize(s) }
        _ = id.uuidString.withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        var result: [SpeechSegment] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let i = sqlite3_column_text(s,0), let text = sqlite3_column_text(s,3), let uid = UUID(uuidString:String(cString:i)) else { continue }
            result.append(SpeechSegment(id:uid,start:sqlite3_column_double(s,1),end:sqlite3_column_double(s,2),text:String(cString:text)))
        }
        return result
    }
    public func search(_ query: String, limit: Int = 200) throws -> [MediaHit] {
        let s = try sql("SELECT m.id,m.title,m.file,m.added,m.duration,s.id,s.start,s.finish,s.body FROM segments s JOIN media m ON m.id=s.media_id WHERE s.body LIKE ? ESCAPE '\\' ORDER BY m.added DESC,s.start LIMIT ?")
        defer { sqlite3_finalize(s) }
        let escaped = query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")
        _ = ("%" + escaped + "%").withCString { sqlite3_bind_text(s,1,$0,-1,sqliteTransient) }
        sqlite3_bind_int(s,2,Int32(max(1,min(1000,limit))))
        var hits: [MediaHit] = []
        while sqlite3_step(s) == SQLITE_ROW {
            func str(_ index: Int32) -> String { guard let c = sqlite3_column_text(s,index) else { return "" }; return String(cString:c) }
            guard let itemID = UUID(uuidString:str(0)), let segID = UUID(uuidString:str(5)) else { continue }
            let item = MediaItem(id:itemID,title:str(1),fileName:str(2),addedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,3)),duration:sqlite3_column_double(s,4))
            let seg = SpeechSegment(id:segID,start:sqlite3_column_double(s,6),end:sqlite3_column_double(s,7),text:str(8))
            hits.append(MediaHit(item:item,segment:seg))
        }
        return hits
    }
}
