#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest
import AVFoundation
@testable import MediaMind

@MainActor
final class MediaWorkflowTests: XCTestCase {
    func testTranscriptionResumes() async throws {
        let root = try temporaryFolder()
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Запись",fileName:"a.mov",duration:90)
        let original = [SpeechSegment(start:0,end:1,text:"Старый текст")]
        try await repo.save(item)
        try await repo.replaceSegments(original,for:item.id)
        let speech = ScriptedSpeech()
        let vm = MediaViewModel(root:root,speech:speech)
        await vm.reload()
        vm.transcribe(item)
        try await waitUntil { !vm.busy }
        XCTAssertEqual(vm.overview[item.id]?.transcript,.paused)
        let old = try await repo.segments(for:item.id)
        XCTAssertEqual(old,original)
        speech.ending = .finish
        vm.transcribe(item)
        try await waitUntil { !vm.busy }
        XCTAssertEqual(speech.offsets,[0,45])
        XCTAssertEqual(vm.overview[item.id]?.transcript,.ready(1))
        let checkpoint = try await repo.checkpoint(for:item.id)
        XCTAssertNil(checkpoint)
    }

    func testFailureSurvivesRelaunch() async throws {
        let root = try temporaryFolder()
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Запись",fileName:"a.mov",duration:90)
        try await repo.save(item)
        let original = [SpeechSegment(start:0,end:1,text:"Старый текст")]
        try await repo.replaceSegments(original,for:item.id)
        let speech = ScriptedSpeech(); speech.ending = .fail
        let vm = MediaViewModel(root:root,speech:speech)
        await vm.reload()
        vm.transcribe(item)
        try await waitUntil { !vm.busy }
        let reopened = MediaViewModel(root:root)
        await reopened.reload()
        XCTAssertEqual(reopened.overview[item.id]?.transcript,.failed(SpeechServiceError.unavailable.localizedDescription))
        let saved = try await repo.segments(for:item.id)
        XCTAssertEqual(saved,original)
        try await repo.replaceSegments(original,for:item.id)
        await reopened.reload()
        XCTAssertEqual(reopened.overview[item.id]?.transcript,.ready(1))
    }

    func testLegacyPositionAndContinue() async throws {
        let root = try temporaryFolder()
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        var items: [MediaItem] = []
        for index in 0..<5 {
            let item = MediaItem(title:"Запись \(index)",fileName:"a\(index).mov",addedAt:Date(timeIntervalSince1970:10),duration:100)
            try await repo.save(item); items.append(item)
        }
        let key = "position-\(items[0].id)"
        UserDefaults.standard.set(17.0,forKey:key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey:key) }
        let vm = MediaViewModel(root:root)
        await vm.reload()
        XCTAssertNil(UserDefaults.standard.object(forKey:key))
        XCTAssertEqual(vm.overview[items[0].id]?.playback?.position,17)
        for index in 1..<5 {
            await vm.recordPlayback(PlaybackPosition(position:Double(index*10),playedAt:Date(timeIntervalSince1970:Double(100+index))),for:items[index])
        }
        XCTAssertEqual(vm.continuing.map(\.id),[items[4].id,items[3].id,items[2].id])
        await vm.recordPlayback(PlaybackPosition(position:100,playedAt:Date(timeIntervalSince1970:300)),for:items[4])
        XCTAssertFalse(vm.continuing.contains(where: { $0.id == items[4].id }))
        await vm.moveToTrash(items[3])
        XCTAssertFalse(vm.continuing.contains(where: { $0.id == items[3].id }))
        await vm.restore(items[3])
        XCTAssertEqual(vm.continuing.first?.id,items[3].id)
        let reopened = MediaViewModel(root:root)
        await reopened.reload()
        XCTAssertEqual(reopened.continuing.map(\.id),vm.continuing.map(\.id))
    }

    func testBookmarkUndo() async throws {
        let root = try temporaryFolder()
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Запись",fileName:"a.mov",duration:90)
        try await repo.save(item)
        let vm = MediaViewModel(root:root)
        await vm.reload()
        let bookmark = MediaBookmark(mediaID:item.id,position:25,note:"Определение")
        try await vm.saveBookmark(bookmark)
        await vm.removeBookmark(bookmark)
        XCTAssertEqual(vm.deletedBookmark?.id,bookmark.id)
        let empty = await vm.bookmarks(item)
        XCTAssertTrue(empty.isEmpty)
        await vm.undoBookmarkDeletion()
        let restored = await vm.bookmarks(item)
        XCTAssertEqual(restored.first?.note,bookmark.note)
        XCTAssertEqual(restored.first?.position,25)
        XCTAssertNil(vm.deletedBookmark)
    }

    func testPlaybackEvents() async throws {
        let root = try temporaryFolder()
        let source = try audio(at:root.appendingPathComponent("test.wav"))
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let item = MediaItem(title:"Аудио",fileName:"test.wav",duration:8)
        try await repo.save(item)
        let vm = MediaViewModel(root:root)
        await vm.reload()
        let playback = MediaPlayback()
        var snapshots: [PlaybackPosition] = []
        var writes: [Task<Void,Never>] = []
        await playback.open(item,url:source,initialTime:nil,resumePosition:2) { value in
            snapshots.append(value)
            writes.append(Task { await vm.recordPlayback(value,for:item) })
        }
        XCTAssertNil(playback.error)
        playback.pauseAndSave()
        XCTAssertTrue(snapshots.isEmpty,"Browsing must not change listening history")
        let player = try XCTUnwrap(playback.player)
        player.play()
        try await waitUntil { player.currentTime().seconds > 2.2 }
        player.pause()
        try await waitUntil { !snapshots.isEmpty }
        for write in writes { await write.value }
        XCTAssertGreaterThan(vm.overview[item.id]?.playback?.position ?? 0,2)
        XCTAssertEqual(vm.continuing.first?.id,item.id)
        await player.seek(to:CMTime(seconds:7.9,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        player.play()
        try await waitUntil { snapshots.last?.position == 8 }
        playback.close()
        for write in writes { await write.value }
        XCTAssertTrue(vm.continuing.isEmpty)
        XCTAssertNil(playback.player)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by:.seconds(8))
        while !condition() && ContinuousClock.now < limit { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(condition(),"Operation did not reach the expected state")
    }

    private func audio(at url: URL) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:128_000))
        buffer.frameLength = 128_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<128_000 { samples[index] = 0 }
        do { let file = try AVAudioFile(forWriting:url,settings:format.settings); try file.write(from:buffer) }
        return url
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
}

@MainActor
private final class ScriptedSpeech: TranscriptionService {
    enum Ending { case pause, fail, finish }
    var ending = Ending.pause
    var offsets: [Double] = []

    func transcribe(file: URL, checkpoint: TranscriptionCheckpoint, save: @escaping (TranscriptionCheckpoint) async throws -> Void, progress: @escaping (Double) -> Void) async throws -> [SpeechSegment] {
        offsets.append(checkpoint.nextOffset)
        var next = checkpoint
        if next.nextOffset == 0 {
            next.nextOffset = 45
            next.segments = [SpeechSegment(start:1,end:2,text:"Новая фраза")]
            try await save(next)
            progress(0.5)
        }
        switch ending {
        case .pause: throw CancellationError()
        case .fail: throw SpeechServiceError.unavailable
        case .finish: return next.segments
        }
    }
}
#endif
