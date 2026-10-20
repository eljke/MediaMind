import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct MediaDetail: View {
    @EnvironmentObject private var vm: MediaViewModel
    let item: MediaItem
    var initialTime: Double? = nil
    @StateObject private var playback = MediaPlayback()
    @State private var segments: [SpeechSegment] = []
    @State private var checkpoint: TranscriptionCheckpoint?
    @State private var loading = true
    @State private var pickSubtitle = false
    @State private var shareURL: URL?
    @State private var query = ""
    @State private var confirmation: Replacement?
    private enum Replacement: String, Identifiable {
        case subtitles, speech
        var id: String { rawValue }
    }
    private var visibleSegments: [SpeechSegment] {
        let query = MediaSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return query.isEmpty ? segments : segments.filter { MediaSearch.normalized($0.text).contains(query) }
    }
    private var title: String { vm.items.first(where: { $0.id == item.id })?.title ?? item.title }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let player = playback.player {
                        VideoPlayer(player: player).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if let error = playback.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else { ProgressView("Открытие записи").frame(maxWidth: .infinity, minHeight: 140) }
                    Text(title).font(.title2.bold()).textSelection(.enabled)
                    HStack {
                        Text("\(Self.time(playback.position)) / \(Self.time(item.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                                Button("\(rate.formatted())×") { playback.setRate(Float(rate)) }
                            }
                        } label: { Label("\(Double(playback.rate).formatted())×", systemImage: "speedometer").frame(minHeight: 44) }
                        .accessibilityLabel("Скорость воспроизведения")
                    }
                    Picker("Язык распознавания", selection: $vm.language) {
                        Text("Русский").tag("ru-RU")
                        Text("English").tag("en-US")
                    }.pickerStyle(.segmented).disabled(vm.busy)
                    VStack(spacing: 10) {
                        Button {
                            if segments.isEmpty && checkpoint == nil { pickSubtitle = true }
                            else { confirmation = .subtitles }
                        } label: { Label("Импортировать SRT / VTT", systemImage: "text.badge.plus").frame(maxWidth: .infinity, minHeight: 36) }
                            .buttonStyle(.bordered)
                        Button {
                            if checkpoint?.language == vm.language { vm.transcribe(item) }
                            else if segments.isEmpty && checkpoint == nil { vm.transcribe(item) }
                            else { confirmation = .speech }
                        } label: {
                            Label(checkpoint?.language == vm.language ? "Продолжить распознавание" : "Распознать офлайн", systemImage: "waveform")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.borderedProminent)
                    }.disabled(vm.busy || !vm.ready || loading)
                    if let checkpoint {
                        Label("Сохранено до \(Self.time(checkpoint.nextOffset)) · \(checkpoint.language == "ru-RU" ? "Русский" : "English")", systemImage: "pause.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                        if checkpoint.language != vm.language {
                            Text("При смене языка распознавание начнётся заново.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !segments.isEmpty {
                        HStack {
                            Text("Расшифровка · \(segments.count)").font(.headline)
                            Spacer()
                            Menu {
                                ForEach(["srt", "vtt", "txt"], id: \.self) { format in
                                    Button(format.uppercased()) { Task { shareURL = await vm.export(item, format: format) } }
                                }
                            } label: { Label("Экспорт", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        }
                        if visibleSegments.isEmpty { ContentUnavailableView.search(text: query) }
                        ForEach(visibleSegments) { segment in
                            Button { playback.seek(segment.start) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(Self.time(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.indigo)
                                    Text(segment.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(12)
                                .background(playback.position >= segment.start && playback.position < segment.end ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Self.time(segment.start)). \(segment.text)")
                            .accessibilityHint("Воспроизвести с этого момента")
                            .id(segment.id)
                        }
                    } else if loading { ProgressView("Загрузка расшифровки") }
                    else {
                        ContentUnavailableView("Нет расшифровки", systemImage: "text.bubble", description: Text("Импортируй субтитры или попробуй локальное распознавание речи. Интернет для распознавания не используется."))
                    }
                }.padding()
            }
            .task(id: vm.revision) {
                loading = true
                segments = await vm.segments(item)
                checkpoint = await vm.checkpoint(item)
                loading = false
                if let initialTime, let target = segments.first(where: { $0.start <= initialTime && $0.end >= initialTime }) {
                    reader.scrollTo(target.id, anchor: .center)
                }
            }
        }
        .navigationTitle("Запись").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Найти в этой записи")
        .task { await playback.open(item, url: vm.location(item), initialTime: initialTime) }
        .onDisappear { playback.close() }
        .confirmationDialog("Заменить расшифровку?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("Продолжить") {
                if confirmation == .subtitles { pickSubtitle = true }
                else { vm.transcribe(item, restart: true) }
                confirmation = nil
            }
            Button("Отмена", role: .cancel) { confirmation = nil }
        } message: {
            Text("Текущие субтитры будут заменены после успешного импорта или распознавания. Сохранённый прогресс распознавания будет сброшен.")
        }
        .fileImporter(isPresented: $pickSubtitle, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { vm.importSubtitle(url, for: item) }
            case .failure(let error): vm.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { shareURL.map { SharedFile(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { file in
            NavigationStack {
                ShareLink(item: file.url) { Label("Сохранить или отправить", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).padding().navigationTitle("Экспорт")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { shareURL = nil } } }
            }.presentationDetents([.medium])
        }
    }

    static func time(_ seconds: Double) -> String {
        let n = Int(seconds.isFinite ? min(359_999_999, max(0, seconds)) : 0)
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
    private struct SharedFile: Identifiable { let url: URL; var id: String { url.absoluteString } }
}
