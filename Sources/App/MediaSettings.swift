import SwiftUI

struct MediaSettings: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var deleting: MediaItem?
    var body: some View {
        NavigationStack {
            Form {
                Section("Приватность") {
                    Label("Медиа остаются на устройстве", systemImage: "lock.shield")
                    Label("Без сервера и облачного распознавания", systemImage: "network.slash")
                }
                Section("Распознавание") {
                    Picker("Язык по умолчанию", selection: $vm.language) {
                        Text("Русский").tag("ru-RU")
                        Text("English").tag("en-US")
                    }.disabled(vm.busy)
                    Text("Apple Speech требует разрешения и доступной офлайн-модели языка. В LiveContainer доступность нужно проверить на устройстве. Импорт SRT/VTT работает независимо.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    LabeledContent("MediaMind", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                    Text("Импорт: медиа до 2 ГБ, SRT/VTT до 10 МБ. Данные хранятся локально. Для переноса расшифровки используй экспорт в SRT, VTT или TXT.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
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
