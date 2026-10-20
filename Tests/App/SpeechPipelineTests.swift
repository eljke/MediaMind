#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest
import AVFoundation
import Speech
@testable import MediaMind

@MainActor
final class SpeechPipelineTests: XCTestCase {
    func testProbeDoesNotRequestPermission() async {
        let before = SFSpeechRecognizer.authorizationStatus()
        _ = await AppleOfflineSpeech().readiness(language:"ru-RU")
        XCTAssertEqual(SFSpeechRecognizer.authorizationStatus(),before)
    }

    func testChunkCancellationAndResume() async throws {
        let root = try temporaryFolder()
        let file = try audio(at:root.appendingPathComponent("recording.wav"),seconds:136)
        let path = root.appendingPathComponent("library.sqlite")
        let repo = try MediaRepository(url:path)
        let item = MediaItem(title:"Длинная запись",fileName:"recording.wav",duration:136)
        let original = [SpeechSegment(start:0,end:1,text:"Прежний текст")]
        try await repo.save(item)
        try await repo.replaceSegments(original,for:item.id)
        let initial = TranscriptionCheckpoint(language:"ru-RU")
        try await repo.saveCheckpoint(initial,for:item.id)
        let service = AppleOfflineSpeech()
        var temporary: [URL] = []
        var calls = 0
        let work = Task {
            try await service.transcribeChunks(file:file,checkpoint:initial,save: { value in
                try await repo.saveCheckpoint(value,for:item.id)
            },progress: { _ in }) { url in
                temporary.append(url); calls += 1
                if calls == 2 { try await Task.sleep(for:.seconds(30)) }
                return [SpeechSegment(start:0,end:0.5,text:"Фраза")]
            }
        }
        defer { work.cancel() }
        let limit = ContinuousClock.now.advanced(by:.seconds(15))
        while calls < 2 && ContinuousClock.now < limit { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(calls,2)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled processing must stop") }
        catch is CancellationError {}
        let reopened = try MediaRepository(url:path)
        let saved = try await reopened.checkpoint(for:item.id)
        let checkpoint = try XCTUnwrap(saved)
        XCTAssertEqual(checkpoint.nextOffset,45)
        XCTAssertEqual(checkpoint.segments.count,1)
        let published = try await reopened.segments(for:item.id)
        XCTAssertEqual(published,original)
        XCTAssertTrue(temporary.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
        var fractions: [Double] = []
        let result = try await service.transcribeChunks(file:file,checkpoint:checkpoint,save: { value in
            try await reopened.saveCheckpoint(value,for:item.id)
        },progress: { fractions.append($0) }) { url in
            temporary.append(url)
            let duration = try await AVURLAsset(url:url).load(.duration).seconds
            XCTAssertGreaterThan(duration,0)
            XCTAssertLessThanOrEqual(duration,45.1)
            return [SpeechSegment(start:0,end:0.5,text:"Фраза")]
        }
        XCTAssertEqual(result.map(\.start),[0,45,90,135])
        XCTAssertEqual(fractions.last,1)
        let completed = try await reopened.checkpoint(for:item.id)
        XCTAssertEqual(completed?.nextOffset,136)
        XCTAssertTrue(temporary.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
    }

    func testSilentChunksAdvance() async throws {
        let root = try temporaryFolder()
        let file = try audio(at:root.appendingPathComponent("silence.wav"),seconds:91)
        var saved: [TranscriptionCheckpoint] = []
        var calls = 0
        let result = try await AppleOfflineSpeech().transcribeChunks(file:file,checkpoint:TranscriptionCheckpoint(language:"ru-RU"),save: { saved.append($0) },progress: { _ in }) { _ in
            calls += 1
            return calls == 3 ? [SpeechSegment(start:0,end:0.5,text:"После тишины")] : []
        }
        XCTAssertEqual(saved.map(\.nextOffset),[45,90,91])
        XCTAssertEqual(result.map(\.start),[90])
    }

    func testInvalidTimesKeepCheckpoint() async throws {
        let root = try temporaryFolder()
        let file = try audio(at:root.appendingPathComponent("invalid.wav"),seconds:2)
        var writes = 0
        var temporary: URL?
        do {
            _ = try await AppleOfflineSpeech().transcribeChunks(file:file,checkpoint:TranscriptionCheckpoint(language:"ru-RU"),save: { _ in writes += 1 },progress: { _ in }) { url in
                temporary = url
                return [SpeechSegment(start:Double.nan,end:1,text:"Некорректно")]
            }
            XCTFail("Invalid timestamps must fail")
        } catch SpeechServiceError.invalidResult {}
        XCTAssertEqual(writes,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(temporary).path))
    }

    private func audio(at url: URL, seconds: Int) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = 0 }
        do {
            let file = try AVAudioFile(forWriting:url,settings:format.settings)
            for _ in 0..<seconds { try file.write(from:buffer) }
        }
        return url
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
}
#endif
