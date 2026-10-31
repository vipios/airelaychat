import SwiftUI
import SafariServices
import Network   // NWPathMonitor：网络一变化立刻重连

// MARK: - App 入口

@main
struct AIRelayChatApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
                .task {
                    // 触感生成器预热。不预热的话 App 起来后**第一下**点击
                    // 经常不震（生成器还在唤起 Taptic Engine），用户会以为又坏了。
                    // 2026-11-01 用户：「所有的按键加一个震动反馈」。
                    Haptic.warmUp()
                    // 点空白处取消选区的全局手势（window 级）。同样要在窗口就绪后挂。
                    SelectionKiller.shared.install()
                    // 首次进入自动判定在家/在外
                    await store.bootstrap()
                }
                // 注意：单参数闭包是 iOS 16 写法，双参数版本要 iOS 17
                .onChange(of: scenePhase) { phase in
                    // 从后台切回来时轻量重连：出门/回家立刻生效，不用杀 App
                    if phase == .active {
                        Task { await store.refreshIfNeeded() }
                    } else if phase == .background {
                        // 进后台时把对话落盘，避免被系统回收后丢历史
                        store.syncCurrentSession()
                    }
                }
                .modifier(NetworkChangeWatcher {
                    // 走到这里说明 WiFi 连上/断开、或者换了网 —— 立刻重新判定。
                    // 用户要的就是"连 WiFi 自动在家、断 WiFi 自动在外面"，
                    // 光靠切前台触发不够：手机在兜里走动时也可能切网。
                    Task { await store.refreshIfNeeded() }
                })
                // 深色模式下顶部状态文字要看清
                .preferredColorScheme(nil)
        }
    }
}

// MARK: - 网络变化监听

/// 监听默认路由的变化。WiFi 断开、连上、换网都会触发。
/// 用它而不是"每 N 秒轮询"：不耗电，也不会在没变化时瞎重连。
struct NetworkChangeWatcher: ViewModifier {
    let onChange: () -> Void

    @State private var monitor: NWPathMonitor?
    @State private var lastSignature: String = ""

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let m = NWPathMonitor()
                m.pathUpdateHandler = { path in
                    // 概括成一个字符串："wifi/有线/蜂窝 + 是否有 IPv6 等"
                    // 只有真的变了才回调，避免 iOS 频繁刷新路径状态时重复重连。
                    var sig = ""
                    if path.usesInterfaceType(.wifi) { sig += "w" }
                    if path.usesInterfaceType(.wiredEthernet) { sig += "e" }
                    if path.usesInterfaceType(.cellular) { sig += "c" }
                    sig += path.status == .satisfied ? "+" : "-"
                    if path.supportsIPv6 { sig += "6" }
                    DispatchQueue.main.async {
                        guard sig != lastSignature else { return }
                        let first = lastSignature.isEmpty
                        lastSignature = sig
                        // 首次只是记录基线，不必重连（.task 已经连过了）
                        if !first { onChange() }
                    }
                }
                m.start(queue: DispatchQueue(label: "airelay.netmon"))
                monitor = m
            }
            .onDisappear {
                monitor?.cancel()
                monitor = nil
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
