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

    // MARK: 会话（抽屉里的任务列表）

    @Published var sessions: [Session] = []
    @Published var currentSessionId: String = ""
    /// 用户自己建的分组（抽屉里「创建分组」）
    @Published var groups: [TaskGroup] = []

    /// 底部 Tab 当前选中项。
    ///
    /// 2026-10-30 按用户要求改成三个：任务 / 后台面板 / 我的。
    /// 「后台面板」点一下直接进中转站网页后台；「我的」点进去直接是设置页。
    @Published var tab: MainTab = .tasks

    /// 连接灯：true = 通，false = 不通，nil = 还没探过（灯显示灰色）
    ///
    /// 为什么单独一个状态而不是用 base != nil：
    /// base 只代表「上次探测成功的地址」，那条隧道可能五分钟前就断了，
    /// 而 base 还留着。灯要反映的是**此刻**通不通，必须真的去打一次。
    @Published var online: Bool?
    /// 连续失败次数。局域网抖动一次就翻红太吵，连续 2 次才算真断。
    private var pingFails = 0
    private var pinging = false

    private let client = RelayClient.shared
    private let settings = Settings.shared

    init() {
        let loaded = SessionStore.load()
        if loaded.isEmpty {
            let s = Session()
            sessions = [s]
            currentSessionId = s.id
        } else {
            sessions = loaded
            // 默认打开最近用过的那一个
            let top = loaded.max(by: { $0.updatedAt < $1.updatedAt }) ?? loaded[0]
            currentSessionId = top.id
            messages = top.messages.map { $0.toChatMessage() }
        }
        groups = GroupStore.load()

        // 先用上次成功的地址把 base 填上，让界面第一帧就是"可用"。
        // 不这么做的话，打开 App 到探测完成之间有一段时间 base == nil，
        // 发送按钮是灰的，用户会以为卡住了。
        // 这个值是"乐观"的：bootstrap 会立刻校验并纠正，连不上会自动换。
        if let cached = settings.cachedBaseForLaunch {
            base = cached.base
            place = cached.place
        }
    }

    // MARK: 连接灯

    /// 用户主动重启设备期间，灯会短暂变灰。
    ///
    /// 为什么不干脆让它变红：红＝出故障，而这时候是我们自己把电拔了，
    /// 报故障会让用户以为重启失败了。灰＝"我知道现在断了，一会儿就好"。
    private var rebooting = false

    /// 进入「我主动重启了」状态。设置页点完确认后立刻调。
    func markRebooting() {
        rebooting = true
        online = nil
        pingFails = 0
    }

    func clearRebooting() {
        rebooting = false
    }

    /// 打一次心跳。给顶栏和输入栏的灯用。
    ///
    /// 调用方按固定节奏调（比如每 20 秒），这里自己做去重，
    /// 避免几个视图同时调导致并发打一堆请求。
    func pingNow() async {
        // 重启等待期内不打心跳：必然是失败的，只会白攒 pingFails，
        // 等设备回来了灯却因为攒够次数还红着。
        if rebooting { return }
        guard !pinging else { return }
        guard let b = base else {
            // 连地址都没有，必然是红的
            pingFails = 2
            online = false
            return
        }
        pinging = true
        defer { pinging = false }
        let ok = await client.ping(base: b)
        if ok {
            pingFails = 0
            online = true
        } else {
            pingFails += 1
            // 连续 2 次不通才翻红：单次丢包/隧道抖动很常见，
            // 一次就变红会让灯一直闪，反而看不出真实状态。
            if pingFails >= 2 { online = false }
        }
    }

    // MARK: 会话操作

    /// 把界面上的消息写回当前会话，并落盘。
    /// 流式输出过程中不调用（太频繁），只在发送结束、切会话、进后台时调。
    func syncCurrentSession() {
        guard let i = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        sessions[i].messages = messages.map { StoredMessage($0) }
        sessions[i].updatedAt = Date()
        // 标题自动取第一条用户消息，用户手动改过的就不再覆盖
        if sessions[i].title.isEmpty,
           let first = messages.first(where: { $0.role == "user" && !$0.text.isEmpty }) {
            let t = first.text.replacingOccurrences(of: "\n", with: " ")
            sessions[i].title = String(t.prefix(20))
        }
        SessionStore.save(sessions)
    }

    func newSession() {
        syncCurrentSession()
        // 当前已经是空会话就复用，别堆一堆空壳
        if let cur = sessions.first(where: { $0.id == currentSessionId }), cur.isEmpty {
            messages = []
            input = ""
            pending = []
            errorText = nil
            capSuggestion = nil
            return
        }
        let s = Session()
        sessions.insert(s, at: 0)
        currentSessionId = s.id
        messages = []
        input = ""
        pending = []
        errorText = nil
        capSuggestion = nil
        SessionStore.save(sessions)
    }

    func openSession(_ id: String) {
        guard id != currentSessionId else { return }
        syncCurrentSession()
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        currentSessionId = id
        messages = s.messages.map { $0.toChatMessage() }
        input = ""
        pending = []
        errorText = nil
        capSuggestion = nil
        if base == nil { Task { await bootstrap(loadModels: false) } }
    }

    func renameSession(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = t
        SessionStore.save(sessions)
        // 会话改名 → 磁盘上的产物文件夹跟着改名。
        // 用户原话：「会话的名字我要改了文件夹名字也同步改」。
        // 这里做的是真的移动文件 + 改目录名，不是只改记录，
        // 否则去「文件」App 里看到的还是老名字。
        renameArtifactFolder(sessionId: id, newTitle: t)
    }

    /// 把某个会话的产物文件夹改成新名字，并把记录里的 folder 字段一起更新。
    private func renameArtifactFolder(sessionId: String, newTitle: String) {
        let lib = FileLibrary.shared
        let updated = FileStore.renameFolder(oldFiles: lib.files,
                                            newTitle: newTitle,
                                            sessionId: sessionId)
        // 只有真的变了才落盘，避免每次改名都重写 index.json
        if updated.map({ $0.folder }) != lib.files.map({ $0.folder }) {
            lib.replaceAll(updated)
        }
    }

    func deleteSession(_ id: String) {
        // 删会话时把它那一堆产物也删掉。
        // 为什么不保留：用户删的是一个"任务"，留着一堆孤立文件
        // 只会在「我的文件」里堆成找不回来的垃圾。
        let lib = FileLibrary.shared
        let doomed = Set(lib.files.filter { $0.sessionId == id }.map { $0.id })
        if !doomed.isEmpty { lib.remove(ids: doomed) }

        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            let s = Session()
            sessions = [s]
            currentSessionId = s.id
            messages = []
        } else if currentSessionId == id {
            let top = sessions.max(by: { $0.updatedAt < $1.updatedAt }) ?? sessions[0]
            currentSessionId = top.id
            messages = top.messages.map { $0.toChatMessage() }
        }
        SessionStore.save(sessions)
    }

    // MARK: 分组管理

    /// 新建一个分组。名字空了就给个默认名，免得列表里出现一行空白。
    @discardableResult
    func createGroup(_ name: String) -> TaskGroup {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { n = "新分组 \(groups.count + 1)" }
        let g = TaskGroup(name: n)
        groups.append(g)
        GroupStore.save(groups)
        return g
    }

    func renameGroup(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = n
        GroupStore.save(groups)
    }

    /// 删除分组。**只删分组本身，里面的会话退回未分组**，
    /// 不跟着一起删 —— 用户只是想取消归类的可能性远大于想清空。
    func deleteGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        var changed = false
        for i in sessions.indices where sessions[i].groupId == id {
            sessions[i].groupId = nil
            changed = true
        }
        GroupStore.save(groups)
        if changed { SessionStore.save(sessions) }
    }

    /// 把会话放进某个分组（groupId = nil 表示移出分组）
    func setGroup(_ sessionId: String, to groupId: String?) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[i].groupId != groupId else { return }
        sessions[i].groupId = groupId
        SessionStore.save(sessions)
    }

    /// 某个分组里的会话（不按时间分，按更新时间倒序）
    func sessions(inGroup id: String) -> [Session] {
        sessions.filter { $0.groupId == id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 未归组、且有内容的会话，按时间分桶（原来的抽屉列表）
    func ungroupedBuckets(query q: String) -> [SessionBucket] {
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var pool = sessions.filter { !$0.isEmpty && $0.groupId == nil }
        if !key.isEmpty {
            pool = pool.filter {
                $0.displayTitle.lowercased().contains(key)
                || $0.previewText.lowercased().contains(key)
            }
        }
        pool.sort { $0.updatedAt > $1.updatedAt }

        var buckets: [SessionGroup: [Session]] = [:]
        for s in pool { buckets[SessionGroup.group(of: s.updatedAt), default: []].append(s) }
        return SessionGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return SessionBucket(group: g, items: items)
        }
    }

    /// 抽屉里要显示的分组
    func groupedSessions(query q: String) -> [SessionBucket] {
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var pool = sessions.filter { !$0.isEmpty }
        if !key.isEmpty {
            pool = pool.filter {
                $0.displayTitle.lowercased().contains(key)
                || $0.previewText.lowercased().contains(key)
            }
        }
        pool.sort { $0.updatedAt > $1.updatedAt }

        var buckets: [SessionGroup: [Session]] = [:]
        for s in pool { buckets[SessionGroup.group(of: s.updatedAt), default: []].append(s) }
        return SessionGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return SessionBucket(group: g, items: items)
        }
    }

    // MARK: 来源

    var provider: Provider? { settings.currentProvider }

    var providerName: String { provider?.name ?? "未选择" }

    /// 顶栏大标题：对齐 WorkBuddy 的「任务名」。
    /// 原版顶栏第二行是「电脑名 | 任务」，第一行就是当前任务名。
    var currentSessionTitle: String {
        guard let s = sessions.first(where: { $0.id == currentSessionId }) else { return "新任务" }
        let t = s.displayTitle
        return t.isEmpty ? "新任务" : t
    }

    /// 顶栏第二行显示「设备名 | 场景」里的设备名部分。
    /// 原版显示的是登录的那台电脑名（DESKTOP-xxx），咱们这边对应「家里那台路由器」。
    /// 用 UIDevice 的真实名字反而误导（那是"我的 iPhone"），所以写路由器型号更实在。
    var deviceLabel: String { "Redmi AC2100" }

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
    ///
    /// 2026-10-31 改：(1) 已有可用 base 时**不阻塞界面**，把校验丢后台；
    /// (2) 拿到新 base 立刻记住，下次打开秒连。
    func bootstrap(loadModels: Bool = true) async {
        guard !detecting else { return }
        detecting = true
        errorText = nil
        defer { detecting = false }

        guard let p = provider else {
            errorText = "还没有可用的供应商，去「我的 → 模型来源」添加一个。"
            return
        }

        let hadBase = (base != nil)
        let (b, pl) = await client.base(for: p)
        place = pl
        base = b

        if b == nil {
            errorText = p.isHome
                ? RelayError.noEndpoint.errorDescription
                : RelayError.notConfigured.errorDescription
            return
        }
        errorText = nil
        // 刚才已经有 base（启动时用的是缓存）：说明用户已经能发消息了，
        // 这时候再去拉模型列表只是补充信息，失败了也不该弹错吓人。
        guard loadModels, let bb = b else { return }
        await loadModelsFrom(base: bb, provider: p, quiet: hadBase)
    }

    private func loadModelsFrom(base bb: String, provider p: Provider,
                                quiet: Bool = false) async {
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
            // 模型拉不到不影响聊天（还能用上次选的），只提示不打断。
            // quiet=true 表示这一轮是后台补充，连提示都不必给。
            if models.isEmpty && !quiet {
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
            // 这里是「打开就能用」体验的最后一环：
            // 启动时用的是缓存地址，如果恰好出门/回家导致缓存失效，
            // 第一条消息会失败。这时候不该直接把错误甩给用户，
            // 先重新判定一次场景、换成对的地址、自动重发一遍。
            // 只有在「一个字都没收到」时才重试——已经流出内容说明链路是通的，
            // 中途断掉重发会让用户看到重复的内容。
            let gotNothing = (idx < messages.count) && messages[idx].text.isEmpty
            var recovered = false
            if gotNothing {
                await bootstrap(loadModels: false)
                if let nb = base, nb != b {
                    recovered = await retryStream(base: nb, key: key, model: model,
                                                  history: history, idx: idx)
                }
            }
            if !recovered {
                if idx < messages.count, messages[idx].text.isEmpty {
                    messages[idx].text = "（没发出去）"
                    messages[idx].failed = true
                }
                errorText = error.localizedDescription
                // 网络中途断了，重新判定场景，下次发送更靠谱
                await bootstrap(loadModels: false)
            }
        }
        sending = false
        syncCurrentSession()
        // 回复完成，把它存成文件进「我的文件」。
        // 放在 syncCurrentSession 之后：那时标题已经从首条用户消息补齐，
        // 文件名才能是「中转站搭建」而不是「新对话」。
        archiveReply(at: idx)
    }

    /// 把一条 AI 回复存成 .md 放进「我的文件」。
    ///
    /// 为什么要自动存而不是让用户手动点「保存」：
    /// 用户要的是「AI 给我的东西都在我的文件里」，多一步点选就等于没存
    /// （想起来点的时候已经找不到了）。自动存 + 能删，比手动存更符合直觉。
    ///
    /// 失败/空回复不存：那种内容存了只是垃圾。
    private func archiveReply(at idx: Int) {
        guard idx >= 0, idx < messages.count else { return }
        let m = messages[idx]
        guard m.role == "assistant", !m.failed else { return }
        let body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 10 else { return }   // 太短的多半是「好的」这类，不值得存

        // 找这条回复对应的那个问题，做成 md 的标题
        var question = ""
        var i = idx - 1
        while i >= 0 {
            if messages[i].role == "user" { question = messages[i].text; break }
            i -= 1
        }

        var doc = ""
        if !question.isEmpty {
            doc += "# \(question.replacingOccurrences(of: "\n", with: " "))\n\n"
        }
        doc += "> 模型：\(m.model.isEmpty ? currentModel : m.model)\n"
        doc += "> 时间：\(Self.stampText())\n\n---\n\n"
        doc += body
        doc += "\n"

        let title = question.isEmpty
            ? (currentSessionTitle.isEmpty ? "对话" : currentSessionTitle)
            : String(question.replacingOccurrences(of: "\n", with: " ").prefix(30))

        // sessionTitle 决定文件落在哪个文件夹：每个会话一个独立目录，
        // 目录名就是会话名（带一小段 id 防同名覆盖）。
        if let rec = FileStore.writeText(title: title,
                                        body: doc,
                                        ext: "md",
                                        sessionId: currentSessionId,
                                        sessionTitle: currentSessionTitle,
                                        messageIndex: idx) {
            FileLibrary.shared.add(rec)
        }
    }

    private static func stampText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// 换地址后重发一次。成功返回 true（已有内容流进来）。
    private func retryStream(base nb: String, key: String, model: String,
                             history: [(role: String, text: String, attachments: [Attachment])],
                             idx: Int) async -> Bool {
        do {
            try await client.stream(base: nb, key: key, model: model, messages: history) { delta in
                Task { @MainActor in
                    guard idx < self.messages.count else { return }
                    self.messages[idx].text += delta
                }
            }
            return !((idx < messages.count) && messages[idx].text.isEmpty)
        } catch {
            return false
        }
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
        syncCurrentSession()
    }

    /// 切到建议的模型，并把刚被拦下的附件放回去让用户直接重发
    func applyCapSuggestion() async {
        guard let s = capSuggestion else { return }
        currentModel = s
        capSuggestion = nil
        errorText = nil
    }

    /// 把模型切成能处理当前附件的那一个（顶栏一个按钮直达）
    func switchToFitModel() {
        guard let fit = capFitModels.first else { return }
        currentModel = fit.id
        errorText = nil
        capSuggestion = nil
    }
}
