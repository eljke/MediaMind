import Foundation

public struct SpeechReadiness: Equatable, Sendable {
    public enum Permission: Sendable { case notRequested, authorized, denied, restricted }
    public enum Model: Sendable { case unsupportedSystem, unsupportedDevice, unsupportedLanguage, missing, downloading, installed }
    public enum Legacy: Sendable { case unsupportedLanguage, offlineUnavailable, temporarilyUnavailable, ready }
    public enum Engine: String, Sendable { case analyzer = "SpeechAnalyzer", recognizer = "SFSpeechRecognizer" }
    public enum Issue: Sendable { case permissionRequired, permissionDenied, restricted, modelRequired, modelDownloading, unsupportedLanguage, unavailable }
    public var permission: Permission
    public var model: Model
    public var legacy: Legacy

    public init(permission: Permission, model: Model, legacy: Legacy) {
        self.permission = permission; self.model = model; self.legacy = legacy
    }

    public var engine: Engine? {
        if model == .installed { return .analyzer }
        if permission == .authorized && legacy == .ready { return .recognizer }
        return nil
    }

    public var canInstall: Bool { model == .missing || model == .downloading }

    public var issue: Issue? {
        if engine != nil { return nil }
        if legacy == .ready {
            switch permission {
            case .notRequested: return .permissionRequired
            case .denied: return .permissionDenied
            case .restricted: return .restricted
            case .authorized: break
            }
        }
        if model == .missing { return .modelRequired }
        if model == .downloading { return .modelDownloading }
        if model == .unsupportedLanguage && legacy == .unsupportedLanguage { return .unsupportedLanguage }
        return .unavailable
    }
}

extension TranscriptionCheckpoint {
    public func isValid(for duration: Double) -> Bool {
        duration.isFinite && duration > 0 && nextOffset.isFinite && nextOffset >= 0 && nextOffset <= duration &&
        segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration }
    }
}
