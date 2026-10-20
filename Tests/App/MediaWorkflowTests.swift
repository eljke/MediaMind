#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest
import AVFoundation
import SwiftUI
@testable import MediaMind

@MainActor
final class MediaWorkflowTests: XCTestCase {
    func testSpeechPreparation() async throws {
        let root = try temporaryFolder()
        let speech = ScriptedSpeech()
        speech.status = SpeechReadiness(permission:.notRequested,model:.missing,legacy:.ready)
        let vm = MediaViewModel(root:root,speech:speech)
        await vm.reload()
        await vm.checkSpeech()
        XCTAssertEqual(vm.speechReadiness?.issue,.permissionRequired)
        vm.requestSpeechPermission()
        try await waitUntil { !vm.busy }
        XCTAssertEqual(speech.permissionRequests,1)
        XCTAssertEqual(vm.speechReadiness?.engine,.recognizer)
        vm.installSpeechModel()
        try await waitUntil { !vm.busy }
        XCTAssertEqual(speech.installRequests,1)
        XCTAssertEqual(vm.speechReadiness?.engine,.analyzer)
        XCTAssertTrue(vm.canTranscribe)
        XCTAssertTrue(speech.offsets.isEmpty)
    }

    func testDownloadCancellation() async throws {
        let root = try temporaryFolder()
        let speech = ScriptedSpeech()
        speech.status = SpeechReadiness(permission:.authorized,model:.missing,legacy:.offlineUnavailable)
        speech.installDelay = .seconds(30)
        let vm = MediaViewModel(root:root,speech:speech)
        await vm.reload()
        vm.installSpeechModel()
        try await waitUntil { speech.installRequests == 1 }
        vm.cancel()
        try await waitUntil { !vm.busy }
        XCTAssertEqual(vm.speechReadiness?.model,.downloading)
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.notice?.contains("iOS") == true)
        let progress = vm.progress
        speech.lateProgress?(0.9)
        XCTAssertEqual(vm.progress,progress)
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testReadinessIgnoresOldLanguage() async throws {
        let previous = UserDefaults.standard.string(forKey:"speechLanguage")
        defer {
            if let previous { UserDefaults.standard.set(previous,forKey:"speechLanguage") }
            else { UserDefaults.standard.removeObject(forKey:"speechLanguage") }
        }
        let speech = ScriptedSpeech()
        speech.delayedLanguage = "ru-RU"
        let vm = MediaViewModel(root:try temporaryFolder(),speech:speech)
        vm.language = "ru-RU"
        let first = Task { await vm.checkSpeech() }
        try await waitUntil { speech.probedLanguages.contains("ru-RU") }
        speech.status = SpeechReadiness(permission:.denied,model:.installed,legacy:.ready)
        vm.language = "en-US"
        await vm.checkSpeech()
        await first.value
        XCTAssertEqual(vm.speechReadiness?.engine,.analyzer)
        XCTAssertFalse(vm.checkingSpeech)
    }

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

    func testLibraryPresentation() async throws {
        let root = try temporaryFolder()
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        _ = try audio(at:folder.appendingPathComponent("preview.wav"))
        let repo = try MediaRepository(url:root.appendingPathComponent("library.sqlite"))
        let ready = MediaItem(title:"Лекция: архитектура приложений",fileName:"preview.wav",duration:8)
        let paused = MediaItem(title:"Интервью с командой",fileName:"interview.mov",duration:120)
        let failed = MediaItem(title:"Обсуждение проекта",fileName:"meeting.m4a",duration:180)
        for item in [ready,paused,failed] { try await repo.save(item) }
        try await repo.replaceSegments([SpeechSegment(start:0,end:4,text:"Важный принцип: состояние принадлежит своему компоненту.")],for:ready.id)
        try await repo.saveCheckpoint(TranscriptionCheckpoint(language:"ru-RU",nextOffset:45),for:paused.id)
        try await repo.recordTranscriptionFailure("Офлайн-модель языка недоступна",for:failed.id)
        try await repo.savePlayback(PlaybackPosition(position:2.5),for:ready.id)
        try await repo.saveBookmark(MediaBookmark(mediaID:ready.id,position:2,note:"Главный тезис — вернуться к этому определению"))
        let speech = ScriptedSpeech()
        let vm = MediaViewModel(root:root,speech:speech)
        await vm.reload()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene:scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.rootViewController = UIHostingController(rootView:MediaRoot().environmentObject(vm))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(500))
        attach(window,name:"Library")
        window.rootViewController = UIHostingController(rootView:NavigationStack { MediaDetail(item:ready) }.environmentObject(vm))
        window.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(500))
        attach(window,name:"Bookmarks")
        speech.status = SpeechReadiness(permission:.denied,model:.missing,legacy:.ready)
        await vm.checkSpeech()
        window.rootViewController = UIHostingController(rootView:MediaSettings().environmentObject(vm))
        window.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(500))
        attach(window,name:"Speech readiness")
    }

    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    var status = SpeechReadiness(permission:.authorized,model:.unsupportedSystem,legacy:.ready)
    var permissionRequests = 0
    var installRequests = 0
    var installDelay = Duration.milliseconds(20)
    var lateProgress: ((Double) -> Void)?
    var delayedLanguage = ""
    var probedLanguages: [String] = []

    func readiness(language: String) async -> SpeechReadiness {
        let snapshot = status
        probedLanguages.append(language)
        if language == delayedLanguage { try? await Task.sleep(for:.milliseconds(100)) }
        return snapshot
    }

    func requestPermission() async { permissionRequests += 1; status.permission = .authorized }

    func installModel(language: String, progress: @escaping (Double) -> Void) async throws {
        installRequests += 1
        status.model = .downloading
        lateProgress = progress
        progress(0.5)
        try await Task.sleep(for:installDelay)
        status.model = .installed
    }

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
