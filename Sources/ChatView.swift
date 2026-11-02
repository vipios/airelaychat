import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit   // UIPasteboard：气泡下面「复制」用

// MARK: - 聊天主界面（仿 WorkBuddy 手机端）

/// 布局对齐 WorkBuddy（2026-10-30 按截图重做）：
///   顶栏：左侧白色圆钮（≡）+ 中间（💻• 模型名 / 会话名）+ 右侧白胶囊（💬+  ⋯）
///   对话区：AI 回复无气泡左对齐，用户消息右侧白气泡
///   输入区：两行白胶囊，上行输入框，下行「声波 · 模型⌄ · ＋ · 发送」
///   抽屉：左侧滑出，可建分组、长按会话归组
struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    /// 产物库。聊天页要看「这条回复的产物」和「全部产物 (N)」。
    @ObservedObject private var lib = FileLibrary.shared
    @StateObject private var voice = VoiceInput()

    @State private var showModelPicker = false
    @State private var showSettings = false
    @State private var showDiag = false
    @State private var showAttach = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var healthTimer: Timer?

    @State private var drawerOpen = false
    /// 顶栏右侧「⋯」的菜单开没开。
    ///
    /// 2026-11-01 修闪退：这里原来是个 `Menu` + `LongPressGesture(minimumDuration: 0)`
    /// 配 `@GestureState` 来盯按下态。`minimumDuration: 0` 在 iOS 16 上会**立即识别**，
    /// 而 `.onChange(of: morePressed)` 又读了这个状态 —— 于是形成
    /// 「手势识别 → 写状态 → body 重建 → 手势重挂 → 再立即识别」的自激循环。
    /// 「⋯」在首帧就要渲染，App 一启动就 100% CPU 空转，被系统看门狗杀掉，
    /// 用户看到的就是「点开闪退」。
    ///
    /// 现在换成普通 Button + 底部弹窗：按下直接吃 `PressableStyle(fills:)`，
    /// 一样反成纯黑，再也不用手势去猜按下态。
    @State private var showMoreMenu = false
    /// 去过哪些 Tab。
    ///
    /// 2026-10-31 为了让后台面板"进去就显示"改了 Tab 的承载方式：
    /// 从 switch（切走即销毁）改成 ZStack 常驻。但常驻不能一上来就全建 ——
    /// 那样 App 启动、用户还在聊天页时就会去加载后台那个 900KB 的网页，
    /// 跟首屏抢网络，反而更慢。
    ///
    /// 所以记一下：**去过一次之后**才让它常驻。
    /// 第一次进后台仍然要等它加载（没办法，那是真没加载过），
    /// 但从第二次起就是瞬间显示。
    @State private var visitedTabs: Set<MainTab> = [.tasks]
    /// 抽屉里的「我的文件」。和抽屉共用外层弹层，抽屉自己不挂 sheet。
    @State private var showFiles = false
    /// 「生成交接」的确认（让 AI 整理要花一次对话，先说清楚）
    @State private var confirmHandoff = false
    /// 点产物卡片 → 预览；预览里点分享 → 换成分享面板
    @State private var previewFile: AIFile?
    @State private var shareFile: AIFile?
    /// 产物长按「保存」→ 系统「存到哪里」面板
    @State private var saveRequest: ExportRequest?
    /// 产物长按「添加到对话」→ 先选对话
    @State private var attachFile: AIFile?

    @FocusState private var inputFocused: Bool

    /// 用户是不是正贴在列表底部。
    ///
    /// 2026-11-02 加：流式跟随必须知道这件事。
    /// 用户在往上翻历史时，新内容继续涌进来不能把他拽回底部 ——
    /// 那正是之前「一往上翻就被拉回去」的老毛病。
    ///
    /// 由底部锚点的 GeometryReader 报上来的 y 判断，见 messagesArea。
    @State private var atBottom = true

    /// 「回到底部」的触发计数。
    /// 加一 → 里层 ScrollViewReader 收到变化就滚到底。
    /// 用计数而不是 Bool：连点两下也要每次都生效。
    @State private var scrollTick = 0

    /// 这一轮从什么时候开始等的。
    ///
    /// 只是给「正在回答」那张卡片显示已等秒数用 —— 用户最想知道的是
    /// "它到底卡了还是只是慢"，一个在跳的秒数比一个转圈更让人放心。
    @State private var thinkingSince = Date()

    /// 设置「是否贴在底部」，两份状态一起改。
    ///
    /// 为什么有两份：`atBottom` 是 `@State`，负责驱动界面（浮钮显隐）；
    /// `gate.pinned` 存在引用类型里，给 `asyncAfter` 的收尾滚动读 ——
    /// 闭包捕获 View struct 快照，读 `@State` 会拿到排队时的旧值。
    /// 两者必须永远一致，所以只准通过这个方法改。
    private func pinToBottom(_ pinned: Bool) {
        gate.pinned = pinned
        if atBottom != pinned { atBottom = pinned }
    }

    /// 滚动跟随的节流闸门。
    ///
    /// ⚠️ 为什么用 class 而不是几个 `@State`：
    /// 收尾滚动是在 `DispatchQueue.main.asyncAfter` 里跑的，闭包捕获的是
    /// **View struct 那一刻的快照** —— 读 `@State` 拿到的永远是排队时的旧值。
    /// 换成引用类型后，闭包里读到的就是最新状态：
    /// 「是不是已经有更新的一发接管了」「用户是不是已经翻上去了」两句判断
    /// 才靠谱。
    ///
    /// 刻意不加 `@Published`：这些字段是纯控制量，不该触发 body 重算，
    /// 每帧重算列表正是之前抖动的来源之一。
    private final class FollowGate: ObservableObject {
        /// 最近一次真正执行 `scrollTo` 的时刻。
        var lastAt = Date.distantPast
        /// 发号器。每次调用加一；到点发现号不是自己那一发，就静默退出。
        var token = 0
        /// 用户当前是否贴在底部（由 `onPreferenceChange` 维护）。
        var pinned = true
    }

    @StateObject private var gate = FollowGate()

    var body: some View {
        ZStack(alignment: .topLeading) {
            mainColumn

            if drawerOpen {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }

                // 注意这里**不能**再加 .ignoresSafeArea(edges: .vertical)：
                // 那样抽屉里的第一行会钻到刘海下面，和状态栏的时间叠在一起。
                // 通栏背景已经由 DrawerView 内部对自己的 background 做了，
                // 内容层留在安全区内就够了。
                DrawerView(store: store,
                           onClose: { closeDrawer() },
                           onOpenSettings: { showSettings = true },
                           onOpenDiag: { showDiag = true },
                           onOpenFiles: { showFiles = true },
                           // 2026-11-01：抽屉里的「我的文件」改成就地展开，
                           // 展开出来的产物行要能长按出菜单 —— 打开 / 共享 / 保存 /
                           // 添加到对话 / 打开对话。抽屉自己不挂 sheet（会抢层），
                           // 所以弹层全部交回 ChatView 这边。
                           onPreviewFile: { f in previewFile = f },
                           onShareFile: { f in shareFile = f },
                           onSaveFile: { f in saveRequest = ExportRequest(urls: [f.url]) },
                           onAttachFile: { f in attachFile = f },
                           onOpenConversation: { f in openConversation(of: f) })
                    .frame(width: DrawerView.width)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
                .roundSheet(28)
        }
        .sheet(isPresented: $showDiag) {
            NavigationStack { DiagView() }
                .roundSheet(28)
        }
        .sheet(isPresented: $showFiles) {
            // 传 sessionId：聊天页点「全部产物」只看这个对话的产物。
            // 抽屉里的「我的文件」不传，看整个文件库。
            MyFilesView(store: store, embedded: true, sessionId: store.currentSessionId)
                .roundSheet(28)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // 产物卡片的预览 / 分享
        .sheet(item: $previewFile) { f in
            NavigationStack {
                QuickLookView(url: f.url)
                    .ignoresSafeArea()
                    .navigationTitle(f.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                let tmp = f
                                previewFile = nil
                                // 等预览关掉再弹分享，两个 sheet 同时开会互相吞
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    shareFile = tmp
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { previewFile = nil }
                        }
                    }
            }
            .roundSheet(28)
        }
        .sheet(item: $shareFile) { f in
            ShareSheet(items: [f.url])
                .presentationDetents([.medium, .large])
                .roundSheet(28)
        }
        // 产物长按「保存」：系统文件选择器负责问存到哪
        .sheet(item: $saveRequest) { req in
            DocumentExporter(urls: req.urls)
                .ignoresSafeArea()
        }
        // 产物长按「添加到对话」：先选一个对话，把产物挂进它的输入框
        .sheet(item: $attachFile) { f in
            SessionPickerSheet(store: store, file: f) {
                attachFile = nil
            }
            .roundSheet(28)
        }
        // 「生成交接」先说清楚代价：让 AI 整理＝花一次对话
        .confirmationDialog("生成交接包？", isPresented: $confirmHandoff, titleVisibility: .visible) {
            Button("生成（让 AI 重新整理，消耗一次对话）") {
                store.generateHandoffPackage()
            }
            Button("只取本地摘要（不花积分）") {
                store.prepareHandoff()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("""
            「生成」让 AI 重新整理交接文档和全部源码，消耗一次对话。
            「本地摘要」不调用模型：把目标、结论、进度拼成文档，顺带从聊天里扫出仓库地址、项目路径和构建命令。
            如果这个项目是 AI 在电脑上做的（手机里没有文件），建议先用「本地摘要」——它扫出的地址比自己重写的代码准。
            """)
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in store.addImage(img) }
                .roundSheet(28)
        }
        // 模型选择挂在整个页面最外层，不能挂在输入栏上 ——
        // 挂输入栏时 GeometryReader 只能拿到输入栏那几十 pt 高度，
        // 半屏算出来就变成一条窄带。挂根层才能拿到整屏高度。
        //
        // 附件弹层（加号）原先挂在输入栏的 .overlay 上，同样有问题：
        // overlay 的尺寸被限制在输入栏那一条里，里面的黑色半透明遮罩
        // 只能盖住输入栏本身，点"弹窗上面的空白"根本点不到遮罩 →
        // 用户反馈「不选择就收不回去」。现在两个都挂到根层，
        // 遮罩铺满整屏，点任何空白处都能关。
        .overlay {
            if showModelPicker {
                ModelPickerSheet(store: store,
                                 onClose: { showModelPicker = false })
            }
            if showAttach {
                AttachSheet(
                    onPhoto: { showAttach = false; showPhotoPicker = true },
                    onCamera: { showAttach = false; showCamera = true },
                    onFile: { showAttach = false; showFilePicker = true },
                    onCancel: { showAttach = false }
                )
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            // 2026-10-31 修「选了文件点确定没反应」：
            // 原来只处理 .success，用户取消 / 权限失败 / 沙盒读不到 全都静默。
            // 尤其是「文件」App 里某些位置（iCloud 未下载、第三方网盘占位）
            // 会直接走 .failure，界面一动不动，看起来就是"点了确定没反应"。
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else {
                    store.toast = "没选到文件"
                    return
                }
                for u in urls { store.addFile(u) }
            case .failure(let err):
                // 用户主动取消也会走到这里，那种不用提示
                let ns = err as NSError
                if ns.domain == NSCocoaErrorDomain,
                   ns.code == CocoaError.Code.userCancelled.rawValue {
                    return
                }
                store.toast = "打不开这个位置：\(err.localizedDescription)"
            }
        }
        // 单参数闭包是 iOS 16 写法，双参数要 iOS 17
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .onChange(of: store.toast) { t in
            guard t != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                store.toast = nil
            }
        }
        .task {
            // 进来先探一次，别让灯一直灰着
            await store.pingNow()
            // 之后每 20 秒一次。为什么不用 30/60 秒：
            // 隧道断开到用户发现，中间最多差这一拍；20 秒足够快，又不费电
            // （一次 /health 就几十字节）。
            healthTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                Task { @MainActor in await store.pingNow() }
            }
        }
        .onDisappear { healthTimer?.invalidate(); healthTimer = nil }
    }

    private func openDrawer() {
        inputFocused = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { drawerOpen = true }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { drawerOpen = false }
    }

    /// 产物「打开对话」：跳回这份产物所属的那个对话。
    ///
    /// 2026-11-01 用户：「我按住某一个产物的时候出现弹窗…里面再加上一个打开对话这四个字，
    /// 我点击了他才跳转到那个聊天窗口」。所以点产物本身**不跳**，
    /// 只有菜单里这一项才切会话 —— 顺序不能反。
    private func openConversation(of f: AIFile) {
        inputFocused = false
        closeDrawer()
        if !f.sessionId.isEmpty { store.openSession(f.sessionId) }
        store.tab = .tasks
        showFiles = false
    }

    /// 聊天页本体（原 switch 里 .tasks 那一段），抽出来给 ZStack 用。
    private var taskTab: some View {
        VStack(spacing: 0) {
            topBar
            // 换过来源/账号 → 提示可以把上一个 AI 的进度交接过来。
            // 2026-10-31 用户要求「换账号别断开记忆」：光有菜单入口不够，
            // 用户换完来源根本不会想起来去点菜单，得主动递到眼前。
            if store.needsHandoffHint { handoffBanner }
            messagesArea
            // 「回到底部」浮钮。用户往上翻历史时不打扰他；
            // 一旦他离开底部、又有新内容在长，右下角出现一个小圆钮。
            // 这是官方那套滚动行为的另一半 —— 只做"不跟随"而不给回去的路，
            // 用户就得自己滑半天。放在 messagesArea 之上、输入栏之下，
            // 用 overlay 挂，不占布局高度（占高度会让消息区在出现/消失时抖一下）。
            if let err = store.errorText { errorBanner(err) }
            if !store.pending.isEmpty { pendingStrip }
            // 队列：官方是「输入框上方的队列」，位置就摆在这里。
            if !store.queued.isEmpty { queueStrip }
            inputBar
        }
        .overlay(alignment: .bottomTrailing) { scrollToBottomButton }
    }

    /// 回到底部。离开底部且正在输出时才出现。
    private var scrollToBottomButton: some View {
        Group {
            if !atBottom, !store.messages.isEmpty {
                Button {
                    pinToBottom(true)
                    // 用一个计数器通知里层的 ScrollViewReader 滚到底。
                    // 为什么不用 NotificationCenter：滚动是纯视图行为，
                    // 走全局通知会跨页面误触发（另一个会话页也在听）。
                    scrollTick += 1
                    Haptic.press()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                        .frame(width: 34, height: 34)
                        .background(Theme.card)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                // 抬到输入栏上面一点，别压住最后一行字
                .padding(.trailing, 18)
                .padding(.bottom, 14)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: atBottom)
    }

    /// 「换个 AI 接着聊」提示条。点右边按钮 → 摘要进输入框。
    private var handoffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("已经换成另一个 AI 了")
                    .font(.system(size: 12.5, weight: .medium))
                Text("它还不知道前面做到哪了")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                store.prepareHandoff()
                store.needsHandoffHint = false
            } label: {
                Text("交接")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.95))

            Button {
                store.needsHandoffHint = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PressableStyle(scale: 0.90, tint: 0.09, tintRadius: 999, darken: 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 主列

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // 三个 Tab 用 ZStack 常驻，**不要用 switch**。
            //
            // 2026-10-31 用户要求「进入后台面板页面直接就显示，现在等得太久」：
            // 原来写的是 switch store.tab，切走时 SwiftUI 会把 AdminTabPage
            // 整个拆掉 —— 里面的 WKWebView 跟着销毁，@State tick 归零。
            // 切回来就是"新建 WebView + tick 从 0 开始"，必然重新全量加载
            // 那个 900 多 KB 的后台首页，还要重新执行里面的 JS。
            //
            // 改成常驻后：WebView 只在第一次进入时建一次，之后切回来
            // 页面还在、滚动位置还在，等于零等待。
            // 用 opacity + allowsHitTesting 而不是 hidden()，因为 hidden
            // 会让布局塌掉，WebView 尺寸被压成 0，回来又要重排。
            //
            // 但「常驻」不能一上来就建 —— 那会在 App 启动、用户还在聊天页时
            // 就去加载后台网页，和首屏抢网络。所以用 visitedTabs 记录：
            // 只有去过一次之后才放进 ZStack 常驻，没去过就不建。
            ZStack {
                taskTab
                    .opacity(store.tab == .tasks ? 1 : 0)
                    .allowsHitTesting(store.tab == .tasks)
                if visitedTabs.contains(.admin) {
                    AdminTabPage(store: store)
                        .opacity(store.tab == .admin ? 1 : 0)
                        .allowsHitTesting(store.tab == .admin)
                }
                if visitedTabs.contains(.mine) {
                    MineTabPage(store: store)
                        .opacity(store.tab == .mine ? 1 : 0)
                        .allowsHitTesting(store.tab == .mine)
                }
            }
            .onAppear { visitedTabs.insert(store.tab) }
            .onChange(of: store.tab) { t in visitedTabs.insert(t) }
            // 底部导航常驻。
            // 之前后台面板页把它藏起来（想让网页全屏），代价是进去以后
            // 想切到「我的」只能先左滑回聊天页 —— 三个 Tab 里少一个，
            // 用户会以为后台是个单向页面。现在和演示图统一，三页都有。
            bottomTabBar
        }
        .background(Theme.page)
        .contentShape(Rectangle())
        // 从屏幕左缘往右滑打开抽屉。
        // **只在「任务」页生效** —— 用户明确要求「侧抽只能聊天界面才能生效」。
        // 后台面板是网页、我的页是设置列表，在那里侧滑出抽屉既意外又容易误触。
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { g in
                    let horizontal = abs(g.translation.height) < 70
                    guard horizontal else { return }

                    // 2026-10-31 用户要求「再加一个右划返回上一页，就像左滑那种」。
                    // 之前的规则是单向的（后台/我的页只能左滑回聊天），
                    // 用户从这两页往右划没反应，和 iOS 系统手势直觉相反。
                    //
                    // 现在按「当前在哪一层」决定返回目标，左右都认：
                    //   抽屉开着        → 右滑关抽屉（回到聊天页本体）
                    //   后台面板/我的   → 左右滑都回聊天页
                    //   聊天页原点      → 只在左缘右滑才出抽屉（防误触）
                    //
                    // 2026-11-01 用户：「左右滑动返回让他从边缘往中间滑动才能返回」。
                    // 上一版只要横向位移过 70pt 就算数，导致在页面正中间随便拨一下
                    // 也会跳页 —— 网页里横滑一张宽表格、在消息列表上左右拖，
                    // 都会莫名其妙退回聊天页。现在两向都要求**起手贴边**
                    // （离屏幕边 30pt 以内，和系统返回手势同一档距），
                    // 页面中部的横向拖动还给页面自己。
                    let screenW = UIScreen.main.bounds.width
                    let fromLeftEdge = g.startLocation.x < 30
                    let fromRightEdge = g.startLocation.x > screenW - 30

                    if drawerOpen {
                        // 抽屉铺在聊天页上面，它的"上一页"就是聊天页。
                        // 这里只听右滑：抽屉本体里还有列表要上下滚，
                        // 左滑留着不抢，避免和列表滑动打架。
                        if fromLeftEdge, g.translation.width > 70 {
                            // 震动放在手势里而不是 closeDrawer() 里：
                            // 抽屉左上角那个按钮自己已经带一档震动（PressableStyle 里），
                            // 两个入口共用函数的话，点按钮会连震两下。
                            Haptic.tap()
                            closeDrawer()
                        }
                        return
                    }

                    if store.tab != .tasks {
                        // 后台面板 / 我的：从左边往中间拨（右滑）或
                        // 从右边往中间拨（左滑）都回聊天页，但都必须贴边起手。
                        let backRight = fromLeftEdge && g.translation.width > 70
                        let backLeft  = fromRightEdge && g.translation.width < -70
                        if backRight || backLeft {
                            inputFocused = false
                            Haptic.tap()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.tab = .tasks
                            }
                        }
                        return
                    }

                    // 聊天页：左缘右滑 → 出抽屉。
                    // 非左缘的右滑在聊天页不做事 —— 聊天页已经是根，没有"上一页"。
                    if fromLeftEdge, g.translation.width > 70 {
                        Haptic.tap()
                        openDrawer()
                    }
                }
        )
    }

    // MARK: - 底部导航

    /// 三个入口：任务 / 后台面板 / 我的。选中态是深色实心图标 + 深色文字。
    private var bottomTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(MainTab.allCases) { t in
                    Button {
                        if store.tab == t { return }
                        inputFocused = false
                        store.tab = t
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                // 2026-10-31 用户：「底栏圆钮还用咱们之前的那个就行」
                                // 之前做的是圆角方块（27×23、圆角 7），别照原版改成黑圆。
                                // 2026-11-01 底色从纯黑改成深灰（Theme.press）：
                                // 纯黑在其他按钮都是白/浅灰的一屏里太抢，深灰仍是"选中"但更稳。
                                if store.tab == t {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Theme.press)
                                        .frame(width: 27, height: 23)
                                        .transition(.opacity)
                                }
                                Image(systemName: store.tab == t ? t.iconFilled : t.icon)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(store.tab == t ? Theme.card : Theme.sub)
                            }
                            .frame(height: 23)

                            Text(t.rawValue)
                                .font(.system(size: 10, weight: store.tab == t ? .medium : .regular))
                                .foregroundStyle(store.tab == t ? Color.primary : Theme.sub)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    // 2026-11-01：底栏三项都补上按下反馈 —— 点"后台面板"时
                    // 至少能看到按钮被按了一下，不用等整页切过去才知道点到了。
                    .buttonStyle(PressableStyle(scale: 0.94))
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 1)
        }
        .background(Theme.page)
    }

    // MARK: - 顶栏

    /// 结构照用户 2026-10-31 的截图定稿：
    ///   (≡)            任务名（17 粗体，第一行）
    ///                  💻• 模型名 | 在家（11 灰，第二行）
    ///                                          [💬+  ⋯]
    ///
    /// 上一版是「模型第一行、会话第二行」，用户新截图明确要求
    /// **第一行任务名、第二行模型** —— 手机上看的是"我在聊什么"，
    /// 模型是次要信息，放第二行。
    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左侧：白色圆钮。参考图里这是一个白底圆形，不是纯图标。
            Button { openDrawer() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Theme.card)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(PressableStyle(scale: 0.95, fills: true))

            // 中间：第一行任务名，第二行模型（点它开模型选择）
            //
            // 2026-10-31 改居中：之前是左对齐，模型名那一行会紧贴左边的 ☰ 按钮，
            // 而演示图里两行都是**居中**的 —— 左右两个圆钮夹着中间一列文字，
            // 这种对称感才是原版的样子。
            Button { showModelPicker = true } label: {
                VStack(alignment: .center, spacing: 2) {
                    Text(store.currentSessionTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 4) {
                        // 电脑图标 + 右上角小灯
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Circle()
                                .fill(linkColor)
                                .frame(width: 5, height: 5)
                                .overlay(Circle().stroke(Theme.page, lineWidth: 1))
                                .offset(x: 2.5, y: -1.5)
                        }
                        .frame(width: 14, height: 12)

                        Text(modelTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.96, tint: 0.06, tintRadius: 14))

            // 右侧：一个白胶囊里并排两个图标（新建 / 更多），照截图
            //
            // 2026-11-01 用户：「ipa 聊天页右上角胶囊点击不是黑色，改一下」。
            // 原因：白底原来画在整条 HStack 上，两个按钮自己是透明的 ——
            // 按下走的 `colorInvert()` 只反按钮**自身像素**，透明区域反完还是透明，
            // 所以按下去只看到一丁点淡灰。
            // 现在白底挪到每一段自己身上，按下那一段直接反成纯黑，
            // 两段拼起来就是整条黑胶囊。
            HStack(spacing: 0) {
                Button { store.newSession(); store.tab = .tasks } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 41, height: 38)
                        .background(Theme.card)
                        .contentShape(Rectangle())
                }
                // 不缩放：整条胶囊是两段拼的，缩放会在接缝处露出一道底色缝
                .buttonStyle(PressableStyle(scale: 1.0, fills: true))

                Button { showMoreMenu = true } label: {
                    // 改成 Button 之后按下直接吃 PressableStyle 的 `colorInvert()`，
                    // 白底一次性反成纯黑 —— 不用再自己盯按下态。
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 41, height: 38)
                        .background(Theme.card)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 1.0, fills: true))
                // 菜单挂在这个按钮自己身上，不挂根层 ——
                // 根层已经有一个「生成交接」的 confirmationDialog，
                // 同层叠两个弹窗 iOS 16 会互相顶掉，挂内层才互不干扰。
                // 条目和顺序跟原来的 Menu 一致：保存会话 → 清空会话 → 生成交接。
                .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .hidden) {
                    Button("保存会话") { store.syncCurrentSession() }
                    Button("清空会话", role: .destructive) {
                        store.reset()
                        store.syncCurrentSession()
                    }
                    Button("生成交接") {
                        // 连着弹两个弹窗 iOS 会吞掉后一个（前一个还在收动画），
                        // 等这一层收干净再开「生成交接」的确认。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            confirmHandoff = true
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Theme.page)
    }

    /// 顶栏第一行的模型名（去掉 "来源|" 前缀）
    private var modelTitle: String {
        let m = store.effectiveModel.isEmpty ? store.currentModel : store.effectiveModel
        if m.isEmpty { return "选个模型" }
        if let i = m.firstIndex(of: "|") { return String(m[m.index(after: i)...]) }
        return m
    }

    /// 连接灯颜色
    private var linkColor: Color {
        switch store.online {
        case .some(true): return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .some(false): return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .none: return Color(.tertiaryLabel)
        }
    }

    /// 顶栏副行里的场景短标签
    private var placeShort: String {
        if store.detecting && store.base == nil { return "连接中" }
        switch store.place {
        case .home: return "在家"
        case .away: return "在外"
        case .unknown: return store.base == nil ? "连接中" : "已连接"
        }
    }

    private func shortName(_ m: String) -> String {
        if let i = m.firstIndex(of: "|") { return String(m[m.index(after: i)...]) }
        return m
    }

    // MARK: - 消息区

    private var messagesArea: some View {
        // 外层只负责「量视口高度」。
        //
        // ⚠️ 2026-11-02 修（用户：「给 ai 下达指令的时候全屏文字和产物直接顶的最上面，
        // 全屏时完全空白，我还要多滑动屏幕几次才能显示」）。
        //
        // 三个病根叠在一起，必须一起改：
        //
        // ① **LazyVStack 是延迟布局的** —— 这是主因。
        //    它的内容总高度在滚动过程中是"估算"的，`scrollTo` 算目标偏移量时
        //    拿到的就是估算值。流式内容每 0.05 秒变一次，每次估算都不一样，
        //    于是滚到一个"当时以为对、下一帧就错"的位置。
        //    表现正是用户说的：**画面被顶到内容之外，一片空白，得手滑几次才回来**。
        //    聊天记录最多几十条，VStack 全量布局也就几毫秒，换来每次 scrollTo
        //    都算在真实高度上。这是最关键的一处。
        //
        // ② **每来一段 delta 就滚一次**（20Hz 的 scrollTo）。
        //    滚动本身是动画，后一发打断前一发，累积误差越滚越偏。
        //    现在改成 0.12 秒节流（约 8Hz），肉眼是连续跟随，但不再自我打架。
        //
        // ③ **`vp.size.height` 可能是 0**。
        //    GeometryReader 在 VStack 里，首帧还没算出高度；而判断"在底部"
        //    用的是 `y <= 0 + 72`，结果恒为 false —— `atBottom` 一直是 false，
        //    流式跟随从头到尾一次都不触发，内容一路往下长、视口不动 = 空白。
        //    现在用 `max(vp.size.height, 1)`，高度未知时退化成"认为在底部"。
        GeometryReader { vp in
            let viewportH = max(vp.size.height, 1)
            ScrollViewReader { proxy in
                ScrollView {
                    // ⚠️ 从 LazyVStack 换成 VStack，见上面 ①。
                    // 不要"为了性能"改回去：聊天记录量级很小，
                    // 而延迟布局会让滚动位置算错，那个代价大得多。
                    VStack(alignment: .leading, spacing: 20) {
                        if store.messages.isEmpty { emptyHint }
                        ForEach(store.messages) { msg in
                            bubble(msg).id(msg.id)
                        }
                        if store.sending && streamingText.isEmpty {
                            // 2026-11-02 按官方重做这段：
                            // 官方文档「任务被自动拆分为多个阶段，每个阶段以卡片形式展示：
                            //   「拆解为 N 个步骤」（显示子步骤数量）、「已完成」（绿色标签）、
                            //   点击卡片右侧 > 可展开查看详细过程」。
                            //
                            // 我们不是多步 Agent，没有真实的工具调用阶段，
                            // 所以不能假装有"N 个步骤"然后编内容 —— 那比不做更糟。
                            // 折中：做成一张**如实反映状态**的卡片，
                            // 展开后显示这一轮实际在干什么（连到哪、用的什么模型、等了多久）。
                            // 结构（可展开卡片）照官方，内容只写真有的。
                            ThinkingCard(store: store, startedAt: thinkingSince)
                                .id("thinking")
                                .padding(.top, 2)
                        }
                        // 底部锚点：一个**非零高度**的稳定 id。
                        //
                        // ⚠️ 为什么高度是 1 而不是 0：
                        // 0 高度的视图在部分 iOS 版本上会被布局系统裁掉，
                        // `scrollTo` 找不到锚点就什么都不做 —— 表现是"滚不动、停在半空"。
                        //
                        // ⚠️ 为什么滚锚点而不是滚「最后一条消息的 id」：
                        // 后者的高度随流式输出一直在变，每次 scrollTo 的目标都在动，
                        // 和内容变高互相拉扯，就是之前那个"到底以后一直抖"。
                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: BottomAnchorY.self,
                                        value: g.frame(in: .named("chatViewport")).maxY
                                    )
                                }
                            )
                        // 底部留白。**放在锚点之后**：
                        // 这样"滚到锚点"就已经滚到内容末端，这段空白是额外给的余量，
                        // 不会反过来把锚点位置算进去导致差一点点没到底。
                        Color.clear.frame(height: 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                }
                // 这个名字挂了 ScrollView 上，里面 frame(in:) 拿到的 y 会随滚动变化，
                // 所以「锚点 y ≤ 视口高 + 一点余量」就等于「已经在底部附近」。
                .coordinateSpace(name: "chatViewport")
                .onPreferenceChange(BottomAnchorY.self) { y in
                    guard y.isFinite else { return }
                    // 容差 120：列表底部还有留白和圆角，给少了会误判成
                    // "用户已经滚上去了"，于是停止跟随 —— 那又变回空白。
                    let near = y <= viewportH + 120
                    pinToBottom(near)
                }

                // ⚠️ 2026-11-02 修（用户：「我给他发完消息全屏看不到字，
                // 我还要往上滑动才能看见」+「全屏文字和产物直接顶的最上面，
                // 全屏时完全空白，我还要去多滑动屏幕几次才能显示」）。
                //
                // 病根：滚动只在「消息数变化」和「开始发送」这两个时刻触发，
                // **回复流式变长时完全没有跟随**。于是回复越写越长、内容一路往下长，
                // 视口却钉在原地不动 —— 用户只能看到开头一句，
                // 下面是整片空白，必须手动往上滑才追得上。
                //
                // 后来补了"每段 delta 滚一次"，结果是 20Hz 的 scrollTo 互相打断，
                // 仍然算错位置。现在统一走 `followBottom(_:animated:)`：
                // **前导 + 收尾的 0.12 秒节流**（约 8Hz）——
                // 到点立刻滚一次，紧接着来的高频更新只登记一次收尾，
                // 保证"最后那一小段内容"也一定跟上，不会有残余偏差。
                //
                // 用 length 而不是全文做 key：字符串比较几 KB 也费，
                // 而流式只会在末尾追加，长度变了就是有新内容。
                .onChange(of: streamingText.count) { _ in
                    guard atBottom else { return }
                    followBottom(proxy, animated: false)
                }
                // 新消息进来：必须滚，而且要带动画 ——
                // 这是"我发了消息，请把镜头带过去"的语义，没有动画会觉得突兀。
                //
                // ⚠️ 必须再补几次 `settleScroll`：新插入的气泡是 `SelectableText`，
                // 它的高度要等 UITextView 建好、文本灌进去才量得准。
                // 只滚一次会滚到"旧高度"对应的位置，画面停在内容之外 = 空白。
                .onChange(of: store.messages.count) { _ in
                    pinToBottom(true)
                    followBottom(proxy, animated: true, force: true)
                    settleScroll(proxy, delays: [0.05, 0.18, 0.40])
                }
                .onChange(of: store.sending) { v in
                    if v { thinkingSince = Date() }
                    pinToBottom(true)
                    // 开始 / 结束都强制滚一次：结束那下是兜底，
                    // 把节流跳过的最后一点点内容补齐，保证收尾一定贴在底部。
                    followBottom(proxy, animated: true, force: true)
                    // 结束那一下尤其要补：产物卡片紧接着就插进来了（见下面
                    // artifactCount），而且这时正文刚从流式状态定型成静态文本，
                    // 高度会再变一次。两个补滚叠在一起也没关系，幂等的。
                    settleScroll(proxy, delays: [0.06, 0.20, 0.45])
                }
                // 「回到底部」浮钮点了一下（见 scrollToBottomButton）
                .onChange(of: scrollTick) { _ in
                    pinToBottom(true)
                    followBottom(proxy, animated: true, force: true)
                    settleScroll(proxy, delays: [0.12, 0.35])
                }
                // 产物卡片是**回复说完之后**才插进来的（见 runSend 收尾顺序），
                // 那一下没有任何滚动跟随 —— 卡片就落在视口下方，用户以为没生成。
                // 这里单独盯住产物数，一变就补一次滚动。
                //
                // ⚠️ 必须延时：`sending` 刚转 false、`archiveReply` 才把产物写进库，
                // 那一刻界面还停在旧布局上。给布局一点时间再滚，才滚到真实位置。
                .onChange(of: artifactCount) { _ in
                    pinToBottom(true)
                    settleScroll(proxy, delays: [0.06, 0.22, 0.50])
                }
                // 切换会话：打开一段很长的历史对话时，同样会遇到"高度还没量准"，
                // 只是这里更极端 —— 几十条消息要一次性建出几十个 UITextView。
                // 所以第一次滚动提前到视图出现前后，之后再补三次，让它一层层追上。
                .onChange(of: store.currentSessionId) { _ in
                    pinToBottom(true)
                    settleScroll(proxy, delays: [0.05, 0.15, 0.35, 0.70])
                }
                .onAppear {
                    // 首次进入会话也走一遍（onChange 只在变化时触发，
                    // 从别的 tab 切回来时不会再变，得单独兜一次）。
                    pinToBottom(true)
                    settleScroll(proxy, delays: [0.05, 0.20, 0.50])
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { inputFocused = false }
                // 下拉刷新（iOS 16 起 ScrollView 原生支持）：
                // 重新探测地址 + 拉一遍模型清单。断网回来、路由器换网段、
                // 或者「一直显示未连接」时，往下拉一把比来回切页面快得多。
                .refreshable { await store.bootstrap() }
                // 页面走了就把已排队的收尾滚动作废（令牌加一即失效），
                // 免得它对着一个已经离屏的 ScrollViewProxy 执行。
                .onDisappear { gate.token &+= 1 }
            }
        }
    }

    /// 正在流式输出的那条回复的全文。
    ///
    /// 单独抽出来是为了给 `onChange` 一个稳定的观察目标：
    /// 直接写 `store.messages.last?.text` 在每次 body 重算时都会变引用，
    /// 容易漏掉或重复触发。空串表示当前没有在流。
    private var streamingText: String {
        guard store.sending, let m = store.messages.last, m.role == "assistant" else { return "" }
        return m.text
    }

    /// 当前会话的产物个数。
    ///
    /// ⚠️ 2026-11-02 加（用户：「测试的没有产物了」）。
    ///
    /// 排查结论：产物**确实生成了**（判定逻辑用离线脚本逐条复刻验证过，
    /// 截图那条回复应产出 4 个文件）。问题出在**顺序**上 ——
    /// `runSend` 收尾是：
    ///   ① `sending = false`  → 触发一次滚到底（这时的滚动是准的）
    ///   ② `syncCurrentSession()`
    ///   ③ `archiveReply(at:)` → 产物在这里才插进文件库
    ///
    /// 也就是说产物卡片是在"最后一次滚动之后"才出现的，内容又长高了一截，
    /// 而没有任何东西再滚一次 —— 卡片正好落在视口下方看不见的地方。
    /// 用户看到的就是"没有产物"。
    ///
    /// 所以必须**单独盯住产物数**：一变就跟着滚到底。
    private var artifactCount: Int {
        lib.files.reduce(0) { $0 + ($1.sessionId == store.currentSessionId ? 1 : 0) }
    }

    /// 滚到底部，**带前导 + 收尾节流**。
    ///
    /// 为什么不能直接用 `proxy.scrollTo(...)`：
    /// 流式 delta 是 20Hz 的。每来一段就起一段滚动动画，后一发打断前一发，
    /// 动画永远播不完；更要命的是每次 `scrollTo` 都拿"此刻"的内容高度去算目标
    /// 偏移量，而这个高度每 0.05 秒就变一次 —— 于是滚到一个"当时以为对、
    /// 下一帧就错"的位置。用户看到的就是：**画面被顶到内容之外，全屏空白，
    /// 得手滑几次才回来**。
    ///
    /// 节流规则：
    /// - 距上次滚动 ≥ 0.12 秒 → 立刻滚（前导），并重置窗口；
    /// - 窗口内再来 → 只登记一个收尾任务，窗口结束时补滚一次。
    ///   保证流式停下时不会永远差最后一小段。
    ///
    /// - Parameters:
    ///   - animated: 是否带动画。流式跟随不带动画（20Hz 上动画必然互相打断），
    ///               而"我发了消息"「点了回到底部」这类一次性动作要动画。
    ///   - force: 忽略节流窗口，立刻滚。用于消息数变化 / 收发状态切换 / 点浮钮。
    private func followBottom(_ proxy: ScrollViewProxy,
                              animated: Bool,
                              force: Bool = false) {
        let now = Date()
        let gap = now.timeIntervalSince(gate.lastAt)

        // 用 gate 而不是 self 捕获：闭包要读到**执行那一刻**的状态。
        let g = gate
        func commit() {
            g.lastAt = Date()
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }

        g.token &+= 1
        let mine = g.token

        if force || gap >= 0.12 {
            commit()
            return
        }

        // 窗口内：排一个收尾，把窗口剩下那点时间等满再滚。
        // 只做丢弃式节流的话，流式突然停下时屏幕上会永远差最后一小段没到底。
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.12 - gap)) {
            guard mine == g.token else { return }   // 已有更新的一发接管
            guard g.pinned else { return }          // 用户主动上翻看历史，别拽他回来
            commit()
        }
    }

    /// 布局"稳定之后"再补几次滚动。
    ///
    /// ⚠️ 2026-11-02 加（用户：「全屏时完全空白的，我还要去多滑动屏幕几次才能显示」）。
    ///
    /// 为什么一次滚动不够：
    /// 我们的正文是 `SelectableText`（包着 `UITextView`），高度走的是
    /// `sizeThatFits(proposal:)` —— **要等 UIView 建出来、文本灌进去才能量准**。
    /// 而 `scrollTo` 是在 body 重算那一帧就执行的，那一帧 `UITextView` 还是空的，
    /// 量出来的高度偏小，于是"滚到底"滚到的是一个**旧高度对应的位置**。
    /// 下一帧文本填进去、高度暴涨，滚动位置却已经定了 ——
    /// 画面就停在内容之外，一片空白。手动滑一下触发重新布局，位置才修正，
    /// 这正是用户说的"要多滑几次才显示"。
    ///
    /// 对策：在几个时间点各补一次（内容已经量准了，补滚是幂等的，
    /// 已经在底部时再滚一次不会有任何视觉变化）。
    private func settleScroll(_ proxy: ScrollViewProxy, delays: [Double]) {
        let g = gate
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                guard g.pinned else { return }
                g.lastAt = Date()
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text(store.base == nil ? "还没连上" : "有什么想聊的？")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if store.base == nil {
                VStack(spacing: 6) {
                    Text("在家连着家里 WiFi，出门有网络，打开就能用")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Button("重连") { Task { await store.bootstrap() } }
                        .font(.system(size: 13, weight: .medium))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - 消息气泡

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    attachmentsView(msg)
                    if msg.recalled {
                        // 2026-10-31 撤回功能：撤回后不直接消失。
                        // 用户要能看见「我撤过什么」，否则会怀疑自己到底发没发出去。
                        // 所以保留位置、灰显、加删除线，并标一行「已撤回」。
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text(msg.text.isEmpty ? "附件已撤回" : msg.text)
                                .font(.system(size: Theme.bodySize))
                                .strikethrough(true, color: .secondary)
                                .lineLimit(3)
                        }
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.card.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.25),
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // 撤错了怎么办：点一下这条灰掉的消息，把原文填回输入框。
                        // 为什么不给独立按钮：撤回是个小概率手滑的操作，
                        // 再挂一个按钮上去会让这条灰条变得比正常消息还热闹。
                        .onTapGesture { store.recallAndRestore(msg) }
                    } else if !msg.text.isEmpty || msg.attachments.isEmpty {
                        // 2026-10-31 换成 SelectableText：
                        // 用户要「长按弹窗包括所有」+「文字上能任意选词复制」，
                        // SwiftUI 原生 Text 满足不了（两个手势互斥），
                        // 所以改用 UITextView 底层实现，把撤回塞进系统选择菜单里。
                        SelectableText(
                            text: msg.text.isEmpty ? " " : msg.text,
                            onRecall: { store.recall(msg) },
                            onRecallAndEdit: { store.recallAndRestore(msg) }
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.045), radius: 5, y: 1)
                    }

                    // 气泡下面的「复制 / 撤回」（2026-10-31 用户：
                    // 「我发送出去的对话下面你没有加上复制和撤回的按钮」）。
                    //
                    // 之前只把这两个操作塞在长按菜单里，觉得省地方；
                    // 实际用起来没人知道要长按，等于没有。现在显式摆出来，
                    // 长按菜单里那两项也留着，两条路都能走。
                    if !msg.recalled, !msg.text.isEmpty {
                        HStack(spacing: 6) {
                            bubbleAction("复制", icon: "doc.on.doc") {
                                UIPasteboard.general.string = msg.text
                                Haptic.press()
                            }
                            bubbleAction("撤回", icon: "arrow.uturn.backward") {
                                store.recall(msg)
                            }
                            // 发送时间：官方要求消息显示时间，用户侧也需要 ——
                            // 否则"这句话是几点说的"只有 AI 侧有，看着不齐。
                            if let t = msgTimeText(msg) {
                                Text(t)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.quaternary)
                                    .padding(.leading, 1)
                            }
                        }
                        .padding(.top, 1)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                attachmentsView(msg)

                if !msg.text.isEmpty || msg.attachments.isEmpty {
                    // 2026-10-31 用户要求：「拷贝换成复制，拖动的样式和图中一样」。
                    //
                    // 这两件事（菜单文案、薄荷绿选区+手柄）只有底层 UITextView 做得到：
                    // SwiftUI `Text` 的 `.textSelection` 既不能改颜色，也不能改菜单名。
                    //
                    // 抖动怎么防的（上一版就是栽在这）：
                    //   1. 高度只由 `sizeThatFits(proposal:)` 一处算，并按 (文字, 宽) 缓存，
                    //      不再有 intrinsicContentSize 的回环 —— 见 SelectableText 里的注释；
                    //   2. **正在流式输出这条**仍然用轻量 `Text`：一句话每秒变好几次，
                    //      每次都重排一遍 UITextView 才是真的卡。等它说完再换成可选中的。
                    let streaming = store.sending && msg.id == store.messages.last?.id
                    if streaming {
                        // ⚠️ 2026-11-02：`.lineSpacing(5)` 必须和 SelectableText 里的
                        // `p.lineSpacing = 5` 完全一致。
                        // 上一版这里没写行距，用的是系统默认（约 0~2pt）；
                        // 等流式结束、控件从 Text 切到 SelectableText 时，
                        // 同一段字的总高度会突然变高一截 —— 列表跟着重排，
                        // 表现就是「回答快说完时整块跳一下」。
                        // 两处行距对齐后，切换前后高度一致，不会再跳。
                        Text(msg.text.isEmpty ? " " : msg.text)
                            .font(.system(size: Theme.bodySize))
                            .lineSpacing(5)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // ⚠️ 2026-11-02：换成按代码块分段的富渲染。
                        //
                        // 用户拿了张截图要求：「像这种的直接就有明显的颜色区分
                        // 后面还有一个小图标让我一键复制」。原来整条回复是
                        // 一块 UITextView —— 代码和正文混在一段里，没法在右上角
                        // 挂按钮，也没法给代码单独上色。
                        //
                        // 现在纯正文段仍是 SelectableText（选词/长按复制不变），
                        // 代码块单独成卡片：左上角语言、右上角两本书图标一键复制、
                        // 代码带语法配色、长命令横向滚动不换行。
                        AssistantBody(text: msg.text.isEmpty ? " " : msg.text,
                                      onRegenerate: { store.regenerate(msg) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // 这条回复产生的产物卡片。对齐原版：
                // 整宽、浅灰底、实心色图标、15.5pt 文件名，一条回复出几个就排几张。
                artifactCards(msg)

                // 「全部产物」入口：每条 AI 回复下面都要有。
                // 2026-10-31 用户明确纠正过：「我需要每条 ai 下面显示全部产物这个我需要」。
                // 字号/颜色照原版：15pt、正文字色，不是蓝色小链接。
                let all = lib.files(sessionId: store.currentSessionId)
                if !all.isEmpty {
                    Button {
                        inputFocused = false
                        showFiles = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("全部产物 (\(all.count))")
                                .font(.system(size: 15))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    // 纯文字、没有底色 → 光靠变暗看不出来，叠一层淡灰
                    .buttonStyle(PressableStyle(scale: 0.95, tint: 0.07, tintRadius: 9))
                    .padding(.top, 2)
                }

                // 底部一行：复制 + 重新生成 + 时间 + 模型名。
                //
                // 2026-11-02 按官方补了三样（用户：「官方点击按钮的方式和效果
                // 都搬过来」「对话的形式和滚动方式」）：
                //   · 发送时间 —— 官方：「已经进入对话流的消息会显示发送时间，并支持复制」
                //   · 重新生成 —— 官方：「长按某条 AI 回复，弹出操作菜单 →「重新生成」」
                //   · 已停止标记 —— 用户点了■之后，明确标出下面是断的
                //
                // 为什么「重新生成」只在非流式、非最后一条也显示：
                // 官方是任取一条都能重答。我们这条路径会把后面的对话暂存再挂回，
                // 所以不是最后一条也能用，不用特意限制。
                if !msg.model.isEmpty || !msg.text.isEmpty {
                    HStack(spacing: 8) {
                        if !msg.text.isEmpty {
                            bubbleAction("复制", icon: "doc.on.doc") {
                                UIPasteboard.general.string = msg.text
                                Haptic.press()
                            }
                            // 正在出的这条不给「重新生成」——它还没说完，
                            // 点了会同时停流 + 重开，动作叠加容易错乱
                            if !(store.sending && msg.id == store.messages.last?.id) {
                                bubbleAction("重新生成", icon: "arrow.clockwise") {
                                    store.regenerate(msg)
                                }
                            }
                        }
                        if msg.stopped {
                            Text("已停止")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.tile)
                                .clipShape(Capsule())
                        }
                        if let t = msgTimeText(msg) {
                            Text(t)
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)
                        }
                        if !msg.model.isEmpty {
                            Text(shortName(msg.model))
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .padding(.top, 1)
                }

                if msg.failed {
                    Button { Task { await store.retryLast() } } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(PressableStyle(scale: 0.95, tint: 0.07, tintRadius: 8))
                    .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 消息时间的显示文案。
    ///
    /// 2026-11-02 加（对齐官方：消息显示发送时间）。
    /// 分三档，避免每行都拖一个"2026-11-02 04:53"这种长串：
    ///   · 今天  → 04:53
    ///   · 昨天  → 昨天 21:10
    ///   · 更早  → 11-01 21:10
    /// 老数据的时间是 1970（见 StoredMessage.toChatMessage），返回 nil 直接不显示 ——
    /// 显示"70-01-01"比不显示更糟。
    private func msgTimeText(_ msg: ChatMessage) -> String? {
        let d = msg.at
        guard d.timeIntervalSince1970 > 0 else { return nil }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "MM-dd HH:mm"
        }
        return f.string(from: d)
    }

    /// 用户气泡下面那排小操作（复制 / 撤回）。
    ///
    /// 做成小胶囊而不是纯图标：图标两个字宽不到 10pt，点在白底上
    /// 完全看不出边界，用户会以为这行是装饰。胶囊至少有底、有边，
    /// 按下去还有一档缩放，能确认"我点到了"。
    private func bubbleAction(_ title: String,
                              icon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.sub)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            // 白底 + 细描边：页面底色本身就是 #F8F8F8，
            // 用浅灰底（Theme.tile）整颗胶囊会糊进背景里，等于没画。
            .background(Theme.card)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(fills: true))
    }

    @ViewBuilder
    private func attachmentsView(_ msg: ChatMessage) -> some View {        ForEach(msg.attachments) { a in
            if let img = a.preview {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 210, maxHeight: 210)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let d = a.durationText {
                            Text(d)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55))
                                .clipShape(Capsule())
                                .padding(5)
                        }
                    }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: fileSymbol(a.kind)).font(.system(size: 12))
                    Text(a.name).font(.system(size: 12)).lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func fileSymbol(_ k: Attachment.Kind) -> String {
        switch k {
        case .image: return "photo"
        case .video: return "video"
        case .text: return "doc.text"
        case .document: return "doc.richtext"
        case .binary: return "doc"
        }
    }

    // MARK: - 产物

    /// 这条回复落盘的所有产物。
    ///
    /// archiveReply 用「messages 里的下标」当 messageIndex，所以按 id 反查下标。
    /// 不按文本匹配：文本会被流式改动，下标在归档那一刻就固定了。
    /// 返回数组而不是单个 —— 一条回复将来可能同时出 md + 代码 + 图。
    private func artifacts(for msg: ChatMessage) -> [AIFile] {
        guard let idx = store.messages.firstIndex(where: { $0.id == msg.id }) else { return [] }
        return lib.files
            .filter { $0.sessionId == store.currentSessionId && $0.messageIndex == idx }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private func artifactCards(_ msg: ChatMessage) -> some View {
        let items = artifacts(for: msg)
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(items) { f in
                    artifactCard(f)
                }
            }
        }
    }

    /// 产物卡片。尺寸照原版截图量的：
    ///   整宽、圆角 14、浅灰底无描边、图标 42 圆角 11 实心色、
    ///   文件名 15.5、副标题 12.5、右上角一个 ↗。
    private func artifactCard(_ f: AIFile) -> some View {
        Button {
            inputFocused = false
            previewFile = f
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(f.kind.tint)
                        .frame(width: 42, height: 42)
                    Image(systemName: f.kind.icon)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(f.displayName)
                        .font(.system(size: 15.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("文件产物 · \(f.sizeText)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tile)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.95, fills: true))
        // 2026-11-01 用户：「这个产物我按住以后也要弹窗全部产物中的那种弹窗」。
        // 所以聊天里这张卡和「全部产物」列表里的那行长按菜单保持一致：
        // 打开 / 共享 / 保存 / 添加到对话。
        // 这里**不放**「打开对话」—— 这张卡本来就长在那个对话里，跳自己等于没用。
        .contextMenu {
            Button {
                previewFile = f
            } label: {
                Label("打开", systemImage: "eye")
            }
            Button {
                shareFile = f
            } label: {
                Label("共享", systemImage: "square.and.arrow.up")
            }
            Button {
                saveRequest = ExportRequest(urls: [f.url])
            } label: {
                Label("保存", systemImage: "folder.badge.plus")
            }
            Button {
                attachFile = f
            } label: {
                Label("添加到对话", systemImage: "text.bubble")
            }
        }
    }

    // MARK: - 错误提示

    private func errorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { store.errorText = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(PressableStyle(scale: 0.90, tint: 0.10, tintRadius: 999, darken: 0))
            }
            if store.capSuggestion != nil {
                Button { store.switchToFitModel() } label: {
                    let name = store.models.first(where: { $0.id == store.capSuggestion })?.display
                        ?? store.capSuggestion ?? ""
                    Label("换成「\(name)」", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PressableStyle(scale: 0.95))
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - 待发附件条

    // MARK: - 发送队列（2026-11-02，对齐 WorkBuddy 手机端）

    /// 输入框上方的队列条。
    ///
    /// 官方文档原文：「模型正在执行任务时，您可以继续发送消息，无需等待上一轮回复结束。
    /// 新消息会进入**输入框上方的队列**，等待当前一轮输出结束后依次处理。
    /// 队列中的消息支持**编辑、删除和拖动排序**。」
    ///
    /// 为什么必须给它一个可见的位置，而不是静默排队：
    /// 用户点了发送，如果界面上什么都没发生，他会以为没发出去，然后反复点。
    /// 摆出来之后"我这句已经在排队了"是看得见的，也知道什么时候轮到它。
    private var queueStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 10, weight: .semibold))
                Text("排队 \(store.queued.count) 条，这一轮说完就发")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
                Button("清空") {
                    store.queued.removeAll()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sub)
            }
            .foregroundStyle(Theme.sub)
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.queued) { q in
                        queueChip(q)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 6)
    }

    /// 队列里的一条。点一下编辑，长按/点叉删除。
    private func queueChip(_ q: ChatStore.QueuedMessage) -> some View {
        HStack(spacing: 6) {
            Text(q.text.isEmpty ? "（附件）" : q.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button {
                store.removeQueued(q.id)
                Haptic.press()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 7)
        .background(Theme.tile)
        .clipShape(Capsule())
        // 编辑：官方允许改队列里的内容。点开把文字填回输入框，
        // 同时把这条从队列里摘掉 —— 用户改完按发送自然就重新排队了，
        // 比做一个行内编辑器简单得多，也不会和键盘抢焦点。
        .onTapGesture {
            store.input = q.text
            store.pending = q.attachments
            store.removeQueued(q.id)
            inputFocused = true
        }
    }

    private var pendingStrip: some View {
        VStack(spacing: 0) {
            if let conflict = store.capConflict {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                    Text(conflict).font(.system(size: 11))
                    Spacer()
                    if let fit = store.capFitModels.first {
                        Button("换成 \(fit.display)") { store.currentModel = fit.id }
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.pending) { a in
                        ZStack(alignment: .topTrailing) {
                            if let img = a.preview {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            } else {
                                VStack(spacing: 2) {
                                    Image(systemName: fileSymbol(a.kind)).font(.system(size: 16))
                                    Text(a.name)
                                        .font(.system(size: 8))
                                        .lineLimit(1)
                                        .frame(width: 48)
                                }
                                .frame(width: 56, height: 56)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }

                            Button { store.removePending(a) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(PressableStyle(scale: 0.95))
                            .offset(x: 5, y: -5)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.page)
    }

    // MARK: - 输入栏（两行胶囊）

    /// 结构照截图：
    ///   第一行：输入框（占满宽度）
    ///   第二行：·)) 声波    💻 模型名 ⌄        ＋    [发送]
    ///
    /// 录音时**不再把整条胶囊换掉**，只把声波图标变红、显示一个小波形，
    /// 输入框始终在，所以焦点不会丢、键盘随时能弹。
    private var inputBar: some View {
        VStack(spacing: 0) {
            // 2026-11-01 用户：「聊天界面不要 workbuddy 的效果，我要咱们之前的那个」，
            // 并给了我们 1.8 那版的截图：**一颗胶囊分两行**
            //   上行：发消息或按住说话…（整行输入）
            //   下行：声波 · 绿点+模型名⌄ ……… ＋ · 圆形发送
            //
            // 之前按原版做成了单行（声波 + 输入 + ＋ + ↑），看着确实更像 WorkBuddy，
            // 但那是别人的样子。这一版回到我们自己的：模型名放回输入栏，
            // 想换模型不用先摸到顶栏第二行。
            VStack(spacing: 6) {
                TextField("发消息或按住说话…", text: $store.input, axis: .vertical)
                    .lineLimit(1...5)
                    // 用我们自己的正文字号，不跟原版截图走的那个数
                    .font(.system(size: Theme.bodySize))
                    .focused($inputFocused)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    // 声波 / 按住说话
                    HoldToTalkButton(voice: voice, disabled: store.sending,
                                     existingText: store.input) { finalText in
                        store.input = finalText
                    } onLive: { liveText in
                        store.input = liveText
                    } onStarted: {
                        inputFocused = false
                    }

                    // 连接灯 + 模型名 + 展开箭头。点一下开模型选择。
                    Button {
                        inputFocused = false
                        showModelPicker = true
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(linkColor)
                                .frame(width: 5, height: 5)
                            Text(modelTitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.sub)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.sub.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, tint: 0.07, tintRadius: 10, darken: 0))

                    Spacer(minLength: 4)

                    // 加号：附件
                    Button { inputFocused = false; showAttach = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.86, tint: 0.10, tintRadius: 999, darken: 0))
                    .disabled(store.sending)

                    // 圆形主按钮。三种状态，对齐 WorkBuddy 手机端：
                    //
                    //   ① 正在输出 + 输入框是空的 → **停止键（■）**
                    //      官方：「任务进行中时，输入栏会显示停止按钮（■），
                    //      点击可随时中断当前执行。」这是最要紧的一个 ——
                    //      发现它答偏了，能立刻叫停，不用干等烧完积分。
                    //   ② 正在输出 + 输入框有内容 → **排队键**
                    //      官方：「新消息会进入输入框上方的队列」。
                    //   ③ 空闲 → 发送（↑）
                    //
                    // 2026-11-01 保留的规矩：按钮**常驻**，不做"有内容才出现"，
                    // 否则打第一个字时整行往左挤 30pt，输入栏会跳一下。
                    Button { primaryAction() } label: {
                        Image(systemName: primaryIcon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(primaryEnabled ? Theme.card : Theme.sub)
                            .frame(width: 30, height: 30)
                            // 可点 = 深灰实心（和底栏选中块同色），
                            // 不可点 = 系统三级填充灰。全站统一这一个"重"色。
                            .background(primaryEnabled ? Theme.press : Color(.tertiarySystemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.88))
                    .disabled(!primaryEnabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 1)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)

            if let e = voice.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                    Text(e)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { voice.error = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(PressableStyle(scale: 0.90, tint: 0.10, tintRadius: 999, darken: 0))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .background(Theme.page)
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75))
                    .clipShape(Capsule())
                    .offset(y: -30)
                    .transition(.opacity)
            }
        }
        // 附件弹层已上移到根视图的 overlay（见 body 里那段注释）：
        // 挂在这里时 overlay 只有输入栏那么大，遮罩盖不满屏幕，点空白关不掉。
    }

    /// 主按钮当前该显示什么图标。
    private var primaryIcon: String {
        if voice.recording { return "stop.fill" }
        // 正在输出：有内容 → 排队；没内容 → 停止
        if store.willQueue {
            return store.canSend ? "text.line.last.and.arrowtriangle.forward" : "stop.fill"
        }
        return "arrow.up"
    }

    /// 主按钮能不能点。
    private var primaryEnabled: Bool {
        if voice.recording { return true }
        // 正在输出时永远可点：输入框有内容就排队，空的就停止。
        if store.willQueue { return store.canSend || streamRunning }
        return store.canSend
    }

    /// 当前是不是真的有一轮在跑（用来区分"能停止"和"只能排队"）。
    private var streamRunning: Bool { store.sending }

    /// 主按钮动作：录音 / 停止 / 排队 / 发送，四选一。
    private func primaryAction() {
        // ① 录音中点 = 先停止，停完用户自己再点一次
        if voice.recording {
            voice.stop()
            return
        }
        // ② 正在输出 + 输入框有内容 = 排进队列（不打断当前这轮）
        if store.willQueue {
            if store.canSend {
                store.enqueueCurrentInput()
                Haptic.press()
                inputFocused = false
            } else {
                // ③ 正在输出 + 输入框空的 = 停止
                store.stopStreaming()
                Haptic.press()
            }
            return
        }
        // ④ 空闲 = 正常发送
        guard store.canSend else { return }
        inputFocused = false
        // send() 自己建 Task（为了撤回能掐断），所以这里不再包 Task。
        store.send()
        Task {
            // 发完立刻探一次灯，让用户马上看到通没通
            await store.pingNow()
        }
    }

    // MARK: - 照片/视频载入

    /// PhotosPicker 选中的可能是图片也可能是视频，按类型分别处理
    private func loadPicked(_ items: [PhotosPickerItem]) async {
        let picked = items
        photoItems = []

        for it in picked {
            guard let type = it.supportedContentTypes.first else { continue }
            let isVideo = type.conforms(to: .movie) || type.conforms(to: .video)

            if isVideo {
                // 视频要落到临时文件才能读，用 loadTransferable 拿 Data 再写盘
                if let data = try? await it.loadTransferable(type: Data.self) {
                    let ext = type.preferredFilenameExtension ?? "mov"
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
                    if (try? data.write(to: tmp)) != nil {
                        await MainActor.run { store.addVideo(tmp) }
                        try? FileManager.default.removeItem(at: tmp)
                    } else {
                        await MainActor.run { store.toast = "视频保存失败" }
                    }
                } else {
                    await MainActor.run { store.toast = "这个视频读不出来（可能是 iCloud 未下载）" }
                }
            } else {
                if let data = try? await it.loadTransferable(type: Data.self) {
                    await MainActor.run { store.addImageData(data, name: "照片.jpg") }
                } else {
                    await MainActor.run { store.toast = "这张图读不出来（可能是 iCloud 未下载）" }
                }
            }
        }
    }
}

// MARK: - 附件弹层

/// 自绘的「添加附件」弹层。
///
/// 为什么不用 confirmationDialog：它和页面上的多个 sheet / photosPicker /
/// fileImporter 挂在同一层时，iOS 会互相打断，表现就是"点了加号什么也没发生"。
/// 自绘 overlay 没有这个问题，而且样式能跟 App 统一。
private struct AttachSheet: View {
    let onPhoto: () -> Void
    let onCamera: () -> Void
    let onFile: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // 用 GeometryReader 而不是 ZStack + Spacer 撑开：
        // Spacer 本身不参与命中测试，看起来没问题，但它把面板推到底部的同时
        // 也让整个 VStack 覆盖了上方区域。改成「遮罩铺满 + 面板贴底」两层，
        // 上层只有面板那块有可点内容，空白处一律落到遮罩上，
        // 这样「点空白收回」才是确定的，不依赖 Spacer 的命中行为。
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 遮罩必须显式 contentShape：
                // 纯 Color 在某些情况下命中测试会穿透到下面几层，
                // 表现为"点了没反应"。加一行 contentShape 就不用赌系统行为。
                Color.black.opacity(0.24)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }

                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        row("照片或视频", "photo.on.rectangle", onPhoto)
                        Divider().padding(.leading, 52)
                        row("拍照", "camera", onCamera)
                        Divider().padding(.leading, 52)
                        row("文件", "folder", onFile)
                    }
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)

                    Button { onCancel() } label: {
                        Text("取消")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.95, fills: true))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                }
            }
            // 让遮罩一直延伸到刘海和底部 Home 条外面，
            // 否则状态栏那一条点下去会落到下面的聊天页上
            .ignoresSafeArea()
        }
        .transition(.opacity)
    }

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        // 整行没有自己的底色，按下要整行泛灰才看得出选的是哪一行
        .buttonStyle(PressableStyle(scale: 0.98, tint: 0.07, tintRadius: 0, darken: 0))
    }
}

