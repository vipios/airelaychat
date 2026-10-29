import SwiftUI

// MARK: - 聊天主界面

struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    @State private var showModelPicker = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    statusBar
                    messagesArea
                    if let err = store.errorText { errorBanner(err) }
                    inputBar
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleBar }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.reset()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(store.messages.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog("选择模型", isPresented: $showModelPicker, titleVisibility: .visible) {
                ForEach(store.models) { m in
                    Button(m.id) { store.currentModel = m.id }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: 顶部标题

    private var titleBar: some View {
        Button { showModelPicker = true } label: {
            VStack(spacing: 1) {
                Text(store.currentModel.isEmpty ? "选择模型" : store.currentModel)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(store.place.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 状态条（在家/在外 + 连接状态）

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.base != nil ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Image(systemName: store.place.symbol)
                .font(.system(size: 12))
            Text(store.detecting ? "检测中…" : statusText)
                .font(.system(size: 12))
            Spacer()
            if store.detecting {
                ProgressView().scaleEffect(0.7)
            } else if store.base == nil {
                Button("重连") {
                    Task { await store.bootstrap() }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var statusText: String {
        switch store.place {
        case .home: return "在家 · 内网直连"
        case .away: return "在外 · 公网直连"
        case .unknown: return "未连接"
        }
    }

    // MARK: 消息区

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(store.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    if store.sending {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("正在回答…").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: store.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = store.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.base == nil ? "还没连上中转站" : "有什么想聊的？")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if store.base == nil {
                Text("在家连家里 WiFi，在外面打开就能用")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: 气泡

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == "user" { Spacer(minLength: 40) }

            if msg.role == "assistant" {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(msg.text.isEmpty ? " " : msg.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .foregroundStyle(msg.failed ? Color.secondary : Color.primary)

                if msg.failed {
                    Button {
                        Task { await store.retryLast() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                msg.role == "user"
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
            )
            .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if msg.role == "assistant" { Spacer(minLength: 40) }
        }
    }

    // MARK: 错误提示

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                store.errorText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: 输入栏

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息…", text: $store.input, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit { sendIfPossible() }

            Button {
                sendIfPossible()
            } label: {
                Image(systemName: store.sending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 29))
                    .foregroundStyle(store.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .disabled(!store.canSend)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func sendIfPossible() {
        guard store.canSend else { return }
        Task { await store.send() }
    }
}
