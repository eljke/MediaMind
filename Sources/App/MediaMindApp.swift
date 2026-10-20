import SwiftUI

@main
struct MediaMindApp: App {
    @StateObject private var vm = MediaViewModel()
    var body: some Scene { WindowGroup { MediaRoot().environmentObject(vm) } }
}

struct MediaRoot: View {
    @EnvironmentObject private var vm: MediaViewModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            MediaLibrary().tabItem { Label("Библиотека", systemImage: "play.rectangle.on.rectangle") }
            MediaSearchView().tabItem { Label("Поиск", systemImage: "text.magnifyingglass") }
            MediaSettings().tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .safeAreaInset(edge: .bottom) {
            if vm.busy {
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(vm.operationTitle).font(.subheadline.bold())
                            Text(vm.progress > 0 ? "\(Int(vm.progress * 100)) % · держи приложение открытым" : "Подготовка · держи приложение открытым").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.canCancel { Button("Остановить") { vm.cancel() }.frame(minHeight: 44) }
                    }
                    if vm.progress > 0 { ProgressView(value: vm.progress).accessibilityLabel("Прогресс обработки") }
                    else { ProgressView().accessibilityLabel("Подготовка обработки") }
                }.padding().background(.regularMaterial)
            } else if vm.transcriptUndo != nil {
                HStack {
                    Text("Текст изменён").font(.footnote)
                    Spacer(minLength: 8)
                    Button("Отменить") { Task { await vm.undoTranscriptEdit() } }.frame(minHeight:44)
                    Button { vm.transcriptUndo = nil } label: { Image(systemName:"xmark.circle.fill").frame(width:44,height:44) }.accessibilityLabel("Закрыть сообщение")
                }.padding(.horizontal).background(.regularMaterial)
            } else if vm.deletedBookmark != nil {
                HStack {
                    Text("Закладка удалена").font(.footnote)
                    Spacer(minLength: 8)
                    Button("Восстановить") { Task { await vm.undoBookmarkDeletion() } }.frame(minHeight: 44)
                    Button { vm.deletedBookmark = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Закрыть сообщение")
                }.padding(.horizontal).background(.regularMaterial)
            } else if let notice = vm.notice {
                HStack {
                    Text(notice).font(.footnote)
                    Spacer(minLength: 8)
                    Button { vm.notice = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Закрыть сообщение")
                }.padding(.horizontal).background(.regularMaterial)
            }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button("Закрыть") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.cancel() }
        }
    }
}
