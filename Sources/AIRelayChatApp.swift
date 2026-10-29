import SwiftUI
import SafariServices

// MARK: - App 入口

@main
struct AIRelayChatApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
                .task {
                    // 首次进入自动判定在家/在外
                    await store.bootstrap()
                }
                // 注意：单参数闭包是 iOS 16 写法，双参数版本要 iOS 17
                .onChange(of: scenePhase) { phase in
                    // 从后台切回来时轻量重连：出门/回家立刻生效，不用杀 App
                    if phase == .active {
                        Task { await store.refreshIfNeeded() }
                    }
                }
        }
    }
}

// MARK: - 打开网页（后台管理、Safari 内嵌）

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController(url: url)
        c.preferredControlTintColor = .systemBlue
        return c
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
