import SwiftUI
import UIKit

// MARK: - 主界面状态

@MainActor
final class ChatStore: ObservableObject {
    @Published var place: NetPlace = .unknown
    @Published var base: String?
    @Published var build: String?
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    /// 待发送的附件
    @Published var pending: [Attachment] = []
    @Published var sending = false
    @Published var detecting = false
    @Published var models: [ModelItem] = []
    @Published var currentModel: String = ""
    @Published var errorText: String?
    /// 附件相关的一次性提示（比如视频太大）
    @Published var toast: String?
    /// 当前模型不支持附件时，提示里给的一键换模型候选
    @Published var capSuggestion: String?

    private let client = RelayClient.shared
    private let settings = Settings.shared

    // MARK: 来源

    var provider: Provider? { settings.currentProvider }

    var providerName: String { provider?.name ?? "未选择" }

    // MARK: 当前模型能力

    var currentCap: ModelCap {
        guard let p = provider else { return .text }
        return settings.cap(for: currentModel, in: p)
    }

    /// 当前附件情况：有没有图、有没有视频
    var hasImage: Bool { pending.contains { $0.kind == .image } }
    var hasVideo: Bool { pending.contains { $0.kind == .video } }

    /// 附件与模型能力是否冲突。返回提示语，nil 表示没问题。
    var capConflict: String? {
        guard !pending.isEmpty else { return nil }
        let cap = currentCap
        if hasVideo, cap != .video, cap != .media {
            return "「\(shortName(currentModel))」不支持视频"
        }
        if hasImage, cap == .text || cap == .video {
            return "「\(shortName(currentModel))」不支持图片"
        }
        return nil
    }

    /// 能接住当前附件的模型（用于一键切换建议）
    var capFitModels: [ModelItem] {
        models.filter { m in
            if hasVideo { return m.cap == .video || m.cap == .media }
            if hasImage { return m.cap == .image || m.cap == .media || m.cap == .video }
            return true
        }
    }

    private func shortName(_ m: String) -> String {
        // loomy|GLM-5.3-Flash -> GLM-5.3-Flash
        if let i = m.firstIndex(of: "|") { return String(m[m.index(after: i)...]) }
        return m
    }

    /// 当前这次请求用的模型：场景配了就用场景的，没配才用界面上选的
    var effectiveModel: String {
        let want = place == .home ? settings.homeModel : settings.awayModel
        if !want.isEmpty, models.isEmpty || models.contains(where: { $0.id == want }) {
            return want
        }
        return currentModel
    }

