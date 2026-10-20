import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct MediaLibrary: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var picker = false
    @State private var sourcePicker = false
    @State private var photoPicker = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var renaming: MediaItem?
    @State private var title = ""
    var body: some View {
        NavigationStack {
            Group {
                if !vm.ready {
                    ContentUnavailableView {
                        Label("Открытие библиотеки", systemImage: "internaldrive")
                    } actions: {
                        Button("Повторить") { Task { await vm.reload() } }.buttonStyle(.bordered)
                    }
                } else if vm.items.isEmpty {
                    ContentUnavailableView {
                        Label("Найди нужный момент", systemImage: "waveform")
                    } description: {
                        Text("Добавь аудио или видео, затем субтитры SRT/VTT или офлайн-расшифровку. Файлы останутся на устройстве.")
                    } actions: {
                        Button("Добавить запись") { sourcePicker = true }.buttonStyle(.borderedProminent).disabled(vm.busy)
                    }
                } else {
                    List {
                        if !vm.continuing.isEmpty {
                            Section("Продолжить прослушивание") {
                                ForEach(vm.continuing) { item in
                                    NavigationLink { MediaDetail(item: item, initialTime: vm.overview[item.id]?.playback?.position) } label: {
                                        MediaLibraryRow(item: item, overview: vm.overview[item.id] ?? MediaOverview(), activity: vm.operationItemID == item.id ? vm.operationTitle : nil, showProgress: true)
                                    }
                                }
                            }
                        }
                        Section {
                            ForEach(vm.items) { item in
                                NavigationLink { MediaDetail(item: item) } label: {
                                    MediaLibraryRow(item: item, overview: vm.overview[item.id] ?? MediaOverview(), activity: vm.operationItemID == item.id ? vm.operationTitle : nil)
                                }
                                .swipeActions(allowsFullSwipe: false) {
                                    Button(role: .destructive) { Task { await vm.moveToTrash(item) } } label: { Label("В корзину", systemImage: "trash") }
                                        .disabled(vm.busy)
                                }
                                .contextMenu {
                                    Button("Переименовать", systemImage: "pencil") { title = item.title; renaming = item }.disabled(vm.busy)
                                    Button("В корзину", systemImage: "trash", role: .destructive) { Task { await vm.moveToTrash(item) } }.disabled(vm.busy)
                                }
                            }
                        } header: { Text("Записей: \(vm.items.count)") }
                    }.listStyle(.insetGrouped).refreshable { await vm.reload() }
                }
            }
            .navigationTitle("MediaMind")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sourcePicker = true } label: { Label("Добавить запись", systemImage: "plus.circle.fill") }.disabled(vm.busy || !vm.ready)
                }
            }
            .confirmationDialog("Откуда добавить запись?", isPresented: $sourcePicker, titleVisibility: .visible) {
                Button("Видео из Фото") { photoPicker = true }
                Button("Аудио или видео из Файлов") { picker = true }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("MOV, MP4, M4V и аудио до 2 ГБ. Формат проверяется после выбора.")
            }
            .photosPicker(isPresented: $photoPicker, selection: $selectedVideo, matching: .videos, preferredItemEncoding: .current)
            .onChange(of: selectedVideo) { _, selection in
                guard let selection else { return }
                photoPicker = false
                vm.importVideo(selection)
                selectedVideo = nil
            }
            // File providers may expose a playable MOV as generic data rather than a movie UTI.
            .fileImporter(isPresented: $picker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { vm.importMedia(url) }
                case .failure(let error): vm.errorMessage = error.localizedDescription
                }
            }
            .alert("Название записи", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
                TextField("Название", text: $title)
                Button("Сохранить") {
                    Task { await vm.rename(item, title: title) }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
            .task { await vm.reload() }
        }
    }
}
