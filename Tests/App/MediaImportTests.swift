#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import MediaMind

@MainActor
final class MediaImportTests: XCTestCase {
    func testMovieTypeFiltering() {
        XCTAssertTrue(UTType.quickTimeMovie.conforms(to: .movie))
        XCTAssertEqual(UTType(mimeType: "video/quicktime"), .quickTimeMovie)
        XCTAssertTrue(UTType.quickTimeMovie.conforms(to: .data))
        XCTAssertFalse(UTType.data.conforms(to: .movie))
    }

    func testVideoExtensions() async throws {
        let folder = try temporaryFolder()
        let vm = MediaViewModel(root: folder.appendingPathComponent("library"))
        await vm.reload()
        let mov = try await movie(at: folder.appendingPathComponent("original.mov"), type: .mov)
        let mp4 = try await movie(at: folder.appendingPathComponent("original.mp4"), type: .mp4)
        for (index, ext) in ["mov", "MOV", "MoV", "mp4", "MP4", "m4v", "M4V"].enumerated() {
            let source = folder.appendingPathComponent("export_1792506531523-\(index).\(ext)")
            try FileManager.default.copyItem(at: ext.lowercased() == "mov" ? mov : mp4, to: source)
            try await vm.storeMedia(source)
            let item = try XCTUnwrap(vm.items.first(where: { $0.title == source.deletingPathExtension().lastPathComponent }))
            XCTAssertGreaterThan(item.duration, 0)
            let playable = try await AVURLAsset(url: vm.location(item)).load(.isPlayable)
            XCTAssertTrue(playable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
        XCTAssertEqual(vm.items.count, 7)
        let reopened = MediaViewModel(root: folder.appendingPathComponent("library"))
        await reopened.reload()
        XCTAssertEqual(reopened.items.count, 7)
    }

    func testPhotoFileLifetime() async throws {
        let folder = try temporaryFolder()
        let source = try await movie(at: folder.appendingPathComponent("From Photos.MOV"), type: .mov)
        var video: ImportedVideo? = try await ImportedVideo.copy(from: source)
        let staged = try XCTUnwrap(video?.file)
        try FileManager.default.removeItem(at: source)
        let vm = MediaViewModel(root: folder.appendingPathComponent("library"))
        await vm.reload()
        try await vm.storeMedia(staged, title: video?.title)
        video = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let item = try XCTUnwrap(vm.items.first)
        XCTAssertEqual(item.title, "From Photos")
        let playable = try await AVURLAsset(url: vm.location(item)).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testInvalidVideoIsNotStored() async throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("fake.MOV")
        try Data("This is not a video".utf8).write(to: source)
        let vm = MediaViewModel(root: folder.appendingPathComponent("library"))
        await vm.reload()
        do {
            try await vm.storeMedia(source)
            XCTFail("Invalid media must fail")
        } catch {}
        XCTAssertTrue(vm.items.isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("library/files").path)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAudioImport() async throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("Audio.WAV")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = 0 }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let vm = MediaViewModel(root: folder.appendingPathComponent("library"))
        await vm.reload()
        try await vm.storeMedia(source)
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.duration ?? 0, 1, accuracy: 0.1)
    }

    func testUnsupportedFileIsNotCopied() async throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("document.txt")
        try Data("Text".utf8).write(to: source)
        let vm = MediaViewModel(root: folder.appendingPathComponent("library"))
        await vm.reload()
        do {
            try await vm.storeMedia(source)
            XCTFail("Unsupported extensions must fail")
        } catch MediaFileImport.ImportError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("library/files").path))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func movie(at url: URL, type: AVFileType) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaFileImport.ImportError.unreadable }
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        memset(base, 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? MediaFileImport.ImportError.unreadable }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaFileImport.ImportError.unreadable }
        return url
    }
}
#endif
