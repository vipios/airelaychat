import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 聊天主界面

struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var settings = Settings.shared
    @StateObject private var voice = VoiceInput()

    @State private var showModelPicker = false
    @State private var showProviderPicker = false
    @State private var showSettings = false
    @State private var showDiag = false
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []

    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    statusBar
                    messagesArea
                    if let err = store.errorText { errorBanner(err) }
                    if !store.pending.isEmpty { pendingStrip }
                    inputBar
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleBar }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.reset() } label: {
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
            .sheet(isPresented: $showSettings) { SettingsView(store: store) }
            .sheet(isPresented: $showDiag) {
                NavigationStack { DiagView() }
            }
            .confirmationDialog("选择来源", isPresented: $showProviderPicker, titleVisibility: .visible) {
                ForEach(settings.providers.filter { $0.enabled }) { p in
                    Button(p.name + (p.id == settings.activeProvider ? "（当前）" : "")) {
                        Task { await store.switchProvider(p.id) }
                    }
                }
            }
            .confirmationDialog("选择模型", isPresented: $showModelPicker, titleVisibility: .visible) {
                ForEach(store.models) { m in
                    Button(m.display + capBadge(m.cap)) { store.currentModel = m.id }
                }
            }
            .confirmationDialog("添加", isPresented: $showAttachMenu, titleVisibility: .hidden) {
                Button("照片") { showPhotoPicker = true }
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
    }

    // MARK: 平台照片/视频载入

    /// PhotosPicker 选中后可能是图片也可能是视频，按类型分别处理
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

    // MARK: 顶部标题

    private var titleBar: some View {
        Button { showModelPicker = true } label: {
            VStack(spacing: 1) {
                Text(store.currentModel.isEmpty ? "选择模型"
                     : store.models.first(where: { $0.id == store.currentModel })?.display
                       ?? store.currentModel)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(store.detecting ? "检测中…" : statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        let p = store.providerName
        switch store.place {
        case .home: return "\(p) · 在家"
        case .away: return "\(p) · 在外"
        case .unknown: return "\(p) · 未连接"
        }
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.base != nil ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Image(systemName: store.place.symbol)
                .font(.system(size: 12))

            // 来源可点：多来源时方便切换
            Button {
                if settings.providers.count > 1 { showProviderPicker = true }
            } label: {
                HStack(spacing: 3) {
                    Text(store.detecting ? "检测中…" : statusText)
                        .font(.system(size: 12))
                    if settings.providers.count > 1 {
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if store.detecting {
                ProgressView().scaleEffect(0.7)
            } else if store.base == nil {
                Button("重连") { Task { await store.bootstrap() } }
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
                    if store.messages.isEmpty { emptyHint }
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
            Text(store.base == nil ? "还没连上" : "有什么想聊的？")
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

            VStack(alignment: .leading, spacing: 6) {
                // 附件预览
                ForEach(msg.attachments) { a in
                    if let img = a.preview {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 210, maxHeight: 210)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                            Image(systemName: fileSymbol(a.kind))
                                .font(.system(size: 12))
                            Text(a.name).font(.system(size: 12)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }

                if !msg.text.isEmpty || msg.attachments.isEmpty {
                    Text(msg.text.isEmpty ? " " : msg.text)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
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

    private func fileSymbol(_ k: Attachment.Kind) -> String {
        switch k {
        case .image: return "photo"
        case .video: return "video"
        case .text: return "doc.text"
        case .document: return "doc.richtext"
        case .binary: return "doc"
        }
    }

    // MARK: 错误提示（带一键换模型 / 诊断入口）

    private func errorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { store.errorText = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            if store.capSuggestion != nil {
                Button {
                    Task { await store.applyCapSuggestion() }
                } label: {
                    let name = store.models.first(where: { $0.id == store.capSuggestion })?.display
                        ?? store.capSuggestion ?? ""
                    Label("换成「\(name)」", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            // 连不上时给个直达诊断的入口，别让用户干瞪眼
            if store.base == nil {
                Button { showDiag = true } label: {
                    Label("连接诊断", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: 待发附件条

    private var pendingStrip: some View {
        VStack(spacing: 0) {
            // 能力冲突时提前警告
            if let conflict = store.capConflict {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(conflict)
                        .font(.system(size: 11))
                    Spacer()
                    if let fit = store.capFitModels.first {
                        Button("换成 \(fit.display)") { store.currentModel = fit.id }
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
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
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                VStack(spacing: 2) {
                                    Image(systemName: fileSymbol(a.kind))
                                        .font(.system(size: 16))
                                    Text(a.name)
                                        .font(.system(size: 8))
                                        .lineLimit(1)
                                        .frame(width: 48)
                                }
                                .frame(width: 56, height: 56)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
    }

    // MARK: 输入栏

    private var inputBar: some View {
        VStack(spacing: 0) {
            // 按住说话时占据输入框位置，显示实时识别结果
            if voice.recording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                    Text(voice.partial.isEmpty ? "正在听…" : voice.partial)
                        .font(.system(size: 15))
                        .foregroundStyle(voice.partial.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    Button { showAttachMenu = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.sending)

                    TextField("发消息…", text: $store.input, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(size: 15))
                        .focused($inputFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // 按住说话：放在发送键左边
                    HoldToTalkButton(voice: voice, disabled: store.sending) { text in
                        // 识别结果拼到输入框（已有文字就接在后面），由用户确认后发送
                        if store.input.isEmpty {
                            store.input = text
                        } else {
                            store.input += text
                        }
                    }

                    Button { sendIfPossible() } label: {
                        Image(systemName: store.sending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.system(size: 29))
                            .foregroundStyle(store.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .disabled(!store.canSend)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let e = voice.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(e)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        voice.error = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75))
                    .clipShape(Capsule())
                    .offset(y: -34)
                    .transition(.opacity)
            }
        }
    }

    private func sendIfPossible() {
        guard store.canSend else { return }
        inputFocused = false
        Task { await store.send() }
    }

    private func capBadge(_ c: ModelCap) -> String {
        switch c {
        case .text: return ""
        case .image: return "  🖼"
        case .video: return "  🎬"
        case .media: return "  🖼🎬"
        }
    }
}

// MARK: - 相机

/// 系统相机封装。模拟器没有相机，真机上正常。
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coord { Coord(onPicked: onPicked) }

    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void
        init(onPicked: @escaping (UIImage) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onPicked(img) }
            picker.presentingViewController?.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.presentingViewController?.dismiss(animated: true)
        }
    }
}
