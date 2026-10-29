import SwiftUI

// MARK: - 模型选择（底部抽拉弹窗）

/// 点顶栏模型名弹出来的列表。
///
/// 为什么要做成抽拉弹窗而不是 ActionSheet：
/// 中转站上有 80 个模型，ActionSheet 撑不下还不可滚动；
/// 抽拉弹窗有搜索框、能分组、能滚，选起来快得多。
///
/// 分组规则：按「来源」分组。家里的中转站排最前，其余按名字。
/// 每个来源右侧有个改名按钮 —— 来源名字是用户自己起的，
/// 叫「家里中转站」还是「老王家」都行，改完立刻生效。
struct ModelPickerSheet: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var renaming: Provider?
    @State private var newName = ""

    /// 过滤后的模型，按来源分组
    private var groups: [(provider: Provider, models: [ModelItem])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [(Provider, [ModelItem])] = []

        // 来源顺序：启用的在前，家里优先，其余按名字
        let provs = settings.providers
            .filter { $0.enabled }
            .sorted { a, b in
                if a.isHome != b.isHome { return a.isHome }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }

        for p in provs {
            var list = store.models.filter { $0.providerId == p.id }
            if !q.isEmpty {
                list = list.filter {
                    $0.display.lowercased().contains(q) || $0.id.lowercased().contains(q)
                }
            }
            if list.isEmpty { continue }
            // 能力强的排前面（能看图的更有用），同能力按名字
            list.sort { a, b in
                if a.cap.rank != b.cap.rank { return a.cap.rank > b.cap.rank }
                return a.display.localizedCompare(b.display) == .orderedAscending
            }
            out.append((p, list))
        }
        return out
    }

    private var total: Int { groups.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        NavigationStack {
            List {
                if store.detecting || store.models.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(store.detecting ? "正在读取模型列表…" : "还没有模型")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !store.detecting {
                                Button("重试") { Task { await store.bootstrap() } }
                                    .font(.system(size: 13))
                            }
                        }
                    }
                }

                ForEach(groups, id: \.provider.id) { group in
                    Section {
                        ForEach(group.models) { m in
                            row(m, provider: group.provider)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: group.provider.isHome ? "house.fill" : "cloud.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(group.provider.isHome ? Color.blue : Color.purple)
                            Text(group.provider.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(group.models.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                newName = group.provider.name
                                renaming = group.provider
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                    }
                }

                if !query.isEmpty && total == 0 {
                    Section {
                        Text("没有匹配「\(query)」的模型")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索模型")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("给来源改名", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("名称", text: $newName)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { commitRename() }
            } message: {
                if let p = renaming {
                    Text(p.isHome ? "这是家里的中转站，改个好记的名字。" : "这个来源在列表和设置里都会显示新名字。")
                }
            }
        }
    }

    // MARK: 一行模型

    private func row(_ m: ModelItem, provider: Provider) -> some View {
        Button {
            store.currentModel = m.id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.display)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if m.display != m.id {
                        Text(m.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                capBadge(m.cap)
                if m.id == store.currentModel {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capBadge(_ cap: ModelCap) -> some View {
        switch cap {
        case .media:
            badge("图·视频", color: .purple)
        case .video:
            badge("视频", color: .indigo)
        case .image:
            badge("图", color: .teal)
        case .text:
            EmptyView()
        }
    }

    private func badge(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: 改名

    private func commitRename() {
        guard var p = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != p.name else { return }
        p.name = name
        settings.updateProvider(p)
    }
}

// MARK: - 能力排序用

extension ModelCap {
    /// 数值越大能力越强，列表里排前面
    var rank: Int {
        switch self {
        case .text: return 0
        case .image: return 1
        case .video: return 2
        case .media: return 3
        }
    }
}
