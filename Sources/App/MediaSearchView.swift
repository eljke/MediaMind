import SwiftUI

struct HighlightedText: View {
    let text: String
    let query: String
    var body: some View {
        var value = AttributedString(text)
        for range in MediaSearch.ranges(in:text,query:query) {
            if let range = Range(range,in:value) { value[range].backgroundColor = Color.yellow.opacity(0.35) }
        }
        return Text(value)
    }
}

struct MediaSearchView: View {
    @EnvironmentObject private var vm: MediaViewModel
    @State private var debouncing = false
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                HStack {
                    Picker("Где искать",selection:$vm.searchScope) { ForEach(SearchScope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    Spacer()
                    Picker("Тип записи",selection:$vm.searchKind) { ForEach(MediaKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                }.pickerStyle(.menu).padding(.horizontal)
                content
            }
            .navigationTitle("Найти момент")
            .searchable(text:$vm.query,prompt:"Название, фраза или заметка")
            .task(id:vm.searchKey) {
                debouncing = true
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    await vm.runSearch()
                    if !Task.isCancelled { debouncing = false }
                } catch {}
            }
        }
    }

    @ViewBuilder private var content: some View {
        if vm.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("Найти момент",systemImage:"text.magnifyingglass",description:Text("Ищи по названиям, расшифровкам и заметкам. Нажатие на фразу или заметку открывает запись с её времени."))
        } else if debouncing || (vm.searching && vm.results.isEmpty) { ProgressView("Поиск по библиотеке").frame(maxWidth:.infinity,maxHeight:.infinity) }
        else if vm.results.isEmpty { ContentUnavailableView.search(text:vm.query) }
        else {
            List {
                Section {
                    ForEach(vm.results) { hit in
                        NavigationLink { MediaDetail(item:hit.item,initialTime:hit.position) } label: {
                            VStack(alignment:.leading,spacing:8) {
                                HighlightedText(text:hit.item.title,query:vm.query).font(.headline).lineLimit(2)
                                if case .title = hit.match {} else { HighlightedText(text:hit.text,query:vm.query).lineLimit(4) }
                                Label(source(hit),systemImage:hit.position == nil ? "doc.text.magnifyingglass" : "play.circle.fill").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.vertical,6)
                        }
                    }
                } header: { Text("Показано совпадений: \(vm.results.count)") }
                if vm.moreSearchResults {
                    Button { Task { await vm.runSearch(more:true) } } label: {
                        HStack { if vm.searching { ProgressView() }; Text("Показать ещё") }.frame(minHeight:44)
                    }.disabled(vm.searching)
                }
            }
        }
    }

    private func source(_ hit: LibrarySearchHit) -> String {
        switch hit.match {
        case .title: return "Название записи"
        case .transcript(let segment): return "Расшифровка · \(MediaTime.label(segment.start))"
        case .bookmark(let bookmark): return "Заметка · \(MediaTime.label(bookmark.position))"
        }
    }
}
