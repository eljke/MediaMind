import SwiftUI

struct MediaSearchView: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var searching = false
    var body: some View {
        NavigationStack {
            Group {
                if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Найти момент", systemImage: "text.magnifyingglass", description: Text("Введи слово или фразу из расшифровки. Нажми на результат, чтобы включить запись с найденного места."))
                } else if searching { ProgressView("Поиск по расшифровкам") }
                else if vm.results.isEmpty { ContentUnavailableView.search(text: vm.query) }
                else {
                    List {
                        Section {
                            ForEach(vm.results) { hit in
                                NavigationLink { MediaDetail(item: hit.item, initialTime: hit.segment.start) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(hit.item.title).font(.headline).lineLimit(2)
                                        Text(hit.segment.text).lineLimit(3)
                                        Label(MediaDetail.time(hit.segment.start), systemImage: "play.circle.fill").font(.caption.monospacedDigit()).foregroundStyle(.indigo)
                                    }.padding(.vertical, 6)
                                }
                            }
                        } header: { Text(vm.results.count == 200 ? "Первые 200 совпадений — уточни запрос" : "Совпадений: \(vm.results.count)") }
                    }
                }
            }
            .navigationTitle("Найти момент")
            .searchable(text: $vm.query, prompt: "Слово или фраза")
            .task(id: vm.query) {
                searching = true
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    await vm.runSearch()
                    if !Task.isCancelled { searching = false }
                } catch {}
            }
        }
    }
}
