import SwiftUI

// MARK: - 模型选择（半屏弹层，供应商 → 模型 两级）

/// 点「模型名」弹出来的选择器。2026-10-31 按用户要求重做三点：
///
/// **1. 半屏 + 大圆角**
/// 上一版是贴底的小 sheet，只能露出三四行，几十个模型要滑很久，
/// 圆角只有 10，看着像系统 ActionSheet。现在固定占 56% 高度、
/// 28 圆角、顶部有拖拽条 —— 一眼十几个，也更像"面板"。
///
/// **2. 先选供应商，再选模型**
/// 上一版把所有来源的模型平铺成一个长列表，第一屏全是同一家的
/// 几十个型号，想找别家得一直滑。现在第一层只列供应商
/// （带模型数量、在用的是哪家），点进去才是模型列表。
///
/// **3. 点上方空白逐级收回**
/// 第二层时点空白 = 退回第一层；第一层时点空白 = 整个关掉。
/// 用户原话：「点一下聊天界面，弹窗以上的地方就自动收回所有」。
///
/// 为什么不用 `.sheet` + `presentationDetents`：
/// 同一个 ZStack 上已经挂了设置、相机、相册、文件选择好几个 sheet，
/// 再加一层会和输入栏抢焦点（表现为键盘弹走、选完跳两次）。
/// 这里是自绘 overlay，挂在输入栏所在层级上，动画和回收都自己控制。
struct ModelPickerSheet: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    /// 外层负责把这一层从视图树里摘掉
    let onClose: () -> Void

    /// nil = 第一层（供应商列表）；非 nil = 第二层（该供应商的模型）
    @State private var picked: Provider?
    @State private var query = ""
    @State private var renaming: Provider?
    @State private var newName = ""

    /// 当前模型属于哪个供应商，用来在第一层打勾
    private var currentProviderId: String? {
        store.models.first(where: { $0.id == store.currentModel })?.providerId
    }

    private var currentModelShort: String {
        shortName(store.currentModel)
    }

    /// 启用的供应商 + 各自模型数（数量为 0 的也显示，告诉用户"这家还没拉到模型"）
    private var providers: [(p: Provider, count: Int)] {
        let provs = settings.providers
            .filter { $0.enabled }
            .sorted { a, b in
                if a.isHome != b.isHome { return a.isHome }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
        return provs.map { p in
            (p, store.models.filter { $0.providerId == p.id }.count)
        }
    }

    private func models(of p: Provider) -> [ModelItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = store.models.filter { $0.providerId == p.id }
        if !q.isEmpty {
            list = list.filter {
                $0.display.lowercased().contains(q) || $0.id.lowercased().contains(q)
            }
        }
        // 能力强的排前面，同能力按名字
        list.sort { a, b in
            if a.cap.rank != b.cap.rank { return a.cap.rank > b.cap.rank }
            return a.display.localizedCompare(b.display) == .orderedAscending
        }
        return list
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 上半屏空白：第二层退回第一层，第一层整个关掉
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { tapBlank() }

                VStack(spacing: 0) {
                    // 拖拽条：告诉用户这是可以点空白收起的面板
                    Capsule()
                        .fill(Color(.tertiaryLabel).opacity(0.5))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    header

                    if picked == nil {
                        providerList
                    } else {
                        modelList
                    }
                }
                // 半屏：56% 刚好露出十几个模型项，再多会把列表压得太矮
                .frame(height: geo.size.height * 0.56)
                .frame(maxWidth: .infinity)
                .background(Theme.page)
                // 28 圆角：比系统的 10 明显"厚"一圈，和输入胶囊的 24 呼应
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 20, y: -2)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .transition(.opacity)
        .alert("给来源改名", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { commitRename() }
        }
    }

    /// 点空白：第二层退回第一层，第一层整个关掉
    private func tapBlank() {
        if picked != nil {
            withAnimation(.easeInOut(duration: 0.18)) {
                picked = nil
                query = ""
            }
        } else {
            onClose()
        }
    }

    // MARK: 顶栏

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if picked != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            picked = nil
                            query = ""
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("供应商")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, tint: 0.07, tintRadius: 8, darken: 0))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(picked?.name ?? "选择模型")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    if picked == nil {
                        Text("当前：\(currentModelShort)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.90))
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)

            // 第二层才给搜索框：第一层就三五个供应商，搜索没意义
            if picked != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("搜索模型", text: $query)
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
                        .buttonStyle(PressableStyle(scale: 0.90, tint: 0.09, tintRadius: 999, darken: 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: 第一层：供应商

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if store.detecting || store.models.isEmpty {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                ForEach(providers, id: \.p.id) { item in
                    providerRow(item.p, count: item.count)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
    }

    private func providerRow(_ p: Provider, count: Int) -> some View {
        let isCurrent = p.id == currentProviderId
        return Button {
            guard count > 0 else { return }
            withAnimation(.easeInOut(duration: 0.18)) { picked = p }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((p.isHome ? Color.blue : Color.purple).opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: p.isHome ? "house.fill" : "cloud.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(p.isHome ? Color.blue : Color.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(count > 0 ? "\(count) 个模型" : "还没读到模型")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if count > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .contextMenu {
            Button {
                newName = p.name
                renaming = p
            } label: {
                Label("改名", systemImage: "pencil")
            }
        }
    }

    // MARK: 第二层：模型

    private var modelList: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let p = picked {
                    let items = models(of: p)
                    if items.isEmpty {
                        Text(query.isEmpty ? "这家还没有模型" : "没有匹配「\(query)」的模型")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        ForEach(items) { m in
                            modelRow(m)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
    }

    private func modelRow(_ m: ModelItem) -> some View {
        let selected = m.id == store.currentModel
        return Button {
            store.selectModel(m.id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.display)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if m.display != m.id {
                        Text(m.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                capBadge(m.cap)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(selected ? Color.accentColor.opacity(0.08) : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
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

    // MARK: 工具

    private func shortName(_ m: String) -> String {
        if let i = m.firstIndex(of: "|") { return String(m[m.index(after: i)...]) }
        return m.isEmpty ? "未选择" : m
    }

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
