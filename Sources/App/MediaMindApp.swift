import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit

@main
struct MediaMindApp: App {
    @StateObject private var vm = MediaViewModel()
    var body: some Scene { WindowGroup { MediaRoot().environmentObject(vm) } }
}

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var results: [MediaHit] = []
    @Published var query = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var errorMessage: String?
    @Published var language = "ru-RU"
    private let db: MediaRepository?
    private let root: URL
    private let speech: TranscriptionService = AppleOfflineSpeech()
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaMind", isDirectory: true)
        do { db = try MediaRepository(url: root.appendingPathComponent("library.sqlite")) }
        catch { db = nil; errorMessage = "Ошибка открытия базы: \(error.localizedDescription)" }
    }
    func location(_ item: MediaItem) -> URL { root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(item.fileName) }
    func reload() async {
        guard let db else { return }
        do { items = try await db.all() }
        catch { errorMessage = error.localizedDescription }
    }
    func importMedia(_ source: URL) async {
        guard let db else { return }
        busy = true; defer { busy = false }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        do {
            let folder = root.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let extensionName = source.pathExtension.lowercased()
            guard ["m4a", "mp3", "mp4", "mov", "wav", "aac", "caf", "aiff", "m4v"].contains(extensionName) else {
                throw ImportError.unsupported
            }
            let fileName = "\(UUID().uuidString).\(extensionName)"
            let dst = folder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: source, to: dst)
            do {
                let asset = AVURLAsset(url: dst)
                let seconds = (try? await asset.load(.duration).seconds) ?? 0
                try await db.save(MediaItem(title: source.deletingPathExtension().lastPathComponent, fileName: fileName, duration: seconds.isFinite ? seconds : 0))
            } catch { try? FileManager.default.removeItem(at: dst); throw error }
            await reload()
        } catch { errorMessage = "Не удалось импортировать: \(error.localizedDescription)" }
    }
    func importSubtitle(_ url: URL, for item: MediaItem) async {
        guard let db else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let input = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ImportError.notText }
            let parts = Subtitles.decode(input)
            guard !parts.isEmpty else { throw ImportError.noCues }
            try await db.replaceSegments(parts, for: item.id)
            errorMessage = "Субтитры импортированы: \(parts.count) фрагментов"
            await runSearch()
        } catch { errorMessage = error.localizedDescription }
    }
    func segments(_ item: MediaItem) async -> [SpeechSegment] {
        (try? await db?.segments(for: item.id)) ?? []
    }
    func runSearch() async {
        guard let db else { return }
        do { results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try await db.search(query) }
        catch { errorMessage = error.localizedDescription }
    }
    func transcribe(_ item: MediaItem) async {
        guard let db else { return }
        busy = true; progress = 0; defer { busy = false }
        do {
            let parts = try await speech.transcribe(file: location(item), language: language) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            guard !parts.isEmpty else { throw SpeechServiceError.noResult }
            try await db.replaceSegments(parts, for: item.id)
            errorMessage = "Распознано \(parts.count) фрагментов"
            await runSearch()
        } catch { errorMessage = "Распознавание: \(error.localizedDescription)" }
    }
    func remove(_ item: MediaItem) async {
        guard let db else { return }
        do { try await db.remove(item.id); try? FileManager.default.removeItem(at: location(item)); await reload(); await runSearch() }
        catch { errorMessage = error.localizedDescription }
    }
    func export(_ item: MediaItem, format: String) async -> URL? {
        guard let db else { return nil }
        do {
            let parts = try await db.segments(for: item.id)
            guard !parts.isEmpty else { throw ImportError.noCues }
            let text = format == "srt" ? Subtitles.encodeSRT(parts) : (format == "vtt" ? Subtitles.encodeVTT(parts) : parts.map(\.text).joined(separator: "\n"))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaMind-\(item.id.uuidString).\(format)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    private enum ImportError: LocalizedError {
        case unsupported, notText, noCues
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Неподдерживаемый тип: MP3/M4A/MP4/MOV/WAV/AAC/CAF/AIFF"
            case .notText: return "Файл субтитров должен быть UTF-8 или UTF-16"
            case .noCues: return "Нет читаемых строк субтитров / расшифровки"
            }
        }
    }
}

struct MediaRoot: View {
    @EnvironmentObject private var vm: MediaViewModel
    var body: some View {
        TabView {
            MediaLibrary().tabItem { Label("Библиотека", systemImage: "play.rectangle.on.rectangle") }
            MediaSearchView().tabItem { Label("Поиск", systemImage: "text.magnifyingglass") }
            MediaSettings().tabItem { Label("Настройки", systemImage: "gearshape") }
        }.tint(.indigo)
        .alert("MediaMind", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button("Закрыть") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }
}

struct MediaLibrary: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var picker = false
    var body: some View {
        NavigationStack {
            Group {
                if vm.items.isEmpty {
                    ContentUnavailableView("Добавь первую запись", systemImage: "waveform", description: Text("Импортируй видео или аудио. Субтитры и расшифровки сохраняются локально."))
                } else {
                    List {
                        ForEach(vm.items) { item in
                            NavigationLink {
                                MediaDetail(item:item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.headline).lineLimit(2)
                                        Text(item.addedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3)
                            }
                            .swipeActions { Button(role: .destructive) { Task { await vm.remove(item) } } label: { Label("Удалить", systemImage: "trash") } }
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("MediaMind")
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { picker = true } label: { Label("Импорт", systemImage: "plus.circle.fill") } } }
            .fileImporter(isPresented:$picker, allowedContentTypes:[.audio,.movie,.video,.mpeg4Movie], allowsMultipleSelection:false) { result in
                if case .success(let urls) = result, let url=urls.first { Task { await vm.importMedia(url) } }
                if case .failure(let err) = result { vm.errorMessage=err.localizedDescription }
            }
            .overlay { if vm.busy { ProgressView("Обработка").padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)) } }
            .task { await vm.reload() }
        }
    }
}

