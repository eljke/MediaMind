import XCTest
@testable import MediaMindCore

final class SpeechReadinessTests: XCTestCase {
    func testRussianDictationFallback() {
        for permission in [SpeechReadiness.Permission.notRequested,.authorized,.denied,.restricted] {
            var status = SpeechReadiness(permission:permission,model:.unsupportedLanguage,legacy:.offlineUnavailable,dictation:.missing)
            XCTAssertNil(status.engine)
            XCTAssertEqual(status.installationEngine,.dictation)
            XCTAssertEqual(status.issue,.modelRequired)
            status.dictation = .downloading
            XCTAssertEqual(status.issue,.modelDownloading)
            status.dictation = .installed
            XCTAssertEqual(status.engine,.dictation)
            XCTAssertNil(status.issue)
            XCTAssertFalse(status.canInstall)
        }
    }

    func testModernAndLegacyRemainAvailable() {
        var status = SpeechReadiness(permission:.authorized,model:.installed,legacy:.ready,dictation:.installed)
        XCTAssertEqual(status.engine,.analyzer)
        status.model = .unsupportedDevice
        XCTAssertEqual(status.engine,.dictation)
        status.dictation = .missing
        XCTAssertEqual(status.engine,.recognizer)
        XCTAssertEqual(status.installationEngine,.dictation)
        status.model = .missing
        XCTAssertEqual(status.installationEngine,.analyzer)
    }

    func testModernNeedsNoLegacyPermission() {
        for permission in [SpeechReadiness.Permission.notRequested, .denied, .restricted, .authorized] {
            let status = SpeechReadiness(permission:permission,model:.installed,legacy:.offlineUnavailable)
            XCTAssertEqual(status.engine,.analyzer)
            XCTAssertNil(status.issue)
            XCTAssertFalse(status.canInstall)
        }
    }

    func testLegacyRequiresPermission() {
        var status = SpeechReadiness(permission:.notRequested,model:.unsupportedSystem,legacy:.ready)
        XCTAssertEqual(status.issue,.permissionRequired)
        XCTAssertNil(status.engine)
        status.permission = .denied
        XCTAssertEqual(status.issue,.permissionDenied)
        status.permission = .restricted
        XCTAssertEqual(status.issue,.restricted)
        status.permission = .authorized
        XCTAssertEqual(status.engine,.recognizer)
        XCTAssertNil(status.issue)
    }

    func testDownloadKeepsOfflineFallback() {
        var status = SpeechReadiness(permission:.authorized,model:.missing,legacy:.ready)
        XCTAssertEqual(status.engine,.recognizer)
        XCTAssertTrue(status.canInstall)
        status.legacy = .offlineUnavailable
        XCTAssertEqual(status.issue,.modelRequired)
        status.model = .downloading
        XCTAssertEqual(status.issue,.modelDownloading)
        XCTAssertTrue(status.canInstall)
        XCTAssertNil(status.engine)
    }

    func testUnsupportedAndUnavailableDiffer() {
        var status = SpeechReadiness(permission:.authorized,model:.unsupportedLanguage,legacy:.unsupportedLanguage)
        XCTAssertEqual(status.issue,.unsupportedLanguage)
        status.legacy = .temporarilyUnavailable
        XCTAssertEqual(status.issue,.unavailable)
        XCTAssertNil(status.engine)
        XCTAssertFalse(status.canInstall)
    }

    func testCheckpointBounds() throws {
        let old = Data(#"{"language":"ru-RU","nextOffset":45,"segments":[{"id":"00000000-0000-0000-0000-000000000001","start":1,"end":2,"text":"Текст"}]}"#.utf8)
        var checkpoint = try JSONDecoder().decode(TranscriptionCheckpoint.self,from:old)
        XCTAssertTrue(checkpoint.isValid(for:90))
        for offset in [-1,91,Double.nan,Double.infinity] {
            checkpoint.nextOffset = offset
            XCTAssertFalse(checkpoint.isValid(for:90))
        }
        checkpoint.nextOffset = 90
        XCTAssertTrue(checkpoint.isValid(for:90))
        checkpoint.segments[0].end = 91
        XCTAssertFalse(checkpoint.isValid(for:90))
        XCTAssertFalse(checkpoint.isValid(for:Double.nan))
    }
}
