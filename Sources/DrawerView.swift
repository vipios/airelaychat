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
///   任务项右侧长按能改名/删除；分组保留时间维度（原版是"任务/空间"两个业务分组，
///   咱们没有"空间"概念，改成按时间分组更实用）。
struct DrawerView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    /// 关闭动作交给外层统一管动画，避免两处状态各动一套
    let onClose: () -> Void

    static let width: CGFloat = 300

    @State private var query = ""
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var confirmDelete: Session?
    @State private var showSettings = false
    @State private var showDiag = false

    /// 分组折叠状态，对齐原版「任务 (3) ⌄」那个箭头
    @State private var collapsed: Set<String> = []
    /// 原版抽屉里没有搜索框。但咱们任务多了之后总得能找，
    /// 所以做成"点放大镜才出现"——不点就跟原版一模一样。
    @State private var showSearch = false

    private var groups: [SessionBucket] {
        store.groupedSessions(query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            newTaskButton
            if showSearch { searchBox }
            list
            footer
        }
        .frame(width: Self.width)
        .background(Theme.sheet)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 0.5)
        }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showDiag) { NavigationStack { DiagView() } }
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
        .padding(.top, 14)
        .padding(.bottom, 16)
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
        .padding(.bottom, 14)
    }

    // MARK: 任务列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Text(query.isEmpty ? "还没有任务" : "没有匹配的任务")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 28)
                }

                ForEach(groups) { bucket in
                    let key = bucket.group.rawValue
                    let open = !collapsed.contains(key)

                    // 分组标题：「今天 (3) ⌄」
                    Button {
                        if open { collapsed.insert(key) } else { collapsed.remove(key) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(bucket.group.rawValue)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                            Text("(\(bucket.items.count))")
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
        // 这里保留长按（改名/删除得有入口），只是不额外加视觉提示。
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator).opacity(0.4))
                .frame(height: 0.5)

            HStack(spacing: 10) {
                Button { showSettings = true } label: {
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

                Button { showDiag = true } label: {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button { showSettings = true } label: {
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
