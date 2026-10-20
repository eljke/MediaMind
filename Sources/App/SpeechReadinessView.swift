import SwiftUI

struct SpeechReadinessView: View {
    @EnvironmentObject private var vm: MediaViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded: Bool
    @State private var download = false

    init(expanded: Bool = false) { _expanded = State(initialValue: expanded) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let status = vm.speechReadiness {
                    LabeledContent("SpeechAnalyzer", value: model(status.model))
                    LabeledContent("SFSpeechRecognizer", value: legacy(status.legacy))
                    LabeledContent("Разрешение SFSpeechRecognizer", value: permission(status.permission))
                    if let issue = status.issue { Text(reason(issue)).font(.footnote) }
                    Text("SpeechAnalyzer работает локально и не требует разрешения старого движка. Доступность внутри LiveContainer подтверждается пробным распознаванием на устройстве.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if status.permission == .notRequested && status.engine != .analyzer {
                        Button("Разрешить старый движок") { vm.requestSpeechPermission() }.frame(minHeight: 44)
                    }
                    if status.permission == .denied || status.permission == .restricted,
                       let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Открыть настройки приложения", destination: settings).frame(minHeight: 44)
                    }
                    if status.canInstall {
                        Button(status.model == .downloading ? "Повторить запрос загрузки" : "Загрузить модель SpeechAnalyzer") { download = true }.frame(minHeight: 44)
                    }
                } else { Text("Поддержка языка ещё не проверена").font(.footnote).foregroundStyle(.secondary) }
                Button { Task { await vm.checkSpeech() } } label: {
                    HStack { if vm.checkingSpeech { ProgressView() }; Text("Обновить проверку") }.frame(minHeight: 44)
                }
            }.font(.subheadline).padding(.top, 8).disabled(vm.busy)
        } label: {
            Label(vm.speechReadiness?.engine.map { "Движок: \($0.rawValue)" } ?? "Проверка офлайн-распознавания", systemImage: vm.speechReadiness?.engine == nil ? "waveform.badge.exclamationmark" : "checkmark.circle")
                .font(.subheadline).foregroundStyle(.primary).frame(minHeight: 44)
        }
        .task(id: vm.language) { await vm.checkSpeech() }
        .onChange(of: vm.busy) { _, busy in if !busy { Task { await vm.checkSpeech() } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await vm.checkSpeech() } } }
        .confirmationDialog("Загрузить модель языка?", isPresented: $download, titleVisibility: .visible) {
            Button("Загрузить модель") { vm.installSpeechModel() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Нужны интернет и свободное место. iOS загрузит модель с серверов Apple; аудио и видео не отправляются. Система может продолжить или повторить загрузку после закрытия приложения.")
        }
    }

    private func model(_ value: SpeechReadiness.Model) -> String {
        switch value {
        case .unsupportedSystem: return "Нужна iOS 26 или новее"
        case .unsupportedDevice: return "Недоступен на устройстве"
        case .unsupportedLanguage: return "Язык не поддерживается"
        case .missing: return "Модель не установлена"
        case .downloading: return "Загрузка или ожидание сети"
        case .installed: return "Модель установлена"
        }
    }

    private func legacy(_ value: SpeechReadiness.Legacy) -> String {
        switch value {
        case .unsupportedLanguage: return "Язык не поддерживается"
        case .offlineUnavailable: return "Офлайн-режим недоступен"
        case .temporarilyUnavailable: return "Временно недоступен"
        case .ready: return "Поддерживает офлайн-режим"
        }
    }

    private func permission(_ value: SpeechReadiness.Permission) -> String {
        switch value {
        case .authorized: return "Разрешено"
        case .notRequested: return "Не запрошено"
        case .denied: return "Запрещено"
        case .restricted: return "Ограничено системой"
        }
    }

    private func reason(_ value: SpeechReadiness.Issue) -> String {
        switch value {
        case .permissionRequired: return "Разреши SFSpeechRecognizer или установи доступную модель SpeechAnalyzer. Проверка сама не запрашивает разрешения."
        case .permissionDenied: return "Доступ к старому движку запрещён. Его можно изменить в настройках; установленная модель SpeechAnalyzer работает отдельно."
        case .restricted: return "Доступ к старому движку ограничен iOS. Проверь ограничения устройства и LiveContainer."
        case .modelRequired: return "Для современного движка нужно отдельно загрузить модель выбранного языка."
        case .modelDownloading: return "iOS загружает модель или ожидает подходящих условий. Повтори проверку позже."
        case .unsupportedLanguage: return "Доступные движки не поддерживают выбранный язык. Можно выбрать другой язык или импортировать SRT/VTT."
        case .unavailable: return "Ни один движок пока не подтвердил офлайн-готовность. Обнови проверку; импорт SRT/VTT доступен независимо."
        }
    }
}
