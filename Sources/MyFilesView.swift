import SwiftUI

// MARK: - 我的文件

/// AI 产物的本地文件库。
///
/// 数据来源：每轮 AI 回复结束时由 ChatStore 自动写成 .md 存进
/// Documents/AIFiles/（见 FileStore）。这里只管展示、分享、删除。
///
/// 为什么按会话分组而不是平铺：
/// 用户找东西的记忆单位是「那次聊关于中转站的对话」，不是文件名。
/// 而且抽屉里搜索时也是按会话名命中，两边逻辑一致才不会觉得别扭。
struct MyFilesView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var lib = FileLibrary.shared
    /// true = 从抽屉点进来（弹层），需要关闭按钮
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var preview: AIFile?
    @State private var sharing: AIFile?
    @State private var confirmDelete: AIFile?

    /// 按会话分组。会话名从 store 里取，取不到就退回「未归类」。
    private var grouped: [(sessionId: String, title: String, items: [AIFile])] {
        let list = lib.search(query)
        var map: [String: [AIFile]] = [:]
        for f in list { map[f.sessionId, default: []].append(f) }
        return map.map { (sid, items) in
            let title = store.sessions.first(where: { $0.id == sid })?.displayTitle
                ?? items.first?.title
                ?? "未归类"
            return (sid, title, items.sorted { $0.createdAt > $1.createdAt })
        }
        .sorted { ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if lib.files.isEmpty {
                    emptyState
                } else if grouped.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("没有匹配「\(query)」的文件")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .navigationTitle("我的文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 不论从哪进来都要能关掉：从抽屉进来是弹层，
                // 没有关闭按钮用户只能下滑，而下滑在列表里容易误触。
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $preview) { f in
                NavigationStack {
                    QuickLookView(url: f.url)
                        .ignoresSafeArea()
                        .navigationTitle(f.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    preview = nil
                                    sharing = f
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { preview = nil }
                            }
                        }
                }
            }
            .sheet(item: $sharing) { f in
                ShareSheet(items: [f.url])
                    .presentationDetents([.medium, .large])
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
        }
    }

    // MARK: 列表

    private var list: some View {
        List {
            ForEach(grouped, id: \.sessionId) { g in
                Section {
                    ForEach(g.items) { f in
                        row(f)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                        Text(g.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(g.items.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        // 文件夹真名，让用户知道去「文件」App 里找哪个目录
                        Text(g.items.first?.folder ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                    .textCase(nil)
                }
            }

            Section {
                HStack {
                    Text("共 \(lib.files.count) 个文件")
                    Spacer()
                    Text(lib.totalSizeText)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        // 列表底色要跟演示图一致：insetGrouped 默认是系统灰，
        // 在浅色下比 Theme.page 深一档，整页看着发闷。
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        // 搜索框加上圆角背景，和聊天页、抽屉的风格一致
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索文件")
    }

    private func row(_ f: AIFile) -> some View {
        Button {
            preview = f
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: f.kind.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.fileName)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(f.kind.label)
                        Text("·")
                        Text(f.sizeText)
                        Text("·")
                        Text(shortTime(f.createdAt))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    sharing = f
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete = f
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有文件")
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

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "MM-dd HH:mm"
        }
        return f.string(from: d)
    }
}
