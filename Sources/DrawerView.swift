import SwiftUI

// MARK: - 左侧抽屉（仿 WorkBuddy 侧边栏）

/// 结构照 WorkBuddy 手机端：
///   顶部：品牌 / 当前工作区
///   搜索框
///   任务列表（按「今天 / 昨天 / 近 7 天 / 更早」分组，可长按改名或删除）
///   底部：设置、连接诊断、新对话、用户头像
///
/// 宽度 290，跟随手指拖拽关闭，右侧带一条渐隐阴影。
struct DrawerView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    /// 关闭动作交给外层统一管动画，避免两处状态各动一套
    let onClose: () -> Void

    /// 抽屉完全展开时距屏幕左边的距离（露出主界面的那一小条）
    static let edgeGap: CGFloat = 0
    static let width: CGFloat = 290

    @State private var query = ""
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var confirmDelete: Session?
    @State private var showSettings = false
    @State private var showDiag = false

    private var groups: [SessionBucket] {
        store.groupedSessions(query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBox
            list
            footer
        }
        .frame(width: Self.width)
        .background(Color(.systemBackground))
        .overlay(alignment: .trailing) {
            // 抽屉右边缘一道细阴影，和主界面分开
            Rectangle()
                .fill(LinearGradient(colors: [.black.opacity(0.10), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 6)
                .offset(x: 6)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showDiag) {
            NavigationStack { DiagView() }
        }
        .alert("重命名对话", isPresented: Binding(
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
        .confirmationDialog("删除这个对话？", isPresented: Binding(
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

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 9) {
            // 图标用中转站的「信号」意象
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("AI 中转站")
                    .font(.system(size: 15, weight: .semibold))
                Text(store.providerName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: 搜索

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索对话", text: $query)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: 任务列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Button {
                    store.newSession()
                    close()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14))
                        Text("新对话")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                if groups.isEmpty {
                    Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 28)
                }

                ForEach(groups) { bucket in
                    Section {
                        ForEach(bucket.items) { s in
                            sessionRow(s)
                        }
                    } header: {
                        Text(bucket.group.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .textCase(nil)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private func sessionRow(_ s: Session) -> some View {
        let active = s.id == store.currentSessionId
        return Button {
            store.openSession(s.id)
            close()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayTitle)
                        .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(s.previewText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(active ? Color.accentColor.opacity(0.10) : Color.clear)
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
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor.opacity(0.85))

                VStack(alignment: .leading, spacing: 1) {
                    Text("本机")
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 3) {
                        Circle()
                            .fill(store.place == .unknown ? Color.orange : Color.green)
                            .frame(width: 5, height: 5)
                        Text(placeText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                Button { showDiag = true } label: {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    private var placeText: String {
        if store.detecting && store.base == nil { return "连接中…" }
        switch store.place {
        case .home: return "在家 · 内网"
        case .away: return "在外 · 公网"
        case .unknown: return store.base == nil ? "连接中…" : "已连接"
        }
    }

    private func close() {
        onClose()
    }
}
