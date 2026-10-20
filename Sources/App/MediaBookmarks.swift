import SwiftUI

struct MediaBookmarks: View {
    @EnvironmentObject private var vm: MediaViewModel
    let item: MediaItem
    let canAdd: Bool
    let currentPosition: () -> Double
    let seek: (Double) -> Void
    @State private var bookmarks: [MediaBookmark] = []
    @State private var editing: MediaBookmark?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Закладки · \(bookmarks.count)").font(.headline)
                Spacer()
                Button {
                    editing = MediaBookmark(mediaID: item.id, position: currentPosition())
                } label: { Label("Добавить", systemImage: "bookmark.badge.plus").frame(minHeight: 44) }
                    .disabled(!canAdd).accessibilityHint("Сохранить текущий момент записи с заметкой")
            }
            if loading && bookmarks.isEmpty { ProgressView("Загрузка закладок") }
            else if bookmarks.isEmpty {
                Text("Сохрани важный момент, чтобы вернуться к нему позже. Заметку можно оставить пустой.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(bookmarks) { bookmark in
                HStack(alignment: .top, spacing: 8) {
                    Button { seek(bookmark.position) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(MediaDetail.time(bookmark.position), systemImage: "bookmark.fill").font(.caption.monospacedDigit()).foregroundStyle(.indigo)
                            Text(bookmark.note.isEmpty ? "Без заметки" : bookmark.note).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(4)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityHint("Воспроизвести с этой закладки")
                    Menu {
                        Button("Изменить заметку", systemImage: "pencil") { editing = bookmark }
                        Button("Удалить закладку", systemImage: "trash", role: .destructive) { Task { await vm.removeBookmark(bookmark) } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("Действия с закладкой на \(MediaDetail.time(bookmark.position))")
                }.padding(12).background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: vm.bookmarkRevision) {
            loading = true
            bookmarks = await vm.bookmarks(item)
            loading = false
        }
        .sheet(item: $editing) { bookmark in BookmarkEditor(bookmark: bookmark).environmentObject(vm) }
    }
}

private struct BookmarkEditor: View {
    @EnvironmentObject private var vm: MediaViewModel
    @Environment(\.dismiss) private var dismiss
    let bookmark: MediaBookmark
    @State private var note: String
    @State private var saving = false
    @State private var discard = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(bookmark: MediaBookmark) {
        self.bookmark = bookmark
        _note = State(initialValue: bookmark.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Момент записи") { Label(MediaDetail.time(bookmark.position), systemImage: "bookmark.fill") }
                Section {
                    TextEditor(text: $note).frame(minHeight: 140).focused($focused).accessibilityLabel("Заметка к закладке")
                    Text("\(note.count) / \(MediaBookmark.noteLimit)").font(.caption)
                        .foregroundStyle(note.count > MediaBookmark.noteLimit ? Color.red : Color.secondary)
                } header: { Text("Заметка") } footer: { Text("Сохраняется только на этом устройстве.") }
            }
            .navigationTitle("Закладка").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { if note != bookmark.note { discard = true } else { dismiss() } }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        saving = true
                        Task {
                            var updated = bookmark; updated.note = note
                            do { try await vm.saveBookmark(updated); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving || note.count > MediaBookmark.noteLimit)
                }
            }
            .interactiveDismissDisabled(saving || note != bookmark.note)
            .confirmationDialog("Не сохранять изменения?", isPresented: $discard, titleVisibility: .visible) {
                Button("Не сохранять", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
            .alert("Не удалось сохранить закладку", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Закрыть") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task { focused = true }
        }
    }
}
