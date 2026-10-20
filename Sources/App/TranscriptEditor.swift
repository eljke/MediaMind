import SwiftUI

struct TranscriptDraft: Identifiable {
    let original: [SpeechSegment]
    let proposed: [SpeechSegment]
    let segment: SpeechSegment
    var id: UUID { segment.id }
}

struct TranscriptEditor: View {
    @EnvironmentObject private var vm: MediaViewModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let draft: TranscriptDraft
    @State private var text: String
    @State private var saving = false
    @State private var discard = false
    @State private var resetRecognition = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool
    private var dirty: Bool { text != draft.segment.text || draft.original.count != draft.proposed.count }

    init(item: MediaItem, draft: TranscriptDraft) {
        self.item = item; self.draft = draft
        _text = State(initialValue:draft.segment.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Временные отметки сохраняются") {
                    Text("\(MediaTime.label(draft.segment.start)) — \(MediaTime.label(draft.segment.end))").monospacedDigit()
                }
                Section {
                    TextEditor(text:$text).frame(minHeight:220).focused($focused).accessibilityLabel("Текст расшифровки")
                    Text("\(text.count) / \(TranscriptEditing.textLimit)").font(.caption).foregroundStyle(.secondary)
                } footer: { Text("Заметки и закладки останутся на своих временных отметках. Последнее изменение текста можно отменить.") }
            }
            .navigationTitle(draft.original.count == draft.proposed.count ? "Исправить текст" : "Объединить фрагменты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Отмена") { if dirty { discard = true } else { dismiss() } }.disabled(saving) }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Сохранить") { save(discardPending:false) }.disabled(saving || !dirty || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.count > TranscriptEditing.textLimit)
                }
            }
            .interactiveDismissDisabled(saving || dirty)
            .confirmationDialog("Не сохранять изменения?",isPresented:$discard,titleVisibility:.visible) {
                Button("Не сохранять",role:.destructive) { dismiss() }
                Button("Продолжить редактирование",role:.cancel) {}
            }
            .confirmationDialog("Сбросить незавершённое распознавание?",isPresented:$resetRecognition,titleVisibility:.visible) {
                Button("Сохранить текст и сбросить прогресс",role:.destructive) { save(discardPending:true) }
                Button("Продолжить редактирование",role:.cancel) {}
            } message: { Text("Сохранённые фрагменты незавершённого распознавания будут удалены. Отмена изменения текста не восстановит этот прогресс.") }
            .alert("Не удалось сохранить текст",isPresented:Binding(get: { errorMessage != nil },set: { if !$0 { errorMessage = nil } })) {
                Button("Закрыть") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task { focused = true }
        }
    }

    private func save(discardPending: Bool) {
        saving = true
        Task {
            defer { saving = false }
            do {
                let updated = try TranscriptEditing.replaceText(in:draft.proposed,id:draft.id,text:text)
                try await vm.reviseTranscript(item,previous:draft.original,updated:updated,discardPending:discardPending)
                dismiss()
            } catch TranscriptEditing.Error.pendingRecognition { resetRecognition = true }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
