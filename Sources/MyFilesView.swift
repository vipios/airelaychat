import SwiftUI

// MARK: - 产物面板

/// AI 产物的列表，半屏圆角弹出。
///
/// 2026-10-31 按用户要求重做（对标 WorkBuddy 手机端）：
///   - 平铺，不再按会话分组、「全部产物」四个字指的就是这一屏
///   - 图标分色：md 青 / 图片蓝 / 代码紫 / 其他蓝
///   - 文件名去掉尾部时间戳（磁盘上还留着，防重名）
///   - 长按进多选，可批量分享、批量删除
///
/// `sessionId` 传了就看这个对话的产物（聊天页尾端「全部产物」进来），
/// 不传就看整个文件库（抽屉「我的文件」进来）。目前只有一个对话，
/// 两者内容一样，但语义分开——以后真做了多会话就不用改这里。
struct MyFilesView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var lib = FileLibrary.shared
    var embedded: Bool = false
    var sessionId: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var preview: AIFile?
    @State private var sharing: [AIFile] = []
    @State private var confirmDelete: AIFile?
    /// 长按「保存」：交给系统「存到哪里」面板（文件 App / iCloud 云盘）
    @State private var exportRequest: ExportRequest?
    /// 长按「添加到对话」：先挂起，等用户在会话列表里选一个
    @State private var attachFile: AIFile?
    /// 多选模式
    @State private var picking = false
    @State private var picked: Set<String> = []
    @State private var confirmBatch = false
    /// 旧版误存的聊天记录（纯文字、没有代码块），扫出来给用户一键清
    @State private var staleIds: Set<String> = []
    @State private var confirmPurge = false
    /// 就地展开的那几个（点产物 = 展开/收起，不跳转）
    @State private var expanded: Set<String> = []
    /// 展开过的正文缓存，key = 文件 id
    @State private var textCache: [String: String] = [:]

    private var title: String { sessionId == nil ? "我的文件" : "全部产物" }

    /// 这个面板要展示的全部文件（未过滤搜索词）
    private var source: [AIFile] {
        let base = sessionId.map { lib.files(sessionId: $0) } ?? lib.files
        return base.sorted { $0.createdAt > $1.createdAt }
    }

    /// 命中搜索词之后的
    private var shown: [AIFile] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return source }
        return source.filter {
            $0.displayName.lowercased().contains(key) || $0.title.lowercased().contains(key)
        }
    }

    private var totalSizeText: String {
        let b = source.reduce(0) { $0 + $1.size }
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }

    var body: some View {
        NavigationStack {
            Group {
                if source.isEmpty {
                    emptyState
                } else if shown.isEmpty {
                    noMatch
                } else {
                    content
                }
            }
            .background(Theme.page)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !source.isEmpty {
                        Button(picking ? "取消" : "选择") {
                            withAnimation(.easeOut(duration: 0.18)) {
                                picking.toggle()
                                if !picking { picked.removeAll() }
                            }
                        }
                        .font(.system(size: 14))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if picking {
                        Button(allPicked ? "全不选" : "全选") {
                            if allPicked { picked.removeAll() }
                            else { picked = Set(shown.map(\.id)) }
                        }
                        .font(.system(size: 14))
                    } else {
                        Button("完成") { dismiss() }
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if picking { actionBar }
            }
            .sheet(item: $preview) { f in
                NavigationStack {
                    QuickLookView(url: f.url)
                        .ignoresSafeArea()
                        .navigationTitle(f.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    preview = nil
                                    // 等预览关掉再弹分享，两个 sheet 同时开会互相吞
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        sharing = [f]
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { preview = nil }
                            }
                        }
                }
                .roundSheet(28)
            }
            .sheet(isPresented: Binding(
                get: { !sharing.isEmpty },
                set: { if !$0 { sharing = [] } }
            )) {
                ShareSheet(items: sharing.map(\.url))
                    .presentationDetents([.medium, .large])
                    .roundSheet(28)
            }
            // 「保存」：系统文件选择器负责问用户存到哪
            .sheet(item: $exportRequest) { req in
                DocumentExporter(urls: req.urls)
                    .ignoresSafeArea()
            }
            // 「添加到对话」：先选对话，再把附件挂进去
            .sheet(item: $attachFile) { f in
                SessionPickerSheet(store: store, file: f) {
                    attachFile = nil
                    // 选完对话这个面板就退场 —— 用户要看的是那个对话的输入框
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dismiss() }
                }
                .roundSheet(28)
            }
            .confirmationDialog("删除这个文件？", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let f = confirmDelete { lib.remove(f) }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("只删手机上的这一份，聊天记录不受影响。")
            }
            .confirmationDialog("删除选中的 \(picked.count) 个文件？",
                                 isPresented: $confirmBatch,
                                 titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    lib.remove(ids: picked)
                    picked.removeAll()
                    picking = false
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删手机上的文件，聊天记录不受影响。删了找不回来。")
            }
            .confirmationDialog("清理 \(staleIds.count) 个对话记录？",
                                 isPresented: $confirmPurge,
                                 titleVisibility: .visible) {
                Button("清理", role: .destructive) {
                    lib.remove(ids: staleIds)
                    staleIds.removeAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些是老版本把聊天正文存成的文件，里面没有代码块。删掉不影响聊天记录本身。")
            }
        }
        // 半屏圆角 + **点面板外面就收回**（2026-10-31 用户：「别忘记弹窗都是
        // 点击弹窗以外的地方就收回」）。
        //
        // 为什么之前收不回：ChatView 那边挂 sheet 时没设 detents，
        // 等于一张全高页面，背景根本露不出来，点哪儿都是"面板里"。
        // 设了 medium 之后上方会留出页面本体，点上去系统自动 dismiss。
        // 想看长列表往上拖一下就到 .large，不影响。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: 列表

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !picking, !staleIds.isEmpty {
                    staleBanner
                }

                ForEach(shown) { f in
                    row(f)
                }

                Text("共 \(source.count) 个 · \(totalSizeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .refreshable { lib.reload() }
        .onAppear { scanStale() }
        .onChange(of: lib.files.count) { _ in scanStale() }
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索产物")
    }

    /// 扫一遍「旧版误存的聊天记录」。
    ///
    /// 就在主线程扫，不丢后台：每个文件只读头 32KB，几十份加起来
    /// 也就一两兆的顺序读，比来回切 actor 的代价小。
    /// （丢 Task.detached 还会因为 AIFile 不是 Sendable 引出一堆并发警告。）
    private func scanStale() {
        staleIds = Set(source.filter { FileStore.isChatArchive($0) }.map(\.id))
    }

    private var staleBanner: some View {
        Button {
            confirmPurge = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("有 \(staleIds.count) 个旧的对话记录")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("老版本把聊天正文也存了进来，不是真产物")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.sub)
                }
                Spacer(minLength: 4)
                Text("清理")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
        .padding(.bottom, 2)
    }

    private var allPicked: Bool {
        !shown.isEmpty && shown.allSatisfy { picked.contains($0.id) }
    }

    private func row(_ f: AIFile) -> some View {
        let on = picked.contains(f.id)
        let open = expanded.contains(f.id)
        return VStack(spacing: 0) {
            Button {
                if picking {
                    if on { picked.remove(f.id) } else { picked.insert(f.id) }
                } else {
                    // 2026-11-01 用户：「我要点击产物的时候不需要跳转到对话窗口，
                    // 让他实现真实的收缩那种」—— 点一下就地展开内容，再点一下收起。
                    // 想看全文/系统预览走长按菜单里的「打开」，不再"点一下就跳走"。
                    withAnimation(.easeOut(duration: 0.18)) {
                        if open { expanded.remove(f.id) } else { expanded.insert(f.id) }
                    }
                }
            } label: {
                HStack(spacing: 11) {
                    if picking {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.4))
                            .transition(.opacity)
                    }

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

                    Spacer(minLength: 4)

                    Text(shortTime(f.createdAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    if !picking {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
            // ScrollView 里没有 swipeActions，长按菜单顶替。
            //
            // 2026-10-31 用户点名要的四项：打开 / 共享 / 保存 / 添加到对话。
            //   打开   = 在 App 里直接看（QuickLook）
            //   共享   = 系统分享面板，发给任何 App
            //   保存   = 存到「文件」App（iCloud 云盘 / 我的 iPhone 等位置）
            //   添加到对话 = 把这份产物塞进指定对话的输入框
            // 2026-11-01 加第五项「打开对话」—— 用户明确要求：
            // 点产物本身**不跳**，只有菜单里这四个字才跳到那个聊天窗口。
            .contextMenu {
                Button {
                    preview = f
                } label: {
                    Label("打开", systemImage: "eye")
                }
                Button {
                    sharing = [f]
                } label: {
                    Label("共享", systemImage: "square.and.arrow.up")
                }
                Button {
                    exportRequest = ExportRequest(urls: [f.url])
                } label: {
                    Label("保存", systemImage: "folder.badge.plus")
                }
                Button {
                    attachFile = f
                } label: {
                    Label("添加到对话", systemImage: "text.bubble")
                }
                Button {
                    openConversation(f)
                } label: {
                    Label("打开对话", systemImage: "arrowshape.turn.up.left")
                }

                Divider()

                Button(role: .destructive) {
                    confirmDelete = f
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        picking = true
                        picked = [f.id]
                    }
                } label: {
                    Label("多选", systemImage: "checkmark.circle")
                }
            }

            if open && !picking {
                inlinePreview(f)
            }
        }
        // 底色和圆角包在**整块**上：展开出来的正文才会和标题行同属一张卡，
        // 而不是标题一块、正文一块中途断开。
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(picking && on ? 0.5 : 0), lineWidth: 1.2)
        )
        .contentShape(Rectangle())
    }

    /// 就地展开的那段正文（只读前一大截，不做全文渲染）。
    ///
    /// 为什么截断：产物里经常是几百行代码，全渲染进 LazyVStack 会把这个半屏面板
    /// 拖成幻灯片。这里给前 1200 字，够认出来是哪一份；要看全文点长按里的「打开」。
    private func inlinePreview(_ f: AIFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            Text(previewText(f))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button {
                    preview = f
                } label: {
                    Label("打开全文", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.remove(f.id) }
                } label: {
                    Text("收起")
                        .font(.system(size: 12))
                }
                .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
                .foregroundStyle(Theme.sub)

                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 读产物正文（带缓存，同一个文件只在第一次展开时读盘）
    private func previewText(_ f: AIFile) -> String {
        if let cached = textCache[f.id] { return cached }
        let limit = 1200
        var out: String
        if let s = try? String(contentsOf: f.url, encoding: .utf8) {
            out = s.count > limit ? String(s.prefix(limit)) + "\n…（后面还有 \(s.count - limit) 字，点「打开全文」看）" : s
            if out.isEmpty { out = "（空文件）" }
        } else {
            out = "（这个格式不能在这里预览，点「打开全文」看）"
        }
        // 写 @State 要放在渲染之后，不能直接在 body 里改；用异步落地
        let key = f.id, value = out
        DispatchQueue.main.async {
            if textCache[key] == nil { textCache[key] = value }
        }
        return out
    }

    /// 菜单里的「打开对话」：关掉面板，切到这份产物所属的会话。
    private func openConversation(_ f: AIFile) {
        dismiss()
        if !f.sessionId.isEmpty { store.openSession(f.sessionId) }
        store.tab = .tasks
    }

    // MARK: 多选操作条

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                sharing = shown.filter { picked.contains($0.id) }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
            .foregroundStyle(picked.isEmpty ? Color.secondary : Color.primary)
            .disabled(picked.isEmpty)

            Button {
                confirmBatch = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
            .foregroundStyle(picked.isEmpty ? Color.secondary : Color.red)
            .disabled(picked.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有产物")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("AI 每次回复都会自动存一份到这里，\n点开能看，也能直接分享出去。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    }

    private var noMatch: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有匹配「\(query)」的产物")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "MM-dd"
        }
        return f.string(from: d)
    }
}

