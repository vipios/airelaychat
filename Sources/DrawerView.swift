import SwiftUI

// MARK: - 左侧抽屉

/// 2026-10-31 定稿版，按用户逐条要求改：
///
///   1. **右上角 ☰ 删掉**（用户原话「这个图标删除」）。
///      它本来只是「关闭抽屉」，但点外面遮罩、左滑、选会话都会关，
///      留一个 34pt 的圆钮专门干这事纯属占地方。
///   2. **搜索框常驻**在第一位，不再是点放大镜才出来
///      —— 藏起来的入口等于没有，找东西的人不会先去点一个放大镜。
///   3. **「我的文件」放在「新建任务」上方**，同样是白底描边大按钮，
///      右侧带文件数量。
///   4. **时间分组可折叠**：点「今天 (3) ▾」收起该组会话，
///      再点展开。收起状态只在本页生命周期内有效，不写磁盘
///      —— 这是"临时看一眼"的操作，不是配置。
///   5. **底部「本机 / 听诊器 / 齿轮」整块删掉**：
///      设置进「我的」Tab，诊断在设置里，抽屉底部不该再重复一遍。
///   6. 顶部不再显示设备名（`REDMI AC2100`）—— 改不了的名字不值得占一行。
struct DrawerView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var lib = FileLibrary.shared

    /// 关闭动作交给外层统一管动画，避免两处状态各动一套
    let onClose: () -> Void
    /// 设置/诊断交给外层弹，抽屉自己不挂 sheet。
    /// 原因：同一个 ZStack 上再挂一层 sheet，会和 ChatView 的 sheet 抢，
    /// iOS 会警告 "Attempt to present ... which is already presenting"。
    var onOpenSettings: () -> Void = {}
    var onOpenDiag: () -> Void = {}
    /// 打开「我的文件」。外面统一管弹层，抽屉不自己挂。
    var onOpenFiles: () -> Void = {}

    static let width: CGFloat = 300

    @State private var query = ""
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var confirmDelete: Session?

    /// 创建分组
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    /// 分组改名
    @State private var renamingGroup: TaskGroup?
    @State private var groupRenameText = ""
    /// 分组删除确认
    @State private var confirmDeleteGroup: TaskGroup?

    /// 折叠状态。key：自定义分组用 group.id，时间分组用 rawValue。
    @State private var collapsed: Set<String> = []

    private var ungrouped: [SessionBucket] {
        store.ungroupedBuckets(query: query)
    }

    /// 自建分组（「工作」「折腾路由器」这些）
    private var filteredGroups: [TaskGroup] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return store.groups }
        return store.groups.filter { $0.name.lowercased().contains(key) }
    }

    private var isEmptyAll: Bool {
        ungrouped.isEmpty && filteredGroups.allSatisfy { store.sessions(inGroup: $0.id).isEmpty }
    }

    /// 搜索框下面那行「文件命中 N 个」用
    private var hitFiles: [AIFile] {
        lib.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBox
            filesButton
            newTaskButton
            newGroupButton
            list
        }
        .frame(width: Self.width)
        // 背景单独铺满整屏（含刘海区、底部小白条区），内容留在安全区内。
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
            Text("删除后无法恢复，这个任务的产物也会一起删掉。")
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

    // MARK: 搜索（常驻第一位）

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索分组 / 会话 / 文件", text: $query)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        // 顶部 8 → 16：删掉 ☰ 之后搜索框直接贴着安全区边缘，
        // 用户反馈「整体有点往上」，多留一点和聊天页顶栏对齐
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: 我的文件（放在新建任务上方，同款白底描边按钮）

    private var filesButton: some View {
        Button {
            close()
            onOpenFiles()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                Text("我的文件")
                    .font(.system(size: 15, weight: .medium))
                // 数量角标：没文件就不显示，别挂个「0」让人以为坏了
                if !lib.files.isEmpty {
                    Text("\(lib.files.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
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

    // MARK: 新建任务

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

    // MARK: 创建分组

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
        .padding(.bottom, 2)
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
                        toggleGroup(g.id)
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

                // ---------- 未分组的会话，按时间归档 ----------
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
                        toggleGroup(key)
                    }

                    if open {
                        ForEach(bucket.items) { s in
                            sessionRow(s)
                        }
                    }
                }

                // 搜索时顺带提示命中了几个文件 —— 搜索框写的是
                // 「搜索分组 / 会话 / 文件」，只搜会话会显得骗人。
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !hitFiles.isEmpty {
                    Button {
                        close()
                        onOpenFiles()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                            Text("「\(query)」命中 \(hitFiles.count) 个文件")
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)
            .animation(.easeInOut(duration: 0.16), value: collapsed)
        }
        .frame(maxHeight: .infinity)
    }

    /// 点标题折叠 / 展开这个分组
    private func toggleGroup(_ key: String) {
        if collapsed.contains(key) {
            collapsed.remove(key)
        } else {
            collapsed.insert(key)
        }
    }

    /// 分组标题：「今天 (3) ▾」/「工作 (2) ▸」
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

    /// 任务项就是一行文字，选中项浅灰底 + 右侧小转圈。
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
    }

    private func close() {
        onClose()
    }
}