struct MediaDetail: View {
    @EnvironmentObject private var vm: MediaViewModel
    let item: MediaItem
    @State private var segments: [SpeechSegment] = []
    @State private var player: AVPlayer?
    @State private var pickSubtitle = false
    @State private var shareURL: URL?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let player { VideoPlayer(player:player).frame(height:220).clipShape(RoundedRectangle(cornerRadius:14)) }
                Text(item.title).font(.title3.bold())
                Picker("Язык",selection:$vm.language) {
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                }.pickerStyle(.segmented)
                HStack {
                    Button { pickSubtitle = true } label: { Label("Импорт SRT/VTT",systemImage:"text.badge.plus") }.buttonStyle(.bordered)
                    Button { Task { await vm.transcribe(item); segments = await vm.segments(item) } } label: { Label("Офлайн-речь",systemImage:"waveform") }.buttonStyle(.borderedProminent).disabled(vm.busy)
                }.font(.caption)
                if vm.busy { ProgressView(value:vm.progress).accessibilityLabel("Прогресс расшифровки") }
                if !segments.isEmpty {
                    HStack {
                        Text("Расшифровка · \(segments.count)").font(.headline)
                        Spacer()
                        Menu("Экспорт") {
                            ForEach(["srt","vtt","txt"],id:\.self) { format in
                                Button(format.uppercased()) { Task { shareURL = await vm.export(item,format:format) } }
                            }
                        }
                    }
                    ForEach(segments) { seg in
                        Button {
                            player?.seek(to: CMTime(seconds:seg.start,preferredTimescale:600))
                            player?.play()
                        } label: {
                            HStack(alignment:.top,spacing:12) {
                                Text(Self.time(seg.start)).font(.caption.monospacedDigit()).foregroundStyle(.indigo).frame(width:56,alignment:.leading)
                                Text(seg.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength:0)
                            }.padding(.vertical,7)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                } else { ContentUnavailableView("Нет расшифровки",systemImage:"text.bubble",description:Text("Импортируй субтитры или попробуй локальное распознавание речи")) }
            }.padding()
        }
        .navigationTitle("Медиа").navigationBarTitleDisplayMode(.inline)
        .task { player=AVPlayer(url: vm.location(item)); segments=await vm.segments(item) }
        .onDisappear { player?.pause() }
        .fileImporter(isPresented:$pickSubtitle,allowedContentTypes:[UTType(filenameExtension:"srt") ?? .plainText,UTType(filenameExtension:"vtt") ?? .plainText,.plainText],allowsMultipleSelection:false) { result in
            if case .success(let urls)=result,let url=urls.first { Task { await vm.importSubtitle(url,for:item); segments=await vm.segments(item) } }
            if case .failure(let err)=result { vm.errorMessage=err.localizedDescription }
        }
        .sheet(item:Binding(get: { shareURL.map { SharedFile(url:$0) } },set: { if $0 == nil { shareURL=nil } })) { value in
            NavigationStack { ShareLink(item:value.url) { Label("Сохранить или отправить",systemImage:"square.and.arrow.up") }.padding().navigationTitle("Экспорт").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Закрыть") { shareURL=nil } } } }
        }
    }
    static func time(_ seconds:Double)->String { let n=Int(seconds); return String(format:"%02d:%02d:%02d",n/3600,n/60%60,n%60) }
    private struct SharedFile:Identifiable { let url:URL; var id:String { url.absoluteString } }
}

struct MediaSearchView: View {
    @EnvironmentObject private var vm:MediaViewModel
    var body:some View {
        NavigationStack {
            Group {
                if vm.query.isEmpty { ContentUnavailableView("Поиск по записям",systemImage:"text.magnifyingglass",description:Text("Найди слово в расшифровке и перейди к точному времени")) }
                else if vm.results.isEmpty { ContentUnavailableView.search(text:vm.query) }
                else {
                    List(vm.results) { hit in
                        NavigationLink { MediaDetail(item:hit.item) } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text(hit.item.title).font(.headline)
                                Text(hit.segment.text).lineLimit(3)
                                Text(MediaDetail.time(hit.segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }.navigationTitle("Найти момент").searchable(text:$vm.query,prompt:"Например: аккумулятор")
                .task(id:vm.query) { await vm.runSearch() }
        }
    }
}

struct MediaSettings:View {
    var body:some View {
        NavigationStack {
            Form {
                Section("Работа на устройстве") {
                    Label("Без облачной отправки медиа",systemImage:"lock.shield")
                    Label("Расшифровка по фрагментам до 45 секунд",systemImage:"square.stack")
                    Label("Файлы и SQLite в локальном хранилище",systemImage:"internaldrive")
                }
                Section("Важно") {
                    Text("Apple Speech требует доступности офлайн-модели выбранного языка и разрешения. Если движок недоступен внутри LiveContainer, импорт SRT/VTT работает независимо.")
                    Text("Для длинных роликов держи приложение открытым и разблокированным. При удалении медиа вместе с ним удаляется расшифровка.")
                }.font(.footnote)
            }.navigationTitle("Настройки")
        }
    }
}