// MARK: - 保存到「文件」App

/// 一次「保存」请求。
///
/// 用数组而不是单个 URL：UIDocumentPicker 本来就支持多个，
/// 以后多选里加「保存」不用再改这层结构。
///
/// 2026-11-01 从 `private` 放开成模块内可见：聊天页的产物卡长按也要「保存」，
/// 两处共用同一个请求结构，省一套重复定义（重复定义还容易改一处忘一处）。
struct ExportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - 添加到对话

/// 选一个对话，把产物作为附件挂进它的输入框。
///
/// 2026-10-31 用户要求：产物长按 →「添加到对话」= 把产物添加到**指定的**对话输入框。
/// 所以这里必须把所有对话列出来让他选，而不是默认塞进当前这个 ——
/// 他经常是"这句要发给另一个对话"。
struct SessionPickerSheet: View {
    @ObservedObject var store: ChatStore
    let file: AIFile
    /// 选完之后通知外层（外层要把产物面板一起关掉）
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.sessions) { s in
                        Button {
                            pick(s)
                        } label: {
                            row(s)
                        }
                        .buttonStyle(PressableStyle(scale: 0.97, dim: 0.72))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .background(Theme.page)
            .safeAreaInset(edge: .top) { fileBar }
            .safeAreaInset(edge: .bottom) { hintBar }
            .navigationTitle("添加到对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .font(.system(size: 14))
                }
            }
        }
        // 同样是「点外面就收回」；对话多时上拖到全高
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .roundSheet(28)
    }

    /// 顶部：要加进去的是哪个文件
    private var fileBar: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(file.kind.tint)
                    .frame(width: 27, height: 27)
                Image(systemName: file.kind.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("文件产物 · \(file.sizeText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.page)
    }

    /// 底部：说清楚"选中只是放进输入框，不点发送不会出去"
    private var hintBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "paperclip")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sub)
            Text("会放进所选对话的输入框，你点发送才真正发出去")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func row(_ s: Session) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(Theme.card)
                    .frame(width: 38, height: 38)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.sub)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(s.displayTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(s.messages.count) 条消息 · \(when(s.updatedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }

            Spacer(minLength: 4)

            if s.id == store.currentSessionId {
                Text("当前")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private func pick(_ s: Session) {
        store.attach(file: file, to: s.id)
        dismiss()
        onDone()
    }

    private func when(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "MM-dd"
        }
        return f.string(from: d)
    }
}
