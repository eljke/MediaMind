import SwiftUI

struct MediaSummaryView: View {
    @EnvironmentObject private var vm: MediaViewModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var source: [SpeechSegment] = []
    @State private var summarySource: [SpeechSegment] = []
    @State private var text = ""
    @State private var saved = ""
    @State private var stale = false
    @State private var loading = true
    @State private var failed = false
    @State private var saving = false
    @State private var discard = false
    @State private var regenerate = false
    @State private var error: String?
    @State private var exportURL: URL?
    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Загрузка конспекта") }
                Section {
                    Text("Локальная подборка фрагментов с таймкодами. Отредактируй её своими словами; это не автоматическое изложение смысла записи.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if stale { Label("Расшифровка изменилась после создания конспекта",systemImage:"exclamationmark.triangle").font(.footnote) }
                    TextEditor(text:$text).frame(minHeight:300).accessibilityLabel("Текст конспекта")
                    Text("\(text.count) / \(MediaSummary.textLimit)").font(.caption).foregroundStyle(text.count > MediaSummary.textLimit ? .red : .secondary)
                    Button("Подобрать фрагменты заново") { regenerate = true }.disabled(source.isEmpty)
                }.disabled(loading || failed || saving)
                Section("Фрагменты исходной расшифровки") {
                    ForEach(references) { segment in
                        NavigationLink {
                            MediaDetail(item:item,initialTime:segment.start).environmentObject(vm)
                        } label: { Text("\(MediaTime.label(segment.start)) · \(String(segment.text.prefix(120)))").lineLimit(3) }
                    }
                }
                Section("Экспорт") {
                    ForEach(["md","txt"],id:\.self) { format in
                        Button("Экспорт \(format.uppercased())") { export(format) }.disabled(text.isEmpty || text.count > MediaSummary.textLimit || loading || failed)
                    }
                    if let exportURL { ShareLink(item:exportURL) { Label("Сохранить или отправить",systemImage:"square.and.arrow.up") } }
                }
            }
            .navigationTitle("Конспект")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { if text != saved { discard = true } else { dismiss() } }.disabled(saving) }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Сохранить") { Task { await save() } }.disabled(loading || failed || saving || vm.busy || text == saved || text.count > MediaSummary.textLimit)
                }
            }
            .interactiveDismissDisabled(text != saved || saving)
            .confirmationDialog("Закрыть без сохранения?",isPresented:$discard,titleVisibility:.visible) {
                Button("Не сохранять",role:.destructive) { dismiss() }
            }
            .confirmationDialog("Заменить текст подборкой фрагментов?",isPresented:$regenerate,titleVisibility:.visible) {
                Button("Заменить") { text = MediaSummary.draft(from:source).text; summarySource = source; stale = false }
            }
            .alert("Не удалось выполнить действие",isPresented:Binding(get:{ error != nil },set:{ if !$0 { error = nil } })) { Button("Закрыть") {} } message: { Text(error ?? "") }
            .task {
                do {
                    source = await vm.segments(item)
                    if let value = try await vm.summary(item) { text = value.text; saved = value.text; summarySource = value.source; stale = value.source != source }
                    else { text = MediaSummary.draft(from:source).text; summarySource = source }
                } catch { self.error = error.localizedDescription; failed = true }
                loading = false
            }
        }
    }
    private var references: [SpeechSegment] {
        let count = min(12,source.count)
        return (0..<count).map { source[$0 * source.count / count] }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do { try await vm.saveSummary(MediaSummary(text:text,source:summarySource),for:item); saved = text; dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func export(_ format: String) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaMind-summary-\(item.id).\(format)")
            try (item.title + "\n\n" + text + "\n").write(to:url,atomically:true,encoding:.utf8)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
