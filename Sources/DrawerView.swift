import SwiftUI

// MARK: - 左侧抽屉（1:1 对齐 WorkBuddy 侧边栏）

/// 原版结构（照截图逐项对齐）：
///   顶部：🖥 电脑名 ⌄            [≡]   ← 右上角那个菜单钮其实是关闭
///   「⊕ 新建任务」白底大按钮，圆角、描边
///   「任务 (3) ⌄」 可折叠分组 → 纯文字任务项，选中项浅灰底 + 右侧转圈
///   「空间 (1) ⌄」 可折叠分组 → 带图标的条目
///   每项都没有副标题、没有聊天气泡图标，就是一行文字
///
/// 咱们的差异（保留，因为是真功能）：
///   1. 加了「创建分组」：会话多了按时间找太累，用户要能自己归类长期保留
///   2. 长按会话 → 「保存到分组」：这是用户点名要的操作方式（按住会话塞进分组）
///   3. 分组标题和会话名都能改名（分组走长按菜单）
///
/// 2026-10-30 修正：原来 `.ignoresSafeArea(.vertical)` 让 header 顶到屏幕最上面，
/// 和状态栏的时间/信号叠在一起（用户原话「弹出来的文字太高了，已经和状态栏时间重叠了」）。
/// 现在把整个抽屉放回安全区内，只让**背景**铺满屏幕 ——
/// 内容不再钻到刘海底下，视觉上又还是通栏的一张纸。
struct DrawerView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    /// 关闭动作交给外层统一管动画，避免两处状态各动一套
    let onClose: () -> Void
    /// 设置/诊断也交给外层弹，抽屉自己不挂 sheet。
    /// 原因：同一个 ZStack 上再挂一层 sheet，会和 ChatView 的 sheet 抢，
    /// iOS 会警告 "Attempt to present ... which is already presenting"。
    var onOpenSettings: () -> Void = {}
    var onOpenDiag: () -> Void = {}

    static let width: CGFloat = 300

    @State private var query = ""
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var confirmDelete: Session?

    /// 新建分组
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    /// 分组改名
    @State private var renamingGroup: TaskGroup?
    @State private var groupRenameText = ""
    /// 分组删除确认
    @State private var confirmDeleteGroup: TaskGroup?

    /// 折叠状态，对齐原版「任务 (3) ⌄」那个箭头。
    /// key：自定义分组用 group.id，时间分组用 rawValue，共用一个集合不会冲突。
    @State private var collapsed: Set<String> = []
    /// 原版抽屉里没有搜索框。但咱们任务多了之后总得能找，
    /// 所以做成"点放大镜才出现"——不点就跟原版一模一样。
    @State private var showSearch = false

    private var ungrouped: [SessionBucket] {
        store.ungroupedBuckets(query: query)
    }

    private var filteredGroups: [TaskGroup] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return store.groups }
        return store.groups.filter { $0.name.lowercased().contains(key) }
    }

    private var isEmptyAll: Bool {
        ungrouped.isEmpty && filteredGroups.allSatisfy { store.sessions(inGroup: $0.id).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            newTaskButton
            newGroupButton
            if showSearch { searchBox }
            list
            footer
        }
        .frame(width: Self.width)
        // 背景单独铺满整屏（含刘海区、底部小白条区），内容留在安全区内。
        // 这一行 + 外层去掉 ignoresSafeArea 就是「不再压状态栏」的全部秘密。
        .background(Theme.sheet.ignoresSafeArea(edges: .vertical))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 0.5)
                .ignoresSafeArea(edges: .vertical)
        }
        // 新建分组
        .alert("创建分组", isPresented: $showNewGroup) {
            TextField("分组名，比如「工作」", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                let g = store.createGroup(newGroupName)
                // 建完直接把折叠取消掉，让用户立刻看到它出现在列表里
                collapsed.remove(g.id)
                newGroupName = ""
            }
        } message: {
            Text("建好后长按任意会话，就能把它保存到这个分组。")
        }
        // 分组改名
        .alert("重命名分组", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("分组名", text: $groupRenameText)
            Button("取消", role: .cancel) { renamingGroup = nil }
            Button("保存") {
                if let g = renamingGroup { store.renameGroup(g.id, to: groupRenameText) }
                renamingGroup = nil
            }
        }
        // 会话改名
        .alert("重命名任务", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let s = renaming { store.renameSession(s.id, to: renameText) }
                renaming = nil
            }
        }
        // 删会话
        .confirmationDialog("删除这个任务？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let s = confirmDelete { store.deleteSession(s.id) }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("删除后无法恢复。")
        }
        // 删分组
        .confirmationDialog("删除这个分组？", isPresented: Binding(
            get: { confirmDeleteGroup != nil },
            set: { if !$0 { confirmDeleteGroup = nil } }
        ), titleVisibility: .visible) {
            Button("删除分组", role: .destructive) {
                if let g = confirmDeleteGroup { store.deleteGroup(g.id) }
                confirmDeleteGroup = nil
            }
            Button("取消", role: .cancel) { confirmDeleteGroup = nil }
        } message: {
            Text("只删分组，里面的会话会回到上面的时间列表里，不会丢。")
        }
    }

    // MARK: 顶部：设备名 + 折叠箭头

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)

            Text(store.deviceLabel.uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            // 搜索：原版没有，收起来不占位
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSearch.toggle()
                    if !showSearch { query = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Button { close() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    // MARK: 搜索（原版没有，只在输入时才浮现，不占常驻空间）

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索任务", text: $query)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: 新建任务（原版是白底、灰描边的大圆角按钮）

    private var newTaskButton: some View {
        Button {
            store.newSession()
            store.tab = .tasks
            close()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .medium))
                Text("新建任务")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            // 白底 + 细描边，浮在 #FAFAFA 的抽屉上。
            // 参考图里这个按钮就是靠那圈描边认出来的，填充色和抽屉底几乎同色。
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.7), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 创建分组（原版没有，用户点名要的功能）

    private var newGroupButton: some View {
        Button {
            newGroupName = ""
            showNewGroup = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                Text("创建分组")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: 任务列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isEmptyAll {
                    Text(query.isEmpty ? "还没有任务" : "没有匹配的任务")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 28)
                }

                // ---------- 用户自建分组（置顶，因为是他主动归的类） ----------
                ForEach(filteredGroups) { g in
                    let open = !collapsed.contains(g.id)
                    let items = store.sessions(inGroup: g.id)

                    groupHeader(title: g.name,
                                count: items.count,
                                open: open,
                                icon: "folder.fill") {
                        if open { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                    }
                    .contextMenu {
                        Button {
                            groupRenameText = g.name
                            renamingGroup = g
                        } label: {
                            Label("重命名分组", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmDeleteGroup = g
                        } label: {
                            Label("删除分组", systemImage: "trash")
                        }
                    }

                    if open {
                        if items.isEmpty {
                            Text("长按下面的会话 →「保存到分组」")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(items) { s in
                                sessionRow(s)
                            }
                        }
                    }
                }

                // ---------- 未分组的会话，仍按时间归档 ----------
                if !ungrouped.isEmpty, !store.groups.isEmpty {
                    HStack(spacing: 4) {
                        Text("未分组")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                }

                ForEach(ungrouped) { bucket in
                    let key = bucket.group.rawValue
                    let open = !collapsed.contains(key)

                    groupHeader(title: bucket.group.rawValue,
                                count: bucket.items.count,
                                open: open,
                                icon: nil) {
                        if open { collapsed.insert(key) } else { collapsed.remove(key) }
                    }

                    if open {
                        ForEach(bucket.items) { s in
                            sessionRow(s)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
    }

    /// 分组标题：「今天 (3) ⌄」/「工作 (2) ⌄」
    private func groupHeader(title: String,
                             count: Int,
                             open: Bool,
                             icon: String?,
                             toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("(\(count))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.tertiary)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 原版任务项就是一行文字，选中项浅灰底。这里照着做，
    /// 只在选中项右侧加一个小转圈表示"这条正在用"。
    private func sessionRow(_ s: Session) -> some View {
        let active = s.id == store.currentSessionId
        return Button {
            store.openSession(s.id)
            store.tab = .tasks
            close()
        } label: {
            HStack(spacing: 8) {
                Text(s.displayTitle)
                    .font(.system(size: 15, weight: active ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if active {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(Color.green)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(active ? Color(.secondarySystemBackground) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 用户要的核心操作：按住会话 → 塞进指定分组。
            // 用二级菜单而不是一长串按钮：分组可能建了十几个，
            // 平铺会把菜单撑到屏幕外。
            Menu {
                ForEach(store.groups) { g in
                    Button {
                        store.setGroup(s.id, to: g.id)
                    } label: {
                        if s.groupId == g.id {
                            Label(g.name, systemImage: "checkmark")
                        } else {
                            Text(g.name)
                        }
                    }
                }
                if store.groups.isEmpty {
                    Text("还没有分组，先点上面的「创建分组」")
                }
                if s.groupId != nil {
                    Divider()
                    Button {
                        store.setGroup(s.id, to: nil)
                    } label: {
                        Label("移出分组", systemImage: "folder.badge.minus")
                    }
                }
            } label: {
                Label("保存到分组", systemImage: "folder")
            }

            Button {
                renameText = s.displayTitle
                renaming = s
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                confirmDelete = s
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // 长按出菜单是 iOS 默认行为，但原版长按没反应；
        // 这里保留长按（归组/改名/删除得有入口），只是不额外加视觉提示。
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator).opacity(0.4))
                .frame(height: 0.5)

            HStack(spacing: 10) {
                Button { close(); onOpenSettings() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(.tertiaryLabel))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("本机")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 5, height: 5)
                                Text(placeText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button { close(); onOpenDiag() } label: {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button { close(); onOpenSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.sheet)
    }

    private var statusColor: Color {
        if store.detecting && store.base == nil { return .orange }
        return store.base == nil ? .orange : .green
    }

    private var placeText: String {
        if store.detecting && store.base == nil { return "连接中…" }
        switch store.place {
        case .home: return "在家 · 内网直连"
        case .away: return "在外 · 域名"
        case .unknown: return store.base == nil ? "连接中…" : "已连接"
        }
    }

    private func close() {
        onClose()
    }
}
