import SwiftUI

// MARK: - 主界面状态

@MainActor
final class ChatStore: ObservableObject {
    @Published var place: NetPlace = .unknown
    @Published var base: String?
    @Published var build: String?
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var sending = false
    @Published var detecting = false
    @Published var models: [ModelInfo] = []
    @Published var currentModel: String = ""
    @Published var errorText: String?

    private let client = RelayClient.shared
    private let settings = Settings.shared

    // 当前这次请求用的模型：场景配了就用场景的，没配才用界面上选的
    var effectiveModel: String {
        let want = place == .home ? settings.homeModel : settings.awayModel
        if !want.isEmpty, models.isEmpty || models.contains(where: { $0.id == want }) {
            return want
        }
        return currentModel
    }

    var canSend: Bool {
        !sending && base != nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 启动 / 重新检测

    /// 进前台、切网络、点重试都走这里。已有对话不会被清掉。
    func bootstrap(loadModels: Bool = true) async {
        guard !detecting else { return }
        detecting = true
        errorText = nil
        defer { detecting = false }

        let r = await client.resolve()
        place = r.place
        base = r.base
        build = r.health?.build

        if r.place == .unknown {
            errorText = RelayError.noEndpoint.errorDescription
            return
        }
        guard loadModels, let b = r.base else { return }

        do {
            let list = try await client.models(base: b)
            models = list
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
        await bootstrap(loadModels: base == nil)
    }

    // MARK: - 发送

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 没连上就先连，连上了再发，避免用户白打一段字
        if base == nil {
            await bootstrap()
            guard base != nil else { return }
        }
        guard let b = base, !sending else { return }

        let model = effectiveModel
        guard !model.isEmpty else {
            errorText = "还没选模型，去「设置」里选一个。"
            return
        }

        input = ""
        errorText = nil
        messages.append(ChatMessage(role: "user", text: text))
        messages.append(ChatMessage(role: "assistant", text: ""))
        let idx = messages.count - 1
        sending = true

        let history = Array(messages.dropLast())
        do {
            try await client.stream(base: b, model: model, messages: history) { delta in
                Task { @MainActor in
                    guard idx < self.messages.count else { return }
                    self.messages[idx].text += delta
                }
            }
            // stream 内部有非流式兜底，能正常返回就一定有内容
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
        while let last = messages.last, last.id != lastUser.id {
            messages.removeLast()
        }
        if let i = messages.indices.last {
            input = messages[i].text
            messages.remove(at: i)
        }
        await send()
    }

    func reset() {
        messages.removeAll()
        errorText = nil
    }
}
