import SwiftUI
import UniformTypeIdentifiers

struct MediaSettings: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var deleting: MediaItem?
    @State private var pickBackup = false
    @State private var restoring: URL?
    @State private var backup: BackupFolder?
    var body: some View {
        NavigationStack {
            Form {
                Section("Приватность") {
                    Label("Медиа остаются на устройстве", systemImage: "lock.shield")
                    Label("Без сервера и облачного распознавания", systemImage: "network.slash")
                }
                Section("Сохранность данных") {
                    Button("Создать полную резервную копию",systemImage:"externaldrive.badge.plus") {
                        Task { if let url = await vm.createBackup() { backup = BackupFolder(url:url) } }
                    }.disabled(vm.busy || !vm.ready)
                    Button("Восстановить из папки копии",systemImage:"arrow.clockwise") { pickBackup = true }
                        .disabled(vm.busy || !vm.ready || !vm.items.isEmpty || !vm.trash.isEmpty)
                    Text("Копия включает медиа, расшифровки, конспекты, закладки и корзину. Сохрани папку целиком вне контейнера приложения через «Файлы». Восстановление — только в пустую библиотеку. Копия не зашифрована: выбирай доверенное место. Для подготовки понадобится дополнительное место размером с библиотеку.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Распознавание") {
                    Picker("Язык по умолчанию", selection: $vm.language) {
                        Text("Русский").tag("ru-RU")
                        Text("English").tag("en-US")
                    }.disabled(vm.busy)
                    SpeechReadinessView(expanded: true)
                    Text("Прогресс сохраняется каждые 45 секунд. При уходе в фон обработка останавливается; продолжить можно на экране записи. Во время работы экран остаётся включённым.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if vm.trash.isEmpty { Label("Корзина пуста", systemImage: "trash").foregroundStyle(.secondary) }
                    ForEach(vm.trash) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            HStack {
                                Button("Восстановить") { Task { await vm.restore(item) } }.buttonStyle(.bordered)
                                Spacer()
                                Button(role: .destructive) { deleting = item } label: { Label("Удалить", systemImage: "trash") }.buttonStyle(.bordered)
                            }.disabled(vm.busy)
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Корзина · \(vm.trash.count)") } footer: {
                    Text("Файлы и расшифровки в корзине сохраняются до удаления навсегда и занимают место на устройстве.")
                }
                Section("О приложении") {
                    Text("Бета-версия · проверяй резервные копии до удаления исходных файлов").font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("MediaMind", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                    Text("Импорт: медиа до 2 ГБ, SRT/VTT до 10 МБ. Данные хранятся локально. Для переноса расшифровки используй экспорт в SRT, VTT или TXT.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .sheet(item:$backup) { folder in BackupFolderExporter(url:folder.url) { backup = nil } }
            .fileImporter(isPresented:$pickBackup,allowedContentTypes:[.folder],allowsMultipleSelection:false) { result in
                switch result {
                case .success(let urls): restoring = urls.first
                case .failure(let error): vm.errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("Восстановить библиотеку из копии?",isPresented:Binding(get:{ restoring != nil },set:{ if !$0 { restoring = nil } }),titleVisibility:.visible) {
                Button("Проверить и восстановить") { if let restoring { vm.restoreBackup(restoring) }; restoring = nil }
            } message: { Text("Сначала будут проверены база, состав и контрольные суммы всех файлов. Не закрывай приложение до завершения.") }
            .confirmationDialog("Удалить навсегда?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
                Button("Удалить файл и расшифровку", role: .destructive) {
                    Task { await vm.removePermanently(item) }
                    deleting = nil
                }
                Button("Отмена", role: .cancel) { deleting = nil }
            } message: { _ in Text("После этого восстановить запись из корзины будет невозможно.") }
            .task { await vm.reload() }
        }
    }
}

private struct BackupFolder: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct BackupFolderExporter: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(url:url,finished:finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting:[url],asCopy:true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let url: URL
        let finished: () -> Void
        init(url: URL, finished: @escaping () -> Void) { self.url = url; self.finished = finished }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { complete() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete() }
        private func complete() { try? FileManager.default.removeItem(at:url); finished() }
    }
}
