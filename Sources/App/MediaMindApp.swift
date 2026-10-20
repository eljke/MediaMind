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
                            Text("\(Int(vm.progress * 100)) % · держи приложение открытым").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Остановить") { vm.cancel() }.frame(minHeight: 44)
                    }
                    ProgressView(value: vm.progress).accessibilityLabel("Прогресс обработки")
                }.padding().background(.regularMaterial)
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