// MARK: - 后台面板页

/// 「后台面板」Tab：App 内嵌网页后台，首次输一次密钥就自动登录。
private struct AdminTabPage: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store: ChatStore
    @State private var key = AdminKey.load()
    @State private var tick = 0
    @State private var editingKey = false
    @State private var keyDraft = ""
    /// 网页是否还在加载。用来盖住白屏期（2026-10-31 加）。
    @State private var webLoading = true
    /// 是否已经成功载入过一次。用来区分「首次进入」和「切回来」。
    @State private var everLoaded = false
    /// 是不是用户主动点了「刷新」。和首屏加载分开：首屏不给"已刷新"时间。
    @State private var refreshing = false
    /// 上一次加载完成的时间，显示在地址下面一行。
    @State private var lastLoaded: Date?
    /// 兜底复位：万一 didFinish / didFail 一个都不来（后台卡住、网页一直转），
    /// 8 秒后自己把转圈收掉，免得按钮永远停在「刷新中」变成死键。
    @State private var refreshGuard: DispatchWorkItem?

    private var base: String {
        // 优先用当前实际在用的地址：在家是内网、在外是域名
        store.base ?? settings.lanBase
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：按钮行 + 标题块（2026-10-31 用户要求：
            //   1. 左上角加返回
            //   2. 整页往下挪，别紧贴状态栏
            //   3. 三个按钮都用胶囊，按下去要有反应）
            //
            // 为什么按钮单独占一行：标题 + 三个胶囊挤一行，
            // 胶囊会被压成"三个小圆点"，白做。分两行以后
            // 按钮有 34 高、标题也有自己的呼吸空间，往下挪的问题一起解决。
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    // 2026-11-01：「返回」不再用黑底 —— 三个胶囊统一成和
                    // 聊天页右上角那颗一样的白底，按下去变深灰。
                    PillButton(title: "返回", icon: "chevron.left") {
                        store.tab = .tasks
                    }
                    Spacer(minLength: 6)
                    // 2026-11-01 用户：「后台面板右上角的刷新按键移除不用了」。
                    // 删掉之后这里只留「密钥」；网页自己会在切回这个 Tab 时重载，
                    // 改完密钥也会自动重载（见 alert 里保存那段），不需要手动刷新。
                    PillButton(title: "密钥", icon: "key.fill") {
                        keyDraft = key
                        editingKey = true
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("后台面板")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(base)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                        if let t = lastLoaded {
                            Text("· 已刷新 \(clock(t))")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub.opacity(0.85))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Theme.page)

            // 底部 Tab 已经常驻，网页不能再 ignoresSafeArea(.bottom)：
            // 那样网页最后一行会钻到 Tab 栏底下点不到。
            // 这里让它只铺到 Tab 之上，四周留 12 的圆角卡片感，和演示图一致。
            AdminWebView(base: base, key: key, reloadTick: tick, loading: $webLoading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                // 加载态盖在网页上。为什么不直接用 ProgressView 顶掉 WebView：
                // 顶掉会让 WebView 从视图树里消失、尺寸归零，回来又得重排重绘。
                // 这里用 overlay 叠一层，WebView 始终在位。
                //
                // 2026-11-01：条件从 `webLoading && !everLoaded` 改成只看 `webLoading`。
                // 原来只有第一次进入才盖，之后点「刷新」网页白着重新加载，
                // 屏幕上一点变化都没有 —— 用户说「不知道是不是在刷新」就是这个。
                .overlay {
                    if webLoading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(refreshing ? "正在刷新…"
                                            : (everLoaded ? "正在重新载入…" : "正在载入后台…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 用淡淡的半透明而不是整片白：刷新时下面的网页还在，
                        // 能看到它正在重绘，比一片白更有"在动"的感觉。
                        .background(Theme.page.opacity(refreshing ? 0.82 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: webLoading)
                .onChange(of: webLoading) { v in
                    guard !v else { return }
                    everLoaded = true
                    // 加载结束（成功或失败）都要收掉「刷新中」，
                    // 否则按钮会永远停在转圈上。
                    refreshGuard?.cancel()
                    refreshGuard = nil
                    refreshing = false
                    lastLoaded = Date()
                }
        }
        .background(Theme.page)
        .alert("后台管理密钥", isPresented: $editingKey) {
            TextField("access_key", text: $keyDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                AdminKey.save(keyDraft)
                key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                startRefresh()
            }
        } message: {
            Text("填一次就记住了，以后进后台不用再输。")
        }
    }

    /// 触发一次重新加载，并把界面切成「刷新中」。
    ///
    /// 2026-11-01 新增。之前刷新只是一个 `tick += 1`，
    /// 界面上没有任何一处跟着变 —— 用户点完只能靠"猜"。
    private func startRefresh() {
        refreshing = true
        webLoading = true
        tick += 1

        // 8 秒兜底：网页卡住不回调时自己复位，别让按钮变成死键
        refreshGuard?.cancel()
        let g = DispatchWorkItem {
            guard refreshing else { return }
            refreshing = false
            webLoading = false
            lastLoaded = Date()
        }
        refreshGuard = g
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: g)
    }

    /// 只显示时分，不显示秒 —— 刷新时间精确到秒没有意义，还会让那行字一直变宽变窄
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 底部锚点的位置上报

/// 把「底部锚点在视口坐标系里的纵坐标」往上送一层。
///
/// 2026-11-02：流式跟随要靠它判断用户有没有贴在底部。
/// 用一个专门的 PreferenceKey 而不是 `@State` + `onAppear`：
/// 滚动过程中这个值一直在变，只有 preference 能跟着滚动实时刷新。
private struct BottomAnchorY: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 「正在执行」卡片

/// 等回复期间显示在对话流里的一张可展开卡片。
///
/// 2026-11-02 建，对齐 WorkBuddy 手机端「步骤拆解」的形态：
/// 官方是「拆解为 N 个步骤」+「已完成」标签 + 点右侧 > 展开看详细过程。
///
/// 我们和官方最大的区别必须说清楚：**我们不是多步 Agent**，
/// 这一轮就是一次流式请求，没有工具调用、没有子步骤。
/// 所以不能照着编一个"N 个步骤、全部已完成"——那是假的。
/// 这里只如实报三个真实信息：连的哪、用的什么模型、等了多久。
/// 卡片形态（灰底、可展开、右侧箭头）照官方，内容只写真有的。
private struct ThinkingCard: View {
    @ObservedObject var store: ChatStore
    let startedAt: Date

    @State private var expanded = false
    /// 每秒跳一次的秒数。用 Timer 而不是 TimelineView：
    /// 卡片只在等回复时存在（几秒到几十秒），一个 1Hz 的 Timer 开销可以忽略，
    /// 而且 TimelineView 会让这张卡片在滚动时也持续重绘。
    @State private var seconds = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                Haptic.tap()
            } label: {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                        .frame(width: 14, height: 14)

                    Text(headline)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if seconds >= 3 {
                        Text("\(seconds)s")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    detailRow("状态", "正在等上游返回")
                    detailRow("地址", store.base ?? "—")
                    detailRow("模型", store.effectiveModel.isEmpty ? "—" : store.effectiveModel)
                    detailRow("已等待", "\(seconds) 秒")
                    if store.retrying {
                        detailRow("重试", "断线了，正在换地址重发")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { startTick() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private var headline: String {
        if store.retrying { return "正在换地址重试…" }
        if seconds < 2 { return "正在连接…" }
        return "正在回答…"
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(v)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func startTick() {
        seconds = Int(Date().timeIntervalSince(startedAt))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                seconds = Int(Date().timeIntervalSince(startedAt))
            }
        }
    }
}


// MARK: - 我的（直接显示设置页）

/// 「我的」Tab 点进去直接就是设置内容，不再是弹窗。
/// 用 NavigationStack 包着，因为设置里有些条目（连接诊断、模型能力）要能点进去。
private struct MineTabPage: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        SettingsView(store: store, embedded: true)
            .background(Theme.page)
    }
}