    var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !sending && base != nil && (hasText || !pending.isEmpty)
    }

    // MARK: - 启动 / 重新检测

    /// 进前台、切网络、点重试都走这里。已有对话不会被清掉。
    func bootstrap(loadModels: Bool = true) async {
        guard !detecting else { return }
        detecting = true
        errorText = nil
        defer { detecting = false }

        guard let p = provider else {
            errorText = "还没有可用的模型来源，去「设置 → 模型来源」添加一个。"
            return
        }

        let (b, pl) = await client.base(for: p)
        place = pl
        base = b

        if b == nil {
            errorText = p.isHome
                ? RelayError.noEndpoint.errorDescription
                : RelayError.notConfigured.errorDescription
            return
        }
        guard loadModels, let bb = b else { return }
        await loadModelsFrom(base: bb, provider: p)
    }

    private func loadModelsFrom(base bb: String, provider p: Provider) async {
        let key = settings.key(for: p)
        do {
            let list = try await client.models(base: bb, key: key)
            // 家里中转站的模型名带 "来源|模型" 前缀，界面上只显示模型名部分更好读
            models = list.map { m in
                ModelItem(id: m.id,
                          providerId: p.id,
                          display: shortName(m.id),
                          cap: settings.cap(for: m.id, in: p))
            }
            // 记住这个来源有哪些模型
            let names = list.map(\.id)
            if let idx = settings.providers.firstIndex(where: { $0.id == p.id }),
               settings.providers[idx].models != names {
                settings.providers[idx].models = names
            }

            let want = place == .home ? settings.homeModel : settings.awayModel
            if !want.isEmpty, list.contains(where: { $0.id == want }) {
                currentModel = want
            } else if currentModel.isEmpty || !list.contains(where: { $0.id == currentModel }) {
                currentModel = list.first?.id ?? ""
            }
        } catch {
            // 模型拉不到不影响聊天（还能用上次选的），只提示不打断
            if models.isEmpty {
                errorText = error.localizedDescription
            }
        }
    }

    /// 从后台回前台时调用：轻量重连，不动对话
    func refreshIfNeeded() async {
        await bootstrap(loadModels: base == nil || models.isEmpty)
    }

    /// 切换来源
    func switchProvider(_ id: String) async {
        guard settings.activeProvider != id else { return }
        settings.activeProvider = id
        models = []
        currentModel = ""
        base = nil
        pending = []
        await bootstrap()
    }

    /// 只在当前来源里刷新模型列表
    func refreshModels() async {
        guard let p = provider, let b = base else { return }
        await loadModelsFrom(base: b, provider: p)
    }

    // MARK: - 附件

    func addImage(_ img: UIImage, name: String = "照片.jpg") {
        guard pending.count < AttachmentMaker.maxAttachments else {
            toast = "最多带 \(AttachmentMaker.maxAttachments) 个附件"
            return
        }
        if let a = AttachmentMaker.image(from: img, name: name) {
            pending.append(a)
        } else {
            toast = "这张图片读取失败"
        }
    }

    func addImageData(_ data: Data, name: String) {
        guard pending.count < AttachmentMaker.maxAttachments else {
            toast = "最多带 \(AttachmentMaker.maxAttachments) 个附件"
            return
        }
        if let a = AttachmentMaker.image(from: data, name: name) {
            pending.append(a)
        } else {
            toast = "这张图片读取失败"
        }
    }

    func addVideo(_ url: URL) {
        guard pending.count < AttachmentMaker.maxAttachments else {
            toast = "最多带 \(AttachmentMaker.maxAttachments) 个附件"
            return
        }
        let (a, err) = AttachmentMaker.video(from: url, name: url.lastPathComponent)
        if let a = a { pending.append(a) } else { toast = err ?? "视频读取失败" }
    }

    func addFile(_ url: URL) {
        guard pending.count < AttachmentMaker.maxAttachments else {
            toast = "最多带 \(AttachmentMaker.maxAttachments) 个附件"
            return
        }
        if let a = AttachmentMaker.file(from: url) {
            pending.append(a)
        } else {
            toast = "这个文件读取失败"
        }
    }

    func removePending(_ a: Attachment) {
        pending.removeAll { $0.id == a.id }
    }

    // MARK: - 发送

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attach = pending
        guard !text.isEmpty || !attach.isEmpty else { return }

        // 没连上就先连，连上了再发，避免用户白打一段字
        if base == nil {
            await bootstrap()
            guard base != nil else { return }
        }
        guard let b = base, !sending, let p = provider else { return }

        let model = effectiveModel
        guard !model.isEmpty else {
            errorText = "还没选模型，点顶部标题选一个。"
            return
        }

        // 附件和模型能力冲突就先拦住，别白等一次失败
        if let conflict = capConflict {
            errorText = conflict + "。点下面换个能处理的模型。"
            capSuggestion = capFitModels.first?.id
            return
        }

        input = ""
        pending = []
        errorText = nil
        capSuggestion = nil
        messages.append(ChatMessage(role: "user", text: text, attachments: attach))
        messages.append(ChatMessage(role: "assistant", text: "", model: model))
        let idx = messages.count - 1
        sending = true

        // 历史里只带「有文字或附件」的，跳过占位的空助手消息
        let history = messages.dropLast().compactMap { m -> (role: String, text: String, attachments: [Attachment])? in
            if m.role == "assistant" && m.text.isEmpty && !m.failed { return nil }
            return (m.role, m.text, m.attachments)
        }

        let key = settings.key(for: p)
        do {
            try await client.stream(base: b, key: key, model: model, messages: history) { delta in
                Task { @MainActor in
                    guard idx < self.messages.count else { return }
                    self.messages[idx].text += delta
                }
            }
        } catch {
            if idx < messages.count, messages[idx].text.isEmpty {
                messages[idx].text = "（没发出去）"
                messages[idx].failed = true
            }
            errorText = error.localizedDescription
            // 网络中途断了，重新判定场景，下次发送更靠谱
            await bootstrap(loadModels: false)
        }
        sending = false
    }

    /// 重发最后一条用户消息
    func retryLast() async {
        guard !sending else { return }
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return }

        // 把这条用户消息及其之后的内容全部撤回，重新填回输入区
        let keep = lastUser
        while let last = messages.last, last.id != keep.id {
            messages.removeLast()
        }
        if let i = messages.indices.last {
            input = messages[i].text
            pending = messages[i].attachments
            messages.remove(at: i)
        }
        await send()
    }

    func reset() {
        messages.removeAll()
        pending = []
        errorText = nil
        capSuggestion = nil
    }

    /// 切到建议的模型，并把刚被拦下的附件放回去让用户直接重发
    func applyCapSuggestion() async {
        guard let s = capSuggestion else { return }
        currentModel = s
        capSuggestion = nil
        errorText = nil
    }
}
