import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    /// 抽屉里的「我的文件」。和抽屉共用外层弹层，抽屉自己不挂 sheet。
    @State private var showFiles = false
    /// 点产物卡片 → 预览；预览里点分享 → 换成分享面板
    @State private var previewFile: AIFile?
    @State private var shareFile: AIFile?

    @FocusState private var inputFocused: Bool

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
                           onOpenFiles: { showFiles = true })
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
            MyFilesView(store: store, embedded: true)
                .roundSheet(28)
        }
        // 产物卡片的预览 / 分享
        .sheet(item: $previewFile) { f in
            NavigationStack {
                QuickLookView(url: f.url)
                    .ignoresSafeArea()
                    .navigationTitle(f.title)
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
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in store.addImage(img) }
                .roundSheet(28)
        }
        // 模型选择挂在整个页面最外层，不能挂在输入栏上 ——
        // 挂输入栏时 GeometryReader 只能拿到输入栏那几十 pt 高度，
        // 半屏算出来就变成一条窄带。挂根层才能拿到整屏高度。
        .overlay {
            if showModelPicker {
                ModelPickerSheet(store: store,
                                 onClose: { showModelPicker = false })
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for u in urls { store.addFile(u) }
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

    // MARK: - 主列

    private var mainColumn: some View {
        VStack(spacing: 0) {
            switch store.tab {
            case .tasks:
                topBar
                messagesArea
                if let err = store.errorText { errorBanner(err) }
                if !store.pending.isEmpty { pendingStrip }
                inputBar
            case .admin:
                AdminTabPage(store: store)
            case .mine:
                MineTabPage(store: store)
            }
            if store.tab != .admin { bottomTabBar }
        }
        .background(Theme.page)
        .contentShape(Rectangle())
        // 从屏幕左缘往右滑打开抽屉。
        // **只在「任务」页生效** —— 用户明确要求「侧抽只能聊天界面才能生效」。
        // 后台面板是网页、我的页是设置列表，在那里侧滑出抽屉既意外又容易误触。
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { g in
                    guard !drawerOpen else { return }
                    let horizontal = abs(g.translation.height) < 70
                    if store.tab == .tasks {
                        // 聊天页：左缘右滑 → 出抽屉
                        if g.startLocation.x < 30, horizontal,
                           g.translation.width > 70 {
                            openDrawer()
                        }
                    } else if horizontal, g.translation.width < -70 {
                        // 后台面板 / 我的：左滑返回聊天页。
                        // 用户要求「不管到哪个界面都应该左滑返回上个界面」。
                        inputFocused = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.tab = .tasks
                        }
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
                                if store.tab == t {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary)
                                        .frame(width: 27, height: 23)
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
                    .buttonStyle(.plain)
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
            .buttonStyle(.plain)

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
            .buttonStyle(.plain)

            // 右侧：一个白胶囊里并排两个图标（新建 / 更多），照截图
            HStack(spacing: 0) {
                Button { store.newSession(); store.tab = .tasks } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button { store.syncCurrentSession() } label: {
                        Label("保存会话", systemImage: "tray.and.arrow.down")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.reset()
                        store.syncCurrentSession()
                    } label: {
                        Label("清空会话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 3)
            .background(Theme.card)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.messages.isEmpty { emptyHint }
                    ForEach(store.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    if store.sending {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("正在回答…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .onChange(of: store.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.sending) { v in
                if v { proxy.scrollTo("thinking", anchor: .bottom) }
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
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
                    if !msg.text.isEmpty || msg.attachments.isEmpty {
                        Text(msg.text.isEmpty ? " " : msg.text)
                            .font(.system(size: 15.5))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: Color.black.opacity(0.045), radius: 5, y: 1)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                attachmentsView(msg)

                if !msg.text.isEmpty || msg.attachments.isEmpty {
                    Text(msg.text.isEmpty ? " " : msg.text)
                        .font(.system(size: 15.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 这条回复落盘的那份产物（ChatStore.archiveReply 写的）
                if let f = artifact(for: msg) {
                    artifactCard(f)
                }

                // 整个会话的产物入口。只有真的存到了东西才显示，
                // 免得每条回复下面都挂一个「全部产物 (0)」。
                let all = lib.files(sessionId: store.currentSessionId)
                if !all.isEmpty {
                    Button {
                        inputFocused = false
                        showFiles = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .medium))
                            Text("全部产物 (\(all.count))")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !msg.model.isEmpty {
                    Text(shortName(msg.model))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .padding(.top, 1)
                }

                if msg.failed {
                    Button { Task { await store.retryLast() } } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func attachmentsView(_ msg: ChatMessage) -> some View {
        ForEach(msg.attachments) { a in
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

    // MARK: - 产物卡片

    /// 这条回复对应的那个文件。
    ///
    /// archiveReply 存的时候用「messages 里的下标」当 messageIndex，
    /// 所以这里按 id 反查下标，再在文件库里按 (会话, 下标) 找。
    /// 不按文本匹配：文本会被流式改动，下标在归档那一刻就固定了。
    private func artifact(for msg: ChatMessage) -> AIFile? {
        guard let idx = store.messages.firstIndex(where: { $0.id == msg.id }) else { return nil }
        return lib.files.first {
            $0.sessionId == store.currentSessionId && $0.messageIndex == idx
        }
    }

    private func artifactCard(_ f: AIFile) -> some View {
        Button {
            inputFocused = false
            previewFile = f
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: f.kind.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.fileName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(f.kind.label) · \(f.sizeText)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
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
                .buttonStyle(.plain)
            }
            if store.capSuggestion != nil {
                Button { store.switchToFitModel() } label: {
                    let name = store.models.first(where: { $0.id == store.capSuggestion })?.display
                        ?? store.capSuggestion ?? ""
                    Label("换成「\(name)」", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - 待发附件条

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
                            .buttonStyle(.plain)
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
            VStack(alignment: .leading, spacing: 6) {
                // ---- 第一行：输入框 ----
                TextField("发消息...", text: $store.input, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 16))
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                // ---- 第二行：工具条 ----
                HStack(spacing: 10) {
                    HoldToTalkButton(voice: voice, disabled: store.sending,
                                     existingText: store.input) { finalText in
                        // 最终结果（已经拼好原有文字），直接写回输入框
                        store.input = finalText
                    } onLive: { liveText in
                        // 边说边显示：直接写进输入框，用户看到的字在长
                        store.input = liveText
                    } onStarted: {
                        // 开始听的时候收起键盘，免得两套输入打架
                        inputFocused = false
                    }

                    // 模型下拉：点它在这个位置正上方弹出选择面板
                    Button { inputFocused = false; showModelPicker = true } label: {
                        HStack(spacing: 4) {
                            // 模型名前也有个小灯，和顶栏同一份数据
                            Circle()
                                .fill(linkColor)
                                .frame(width: 5, height: 5)
                            Text(modelTitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: 190, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    // 加号：附件。用户说它已经能选文件了，保持不动
                    Button { inputFocused = false; showAttach = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.sending)

                    // 发送：胶囊样式「发送」两个字，颜色跟加号一致
                    Button { sendIfPossible() } label: {
                        Text(voice.recording ? "停止" : "发送")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(canTapSend ? Theme.card : Theme.sub)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(canTapSend ? Color.primary : Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canTapSend)
                    .animation(.easeOut(duration: 0.15), value: canTapSend)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
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
                    .buttonStyle(.plain)
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
        // 附件菜单改成自绘弹层（放在顶部对齐的 overlay 里），
        // 不再用 confirmationDialog —— 之前它和几个 sheet 挂同一层会互相吞掉，
        // 点了加号没反应就是这个原因。
        .overlay {
            if showAttach {
                AttachSheet(
                    onPhoto: { showAttach = false; showPhotoPicker = true },
                    onCamera: { showAttach = false; showCamera = true },
                    onFile: { showAttach = false; showFilePicker = true },
                    onCancel: { showAttach = false }
                )
            }
        }
    }

    /// 发送键能不能点。录音中允许点（用来「停止」），有内容才允许发。
    private var canTapSend: Bool {
        if voice.recording { return true }
        return store.canSend
    }

    private func sendIfPossible() {
        // 录音中点发送 = 先停止；停完用户自己再点一次发送
        if voice.recording {
            voice.stop()
            return
        }
        guard store.canSend else { return }
        inputFocused = false
        Task {
            await store.send()
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
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                Spacer()
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
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
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
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var base: String {
        // 优先用当前实际在用的地址：在家是内网、在外是域名
        store.base ?? settings.lanBase
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标题 + 两个按钮（刷新 / 改密钥）
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台面板")
                        .font(.system(size: 17, weight: .semibold))
                    Text(base)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    tick += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Theme.card)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    keyDraft = key
                    editingKey = true
                } label: {
                    Image(systemName: "key")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Theme.card)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            // 顶部 8 → 16：标题原来贴着状态栏时间，用户反馈「整体往下」
            .padding(.top, 16)
            .padding(.bottom, 10)
            .background(Theme.page)

            AdminWebView(base: base, key: key, reloadTick: tick)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.page)
        .alert("后台管理密钥", isPresented: $editingKey) {
            TextField("access_key", text: $keyDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                AdminKey.save(keyDraft)
                key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                tick += 1
            }
        } message: {
            Text("填一次就记住了，以后进后台不用再输。")
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
