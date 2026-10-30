import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 聊天主界面（仿 WorkBuddy 手机端）

/// 布局对齐 WorkBuddy：
///   顶栏：左侧圆形菜单按钮 + 中间两行（模型名 / 连接状态）+ 右侧两个圆按钮
///   对话区：AI 回复无气泡左对齐带模型小标，用户消息右侧着色气泡
///   输入区：悬浮胶囊（加号 / 输入框 / 按住说话 / 发送）
///   抽屉：左侧滑出，任务列表按时间分组
struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    @StateObject private var voice = VoiceInput()

    @State private var showModelPicker = false
    @State private var showSettings = false
    @State private var showDiag = false
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []

    @State private var drawerOpen = false

    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            mainColumn

            if drawerOpen {
                // 遮罩按参考图采到的 #ADADAD 反推 ≈ 30% 黑，
                // 比我原来用的 26% 略重一点，抽屉的"压过去"感更明显
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }

                DrawerView(store: store, onClose: { closeDrawer() })
                    .frame(width: DrawerView.width)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(edges: .vertical)
                    .transition(.move(edge: .leading))
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showDiag) { NavigationStack { DiagView() } }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("添加", isPresented: $showAttachMenu, titleVisibility: .hidden) {
            Button("照片或视频") { showPhotoPicker = true }
            Button("拍照") { showCamera = true }
            Button("文件") { showFilePicker = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .sheet(isPresented: $showCamera) { CameraPicker { img in store.addImage(img) } }
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
            default:
                otherTabPage(store.tab)
            }
            bottomTabBar
        }
        .background(Theme.page)
        .contentShape(Rectangle())
        // 从屏幕左缘往右滑打开抽屉。只在起点靠左、主要横向移动时触发，
        // 不会抢走消息列表的纵向滚动。
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { g in
                    guard !drawerOpen else { return }
                    if g.startLocation.x < 30,
                       g.translation.width > 70,
                       abs(g.translation.height) < 70 {
                        openDrawer()
                    }
                }
        )
    }

    // MARK: - 底部导航

    /// 结构照 WorkBuddy：四个图标 + 下方小字，选中态是深色实心图标 + 深色文字。
    /// 原版选中时图标底色是个小圆角方块，这里用同样的处理。
    private var bottomTabBar: some View {
        // 参考图的 Tab 栏上方没有分隔线，颜色和消息区完全一样。
        // 所以这里只有一条透明的背景，靠"图标离得远"来分区。
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

    // MARK: - 其它 Tab 页

    /// 原版另外三个 Tab 在咱们这边没有对应功能：
    /// 「定时任务」= WorkBuddy 的定时执行；「发现」= 官方内容广场；「我的」= 账号与会员。
    /// 不假装做出来，明说还没接，并给出能做的替代入口。
    @ViewBuilder
    private func otherTabPage(_ t: MainTab) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(t.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: t.icon)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)

                    Text(explain(t))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 28)

                    VStack(spacing: 10) {
                        switch t {
                        case .scheduled:
                            // 中转站本身就有「自动签到 / 自动升级」这类定时任务，
                            // 只是它们在网页后台里，这里给个直达入口。
                            Button {
                                adminJump()
                            } label: {
                                Label("打开中转站后台看定时任务", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        case .discover:
                            EmptyView()
                        case .mine:
                            Button { showSettings = true } label: {
                                Label("打开设置", systemImage: "gearshape")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { showDiag = true } label: {
                                Label("连接诊断", systemImage: "stethoscope")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func explain(_ t: MainTab) -> String {
        switch t {
        case .scheduled:
            return "WorkBuddy 这边的「定时任务」是让电脑按时间自动跑任务。\n\n咱们的中转站没有这个概念，但路由器上确实有定时活（自动签到、自动升级、地址上报），这些在网页后台里能看到，点下面直接过去。"
        case .discover:
            return "这一栏在 WorkBuddy 里是官方内容广场（模板、案例、插件推荐）。\n\n咱们是自建中转站，没有这套内容源，所以这里空着。想找能用的模型，去「任务」页点顶部标题就能切换。"
        case .mine:
            return "WorkBuddy 的「我的」是账号、会员、积分这些。\n\n咱们这边对应的是中转站设置：密钥、模型来源、连接状态都在里面。"
        default:
            return ""
        }
    }

    private func adminJump() {
        // 优先用当前实际在用的地址，在家就是内网、在外就是域名
        let raw = store.base ?? settings.lanBase
        if let u = URL(string: raw) {
            UIApplication.shared.open(u)
        }
    }

    // MARK: - 顶栏

    /// 结构照 WorkBuddy：
    ///   [≡]  任务标题（左对齐，粗体 17）      [+]  [⋯]
    ///        🖥 设备名 | 任务 ▸
    /// 原版标题是左对齐的，不是居中——居中会让长标题两侧留白很怪。
    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            circleButton("line.3.horizontal") { openDrawer() }
                .padding(.top, 2)

            Button { showModelPicker = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.currentSessionTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(store.deviceLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("|")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                        Text(placeShort)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 原版右侧是两个：一个「+」、一个「⋯」，都是纯图标、无底色
            Button { store.newSession() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            Menu {
                Button { store.syncCurrentSession() } label: {
                    Label("保存当前对话", systemImage: "tray.and.arrow.down")
                }
                Button { showModelPicker = true } label: {
                    Label("切换模型", systemImage: "cpu")
                }
                Button { showDiag = true } label: {
                    Label("连接诊断", systemImage: "stethoscope")
                }
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) { store.reset() } label: {
                    Label("清空当前对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // 顶栏不单独上色，直接透出页面底色 —— 参考图整页是同一块 #F8F8F8，
        // 中间没有任何分隔线，加了分隔线就会碎成"上中下三块"。
        .background(Theme.page)
    }

    /// 顶栏副行里的场景短标签（对齐原版「任务 ▸」那个位置的语气）
    private var placeShort: String {
        if store.detecting && store.base == nil { return "连接中" }
        switch store.place {
        case .home: return "在家"
        case .away: return "在外"
        case .unknown: return store.base == nil ? "连接中" : "已连接"
        }
    }

    /// 顶栏和抽屉里的圆形按钮。
    ///
    /// 参考图上这些按钮**没有底色**（按钮中心的像素和页面背景一模一样），
    /// 就是一枚纯图标。所以这里不要加 background，加了就会多出一圈灰饼。
    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            // 原版用户消息是右侧**白色**圆角块 + 黑字，靠一层极淡阴影从
            // #F8F8F8 底色上浮起来。不是蓝色气泡（微信那一套），
            // 也不是灰气泡 —— 灰度差太小会糊在一起，白色反而更清楚。
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
            // AI 回复：无气泡、左对齐、正文黑字。原版就是这样，
            // 也不显示模型名小标（模型在顶栏标题里）。这里保留一个小标，
            // 因为咱们一个任务里可能中途切换模型，标出来更有用。
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
            // 连不上时给个直达诊断的入口
            if store.base == nil {
                Button { showDiag = true } label: {
                    Label("连接诊断", systemImage: "stethoscope")
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

    // MARK: - 输入栏（悬浮胶囊）

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if voice.recording {
                    // 录音态：波形 + 实时识别，占住整条胶囊
                    Image(systemName: "waveform")
                        .font(.system(size: 17))
                        .foregroundStyle(.red)
                    Text(voice.partial.isEmpty ? "正在听…" : voice.partial)
                        .font(.system(size: 16))
                        .foregroundStyle(voice.partial.isEmpty ? Theme.sub : Color.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    // 左边声波 = 按住说话。参考图上它就是一枚纯图标，
                    // 没有圆底、没有"语音"两个字。
                    HoldToTalkButton(voice: voice, disabled: store.sending) { text in
                        // 识别结果填进输入栏，光标落到末尾、键盘弹出，
                        // 由你自己确认后再点发送 —— 不自动发出去。
                        if store.input.isEmpty {
                            store.input = text
                        } else if store.input.hasSuffix(" ") || store.input.hasSuffix("\n") {
                            store.input += text
                        } else {
                            store.input += " " + text
                        }
                        inputFocused = true
                    }

                    TextField("发消息或按住说话...", text: $store.input, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(size: 16))
                        .focused($inputFocused)
                        .padding(.vertical, 4)

                    // 右边：空的时候是「+」（加附件），写了字就换成「↑」发出去。
                    // 用 hasDraft 而不是 store.canSend 判断 —— canSend 在发送中会变 false，
                    // 拿它做判断会让按钮在发送瞬间跳回加号，看着像卡了一下。
                    if hasDraft {
                        Button { sendIfPossible() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.card)
                                .frame(width: 30, height: 30)
                                .background(Color.primary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canSend)
                        .opacity(store.canSend ? 1 : 0.4)
                    } else {
                        Button { showAttachMenu = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Theme.inkSoft)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.sending)
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
            .frame(minHeight: 54)
            .floatingCard(corner: 27)
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
    }

    /// 输入框里有没有"待发出去的东西"（文字或附件）。
    ///
    /// 单独拎出来是因为不能直接用 store.canSend 判断显示「+」还是「↑」：
    /// canSend 在"正在发送"时会变成 false，拿它当判断会让按钮在点击瞬间
    /// 跳回加号，看起来像点了没反应。
    private var hasDraft: Bool {
        !store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.pending.isEmpty
    }

    private func sendIfPossible() {
        guard store.canSend else { return }
        inputFocused = false
        Task { await store.send() }
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
