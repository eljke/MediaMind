import Foundation
import XCTest
@testable import MediaMindCore
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
}
