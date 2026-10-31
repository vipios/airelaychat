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

    /// 正在让 AI 整理交接包。
    ///
    /// 2026-10-31 用户问「怎么让他直接生成交接文档和源码，而不是我一个字一个字去打字」——
    /// 所以「生成交接」不再只是本地拼一段摘要，而是自动替用户发一条格式指令，
    /// 拿到回复后当场拆成交接文档 + 源码两个文件。这个标记用来：
    ///   1. 让界面显示"正在整理"
    ///   2. 在 runSend 结束时认领这一轮回复（走专门拆包，不做普通归档）
    @Published var handoffBuilding = false
    /// 起手看门狗：万一模型/连接有问题根本没发出去，几秒后把标记复位，
    /// 否则按钮会一直卡在"整理中"。
    private var handoffWatch: Task<Void, Never>?
    /// 刚换过来源/账号，界面提示「要不要把上一个 AI 的进度交接过来」。
    ///
    /// 2026-10-31 用户要求「换另一个账号的 AI 继续，别断开记忆」：
    /// 换来源这个动作本身不会丢消息（历史还在本地），但新模型的上下文是空的，
    /// 它会当第一次见你。这个标记让界面上浮一条可点的提示，
    /// 而不是让用户自己想起来"哦我该跟他说一下之前做了啥"。
    ///
    /// 注意：2026-10-31 晚些时候用户选了「全自动」方案，所以现在
    /// 交接是**自动**发生在下一条消息上的（见 autoHandoffPending），
    /// 这个提示条只是告诉他"已经帮你接上了"，不再需要他动手。
    @Published var needsHandoffHint = false

    /// 待自动交接。
    ///
    /// 2026-10-31 用户选择「自动化」方案后加的：
    /// 换来源/换模型之后，**下一条消息自动**把之前的背景带上，
    /// 用户不用点任何按钮、也不用多花一次模型调用
    /// （摘要走本地拼接，塞进本来就要发的那次请求里）。
    ///
    /// 存的是「要交接哪些消息」的截止下标 —— 换账号那一刻之前的对话。
    /// 换完之后新说的话不该再被当成"背景"，否则会重复。
    private var autoHandoffCutoff: Int?

    /// 上次成功发消息用的来源 id。
    ///
    /// 用来判断"是不是换账号了"：来源 id 变了 = 换了一个 AI，
    /// 那它的上下文是空的，需要交接。
    private var lastSendProviderId: String = ""
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

    /// 正在跑的发送任务。
    ///
    /// 2026-10-31 用户要求「撤回后 AI 不再请求响应，等发下一条才继续」：
    /// 拿住这个句柄，撤回时 cancel() 就能立刻掐断 SSE 流。
    /// 不掐的话，即使界面把消息标成"已撤回"，后台还在读上游的 token，
    /// 等于白烧积分。
    private var sendTask: Task<Void, Never>?

    /// 已经点了发送、但真正的 runSend 还没开始跑的那一瞬。
    ///
    /// 为什么需要它：send() 改成"建 Task 就走"之后，sending 是在 Task 内部
    /// 才置 true 的，用户手快连点两下会开出两个任务、发两条一样的消息。
    /// 这个标记把「已受理」和「正在跑」分开，两个都为空才允许再发。
    private var sendStarting = false

    /// 发送任务序号。
    ///
    /// 场景：撤回 → 立刻重发。旧任务的收尾代码会把 sendTask 置 nil，
    /// 如果不区分是谁的收尾，就会把**新任务**的句柄误清掉，
    /// 导致下一次撤回又掐不断。用序号只让"最新那个"清自己。
    private var sendSeq = 0

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

        // 顺手把公网域名的连接预热掉。
        // 用户在外面用流量时域名是唯一通路，而它冷启动要 2.7~4.3 秒。
        // 改成"一打开就开始握手"，等用户真正发消息时连接已经热了。
        // 不阻塞任何东西，失败也无声无息。
        client.prewarm()
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

    // MARK: - 记忆续接（换账号/换来源后接着聊）

    /// 把当前对话压成一段「交接说明」，给下一个模型看。
    ///
    /// 2026-10-31 用户要求：「ipa 要添加 ai 记忆功能，比如我正在和你聊天，结果
    /// 没有积分了、额度了，我要换另一个账号的 ai 来继续接下来的项目，别让他
    /// 断开记忆重新开始，需要对接上一个 ai 的对话」。
    ///
    /// 为什么不直接把全部历史带过去：
    /// 不同来源的模型是两套上下文，换过去之后本来就要重讲一遍；
    /// 而全量历史往往几万字，一次塞进去要么超长被拒、要么白烧一大笔积分
    /// ——用户恰好是因为额度用完才换的，这时候更经不起浪费。
    ///
    /// 所以压成三段：
    ///   1. 我们在做什么（取会话标题 + 最初几条用户消息）
    ///   2. 已经定下来的结论（取助手回复里"看起来是结论"的行）
    ///   3. 下一步要做什么（取最后一条用户消息 + 最后一条助手回复的尾部）
    /// 目标是让新模型能在读完这三百来字后**接着说**，而不是从零开始。
    ///
    /// - Parameter upTo: 只统计到这个下标之前（不含）的消息。
    ///   自动交接时用「换账号那一刻的条数」，这样换完之后新说的话
    ///   不会被当成"背景"重复带进去。
    ///   传 nil = 用当前全部消息（手动点「生成交接」时用）。
    /// - Parameter mentionSource: 是否在结尾提一句「另外附了源码」。
    ///   只有手动「生成交接」会同时发源码文件（见 prepareHandoff），
    ///   自动交接只是把摘要插进消息里、并没有附件，写这句就是骗人。
    func buildHandoff(upTo: Int? = nil, mentionSource: Bool = false) -> String {
        let pool: ArraySlice<ChatMessage>
        if let upTo {
            let end = min(upTo, messages.count)
            pool = messages[0..<max(0, end)]
        } else {
            pool = messages[messages.startIndex...]
        }

        // 只算没撤回的消息——撤回的语义就是"没说过"，不能带进交接
        let live = pool.filter { !$0.recalled && !$0.text.isEmpty }
        guard !live.isEmpty else { return "" }

        let title = currentSessionTitle
        var out: [String] = []
        out.append("# 交接：\(title)")
        out.append("")
        out.append("下面是我和上一个 AI 的对话摘要。上一个因为额度用完了，")
        out.append("现在换你来接着做。**请你先读完整段，然后直接说「我接上了」**，")
        out.append("不要从头再问一遍已经说清楚的事。")
        out.append("")

        // ── 1. 目标：开头两轮，说明这事是怎么起的
        out.append("## 我们在做什么")
        let opening = live.prefix(4).filter { $0.role == "user" }
        if opening.isEmpty {
            out.append("（这个会话还没说过具体目标）")
        } else {
            for m in opening {
                out.append("- " + oneLine(m.text, limit: 200))
            }
        }
        out.append("")

        // ── 2. 已定的结论：从助手回复里挑"像结论"的行
        out.append("## 已经定下来的")
        var decided: [String] = []
        for m in live where m.role == "assistant" {
            for raw in m.text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.count >= 8 else { continue }
                // 只挑陈述性/结论性的句子，跳过寒暄和过渡
                let isNoise = line.hasPrefix("好的") || line.hasPrefix("明白")
                    || line.hasPrefix("当然") || line.hasPrefix("以下是")
                    || line.hasPrefix("希望") || line.hasSuffix("：")
                if isNoise { continue }
                // 结论常见的开头：编号、重点标记、明确判断
                let looksLikePoint = line.hasPrefix("- ") || line.hasPrefix("* ")
                    || line.hasPrefix("1.") || line.hasPrefix("2.") || line.hasPrefix("3.")
                    || line.contains("所以") || line.contains("结论")
                    || line.contains("要注意") || line.contains("因为")
                    || line.contains("必须") || line.contains("建议")
                if looksLikePoint {
                    decided.append(oneLine(line, limit: 160))
                }
                if decided.count >= 12 { break }
            }
            if decided.count >= 12 { break }
        }
        if decided.isEmpty {
            // 挑不出结构化结论就退一步：把助手回复的首句列出，总比没有强
            for m in live where m.role == "assistant" {
                let firstLine = m.text.components(separatedBy: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                if !firstLine.isEmpty { decided.append(oneLine(firstLine, limit: 140)) }
                if decided.count >= 6 { break }
            }
        }
        if decided.isEmpty {
            out.append("（还没有形成明确结论）")
        } else {
            for d in decided { out.append("- " + d) }
        }
        out.append("")

        // ── 3. 进行到哪一步：最后一条用户意图 + 最后一条回复的收尾
        out.append("## 现在进行到哪一步")
        if let lastUser = live.last(where: { $0.role == "user" }) {
            out.append("我最后说的事：")
            out.append("> " + oneLine(lastUser.text, limit: 400))
        }
        if let lastAI = live.last(where: { $0.role == "assistant" }) {
            // 取尾部 —— 回复的重点通常在后半段（结论、下一步）
            let tail = String(lastAI.text.suffix(500))
            out.append("")
            out.append("上一个 AI 最后交代的：")
            out.append("> " + oneLine(tail, limit: 500))
        }
        out.append("")

        // ── 4. 项目线索：仓库地址、磁盘路径、构建命令
        //
        // 用户真实场景：让 AI 在电脑上把项目做完，聊天里一个代码块都没有。
        // 这时《源码》那份是空的，必须有这一节兜住，否则交接等于没交。
        let clues = buildProjectClues(upTo: upTo)
        if clues.count > 0 {
            out.append("")
            out.append(clues.doc)
            out.append("")
        }

        out.append("---")
        out.append("以上是背景。请接着做，不要再问一遍上面已经说清的事。")
        if mentionSource {
            out.append("")
            out.append("另外我一并发了《源码》那份文件（同一个消息里的另一个 md），")
            out.append("里面是这次对话里出现过的全部代码。需要看实现就直接用它，")
            out.append("不要让我再重新贴一遍。")
        } else if clues.count > 0 {
            // 没源码但有线索：把「你自己去取」这句话说清楚，
            // 否则模型会以为项目是空的，要求用户从头贴一遍。
            out.append("")
            out.append("这次对话里没有贴代码（活是在我电脑上干的，手机拿不到文件），")
            out.append("但上面「项目线索」里有真实的仓库地址、路径和命令。")
            out.append("请按那些地址自己去取代码，不要让我重新贴。")
        }
        return out.joined(separator: "\n")
    }

    /// 从对话里扫出「项目线索」：仓库地址、磁盘路径、构建命令、版本号。
    ///
    /// 为什么需要这一节：用户经常是让 AI 在**电脑上**把活干完
    /// （比如从零做完一个 ipa），聊天里只留下「做好了」。
    /// 这时《源码》那份是空的，交接文档里若再没有路径和仓库地址，
    /// 下一个 AI 等于从零开始问起 —— 而这些东西本来就在聊天文字里躺着：
    /// 「项目在 E:\xxx，仓库是 github.com/xxx/yyy，推上去跑 CI」。
    ///
    /// 全部用正则从已有文字里捞，不花一次对话、不烧积分。
    ///
    /// - Parameter upTo: 只统计这个下标之前（不含），语义同 buildHandoff。
    func buildProjectClues(upTo: Int? = nil) -> (doc: String, count: Int) {
        let pool: ArraySlice<ChatMessage>
        if let upTo {
            let end = min(upTo, messages.count)
            pool = messages[0..<max(0, end)]
        } else {
            pool = messages[messages.startIndex...]
        }
        let text = pool.filter { !$0.recalled }.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return ("", 0) }

        var sections: [String] = []
        var total = 0

        // 仓库 / 网址
        let urls = Self.unique(Self.matches(#"https?://[A-Za-z0-9._\-/:@?=&#%+~]+"#, in: text), limit: 12)
            + Self.unique(Self.matches(#"github\.com/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+"#, in: text), limit: 8)
        if !urls.isEmpty {
            sections.append("### 仓库 / 网址")
            for u in Self.unique(urls, limit: 14) { sections.append("- " + u) }
            total += urls.count
        }

        // 磁盘路径
        var paths = Self.unique(Self.matches(#"[A-Za-z]:\\[^\s"'<>|，。；）]+"#, in: text), limit: 12)
        paths += Self.unique(Self.matches(#"/(?:Users|home|opt|etc|var|www|usr|private)/[^\s"'<>|，。；）]+"#, in: text), limit: 12)
        if !paths.isEmpty {
            sections.append("### 项目所在路径")
            for p in Self.unique(paths, limit: 18) { sections.append("- `" + p + "`") }
            total += paths.count
        }

        // 项目内文件（带扩展名的那种）
        //
        // 尾巴上的 `(?![A-Za-z0-9])` 不能省：没有它，`github.com` 会被
        // 当成「一个叫 github.c 的文件」，`relay.example.com` 同理。
        // 加了之后要求扩展名后面不能再跟字母数字，误报就没了。
        let files = Self.unique(Self.matches(
            #"[A-Za-z0-9_][A-Za-z0-9_./\-]*\.(?:swift|py|sh|mm|m|h|c|js|ts|jsx|tsx|json|yml|yaml|plist|xml|md|deb|ipa|zip|conf|ini|toml)(?![A-Za-z0-9])"#,
            in: text), limit: 20)
        if !files.isEmpty {
            sections.append("### 提到的文件")
            for f in files { sections.append("- `" + f + "`") }
            total += files.count
        }

        // 构建 / 部署命令：按行扫，认常见的工具前缀
        let cmdMarks = ["git ", "npm ", "pnpm ", "yarn ", "pip ", "pip3 ",
                        "python ", "python3 ", "xcodebuild", "xcodegen",
                        "brew ", "docker ", "gh ", "curl ", "ssh ", "scp ",
                        "make ", "cargo ", "go build", "swift build",
                        "dpkg-deb", "ldid", "codesign", "Sideloadly"]
        var cmds: [String] = []
        var seenCmd = Set<String>()
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.isEmpty || line.count > 160 { continue }
            // 去掉行首的 $ 或 > 提示符
            while let f = line.first, f == "$" || f == ">" || f == " " { line.removeFirst() }
            guard cmdMarks.contains(where: { line.hasPrefix($0) }) else { continue }
            guard !seenCmd.contains(line) else { continue }
            seenCmd.insert(line)
            cmds.append(line)
            if cmds.count >= 15 { break }
        }
        if !cmds.isEmpty {
            sections.append("### 构建 / 运行命令")
            for c in cmds { sections.append("```\n" + c + "\n```") }
            total += cmds.count
        }

        // 版本号（只在有别的线索时才提，单纯出现一个数字没意义）
        if total > 0 {
            let vers = Self.unique(Self.matches(#"\b\d+\.\d+\.\d+\b"#, in: text), limit: 6)
            if !vers.isEmpty {
                sections.append("### 出现过的版本号")
                sections.append("- " + vers.joined(separator: "、"))
            }
        }

        guard total > 0 else { return ("", 0) }

        var out: [String] = []
        out.append("## 项目线索（从聊天记录里原样扫出来的）")
        out.append("")
        out.append("> 下面这些地址、路径、命令都不是我编的，是对话里真实出现过的原文。")
        out.append("> **请直接按这些去定位代码，不要再问我要。**")
        out.append("")
        out.append(contentsOf: sections)
        return (out.joined(separator: "\n"), total)
    }

    /// 按出现顺序去重
    private static func unique(_ list: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in list where !seen.contains(s) {
            seen.insert(s)
            out.append(s)
            if out.count >= limit { break }
        }
        return out
    }

    /// 把一个正则的所有命中按出现顺序取出来（自带去重与清洗）
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            // 正则贪婪吃到中文标点时切掉，否则「E:\项目\README.md。」会带个句号
            while let last = s.last {
                if "，。；、）】".contains(last) { s.removeLast() } else { break }
            }
            guard s.count >= 4 else { continue }
            out.append(s)
        }
        return out
    }

    /// 把会话里出现过的代码块按顺序汇总成一份「源码」文档。
    ///
    /// 为什么不打包成 zip：这是个聊天 App，本地并没有工程目录，
    /// 唯一的「源码」就是对话里贴出来的那些代码；而下一个 AI 读纯文本
    /// 最省事，zip 它未必解得开。所以拼成一个 md，每段带语言标注。
    ///
    /// - Parameter upTo: 只统计这个下标之前（不含），语义同 buildHandoff。
    func buildSourceBundle(upTo: Int? = nil) -> (doc: String, count: Int) {
        let pool: ArraySlice<ChatMessage>
        if let upTo {
            let end = min(upTo, messages.count)
            pool = messages[0..<max(0, end)]
        } else {
            pool = messages[messages.startIndex...]
        }
        let live = pool.filter { !$0.recalled && !$0.text.isEmpty }

        var body: [String] = []
        var n = 0
        for m in live where m.role == "assistant" {
            for b in Self.splitCodeBlocks(m.text).blocks {
                let code = b.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { continue }
                n += 1
                let lang = b.lang.isEmpty ? "text" : b.lang
                body.append("## \(n). \(lang)")
                body.append("")
                body.append("```\(lang)")
                body.append(code)
                body.append("```")
                body.append("")
            }
        }
        guard n > 0 else { return ("", 0) }

        let trip = currentSessionTitle.isEmpty ? "本次会话" : currentSessionTitle
        var head: [String] = []
        head.append("# 源码：\(trip)")
        head.append("")
        head.append("> 从这次对话里按出现顺序摘出的全部代码，共 \(n) 段。")
        head.append("> 请配合《交接-\(trip)》一起看：那份讲目标、结论和进度，这份是代码本身。")
        head.append("")
        head.append("---")
        head.append("")
        return ((head + body).joined(separator: "\n"), n)
    }

    /// 取一行、压掉多余空白、超长截断
    private func oneLine(_ s: String, limit: Int) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "\t", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > limit {
            t = String(t.prefix(limit)) + "…"
        }
        return t
    }

    // MARK: - 让 AI 自己整理交接包（一键，不用用户打字）

    /// 「生成交接 → 生成」时替用户发出去的格式指令。
    ///
    /// 为什么走正常聊天通道、而不是偷偷调一次接口：
    /// 用户在聊天里能看到"我让它整理交接"这件事，不会凭空多出一条没来源的消息；
    /// 而且重连、换地址、能力判断这些逻辑全部复用，不用另写一份。
    static let handoffPrompt = """
    换 AI 前把材料整理好。请严格按下面两段格式输出，两段之外不要写别的话：

    ===HANDOFF===
    # 项目目标（一句话）
    # 已经完成的
    # 还没做的
    # 关键约束（技术栈、不能改的地方、已经踩过的坑）
    ===SOURCES===
    全部源码，一个文件一个代码块；每个代码块第一行用注释写出文件路径
    """

    /// 一键生成交接包：自动让 AI 把交接文档和全部源码写出来。
    ///
    /// 2026-10-31 用户：「我怎么能让他直接生成交接文档和源码，
    /// 而不是我一个字一个字去打字让他给我准备」。
    ///
    /// 所以这一步是**替用户发指令**，不是本地拼一段摘要：
    /// 发出去 → 等这一轮回复结束 → 拆成两个文件 → 挂到输入框附件区。
    /// 代价是一次模型调用，界面上会先问一句再动手。
    func generateHandoffPackage() {
        guard !sending, !sendStarting else {
            toast = "等这条回复说完再生成"
            return
        }
        guard messages.contains(where: { $0.role == "user" }) else {
            toast = "这个会话还没有内容，不用交接"
            return
        }
        handoffBuilding = true
        input = Self.handoffPrompt
        send()

        // 起手看门狗：3 秒还没真正开始发送（没选模型、没连上），
        // 就把标记复位，否则按钮会一直挂在"整理中"。
        handoffWatch?.cancel()
        handoffWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.handoffBuilding, !self.sending, !self.sendStarting {
                self.handoffBuilding = false
                self.toast = "没能开始整理，检查一下模型和连接"
            }
        }
    }

    /// 把这一轮回复拆成交接文档 + 源码两个文件，并挂到输入框附件区。
    ///
    /// 兜底策略（模型不照格式写的时候）：交接文档退成本地摘要、
    /// 源码退成"从这段回复里扒代码块"。宁可少，也别给用户一个空文件。
    private func materializeHandoffPack(at idx: Int) {
        guard idx >= 0, idx < messages.count else { return }
        let m = messages[idx]
        // 发送失败时会留下「（没发出去）」，别把它做成交接文档
        guard !m.failed else {
            toast = "这次没发出去，等连上再点一次「生成交接」"
            return
        }
        let reply = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            toast = "AI 没给出内容，再点一次「生成交接」试试"
            return
        }

        let trip = currentSessionTitle.isEmpty ? "本次会话" : currentSessionTitle
        let parts = Self.splitHandoffPack(reply)

        // 交接正文
        let aiBrief = (parts.handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = aiBrief.isEmpty ? buildHandoff() : aiBrief

        // 源码正文：优先用 SOURCES 段；没有就从整段回复里扒代码块
        var src = (parts.sources ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if src.isEmpty {
            let blocks = Self.splitCodeBlocks(reply)
            src = blocks.blocks.isEmpty ? "" : Self.reassemble(blocks).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let files = Self.countCodeBlocks(src)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var doc = "# 交接：\(trip)\n\n"
        doc += "> 由上一个 AI 整理于 \(df.string(from: Date()))\n"
        if !src.isEmpty {
            doc += "> 源码另附一份（同一个消息里的《源码-\(trip)》），要看实现直接用它。\n"
        }
        doc += "\n---\n\n"
        doc += brief
        doc += "\n"

        var made: [AIFile] = []
        if let rec = FileStore.writeText(title: "交接-\(trip)",
                                        body: doc,
                                        ext: "md",
                                        sessionId: currentSessionId,
                                        sessionTitle: currentSessionTitle) {
            FileLibrary.shared.add(rec)
            made.append(rec)
        }

        var srcDoc = ""
        if !src.isEmpty {
            srcDoc = "# 源码：\(trip)\n\n"
            srcDoc += files > 0 ? "> 共 \(files) 个代码块。\n\n---\n\n" : "> 整理于 \(df.string(from: Date()))\n\n---\n\n"
            srcDoc += src
            srcDoc += "\n"
            if let rec = FileStore.writeText(title: "源码-\(trip)",
                                             body: srcDoc,
                                             ext: "md",
                                             sessionId: currentSessionId,
                                             sessionTitle: currentSessionTitle) {
                FileLibrary.shared.add(rec)
                made.append(rec)
            }
        }

        guard !made.isEmpty else {
            toast = "文件没写成功，看看手机存储是不是满了"
            return
        }

        // 挂到输入框附件区，只替换上一次的交接包
        let added = made.compactMap { Attachment.file(from: $0.url).0 }
        pending = pending.filter {
            !($0.name.hasPrefix("交接-") || $0.name.hasPrefix("源码-"))
        } + added

        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = "这是上一个 AI 的交接文档和源码，都在附件里。请接着做，别从头再问一遍。"
        }

        toast = src.isEmpty
            ? "交接文档做好了，但 AI 这次没贴源码；已放到输入框"
            : "交接文档 + 源码（\(files) 个代码块）都做好了，已放到输入框，点发送即可"
    }

    /// 从回复里切出 ===HANDOFF=== 和 ===SOURCES=== 两段。
    ///
    /// 模型不老实、标记缺一个的时候也要能认出另一半，
    /// 所以不是"两个都有才解析"那种硬匹配。
    private static func splitHandoffPack(_ s: String) -> (handoff: String?, sources: String?) {
        let hTag = "===HANDOFF==="
        let sTag = "===SOURCES==="
        let h = s.range(of: hTag, options: .caseInsensitive)
        let src = s.range(of: sTag, options: .caseInsensitive)

        switch (h, src) {
        case let (h?, s?):
            if h.upperBound <= s.lowerBound {
                return (String(s[h.upperBound..<s.lowerBound]), String(s[s.upperBound...]))
            }
            // 两段顺序反了：按标记各自切，别丢内容
            return (String(s[s.upperBound..<h.lowerBound]), String(s[h.upperBound...]))
        case let (h?, nil):
            return (String(s[h.upperBound...]), nil)
        case let (nil, s?):
            return (String(s[..<s.lowerBound]), String(s[s.upperBound...]))
        case (nil, nil):
            return (s, nil)
        }
    }

    /// 数一下源码文档里有多少个代码块（给人看的概览，不参与逻辑）
    private static func countCodeBlocks(_ s: String) -> Int {
        var n = 0
        var pos = s.startIndex
        while let r = s.range(of: "```", range: pos..<s.endIndex) {
            n += 1
            pos = r.upperBound
        }
        return n / 2
    }

    /// 生成交接包：**交接文档 + 源码**，两份都落进产物库，
    /// 并直接挂到输入框的附件区 —— 用户点一下发送，两份东西一起送给下一个 AI。
    ///
    /// 2026-10-31 用户要求：「字改成生成交接，位置放在清空会话下面，
    /// 点击生成交接以后，他会给我生成交接文档和源码，
    /// 我直接二个东西都发送给下个 ai 他就能直接干活了」。
    ///
    /// 所以不再把摘要塞进输入框：那样得用户自己复制粘贴，几千字还会把
    /// 输入区撑满。改成附件后，交接文档和源码天然是"两个文件"，
    /// 转给谁都不用二次加工。
    func prepareHandoff() {
        // 先算源码，才知道交接文档结尾要不要提「另附源码」这件事
        let src = buildSourceBundle()
        let brief = buildHandoff(mentionSource: src.count > 0)
        guard !brief.isEmpty else {
            toast = "这个会话还没有内容，不用交接"
            return
        }
        let trip = currentSessionTitle.isEmpty ? "本次会话" : currentSessionTitle

        var made: [AIFile] = []

        // ① 交接文档：目标 / 已定结论 / 进行到哪一步
        if let rec = FileStore.writeText(title: "交接-\(trip)",
                                        body: brief,
                                        ext: "md",
                                        sessionId: currentSessionId,
                                        sessionTitle: currentSessionTitle) {
            FileLibrary.shared.add(rec)
            made.append(rec)
        }

        // ② 源码：对话里出现过的全部代码
        if src.count > 0,
           let rec = FileStore.writeText(title: "源码-\(trip)",
                                         body: src.doc,
                                         ext: "md",
                                         sessionId: currentSessionId,
                                         sessionTitle: currentSessionTitle) {
            FileLibrary.shared.add(rec)
            made.append(rec)
        }

        guard !made.isEmpty else {
            toast = "文件没写成功，看看手机存储是不是满了"
            return
        }

        // 记到会话上，下次点还能看到上次生成的那份
        if let i = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[i].handoff = brief
            SessionStore.save(sessions)
        }

        // 直接挂到输入框附件区。用户不用去产物面板里找，
        // 也不用分别点两次分享 —— 点发送就是"两个东西一起发出去"。
        //
        // 只替换上一次生成的交接包（按文件名前缀认："交接-" / "源码-"），
        // 不一把清空：用户手上可能还挂着别的附件（截图之类），
        // 点一下交接就把它们弄没了会很恼火。
        let added = made.compactMap { Attachment.file(from: $0.url).0 }
        pending = pending.filter {
            !($0.name.hasPrefix("交接-") || $0.name.hasPrefix("源码-"))
        } + added

        // 输入框空着就补一句引导语：AI 收到两个附件，还得知道要他干什么。
        // 用户已经打了字就不动，免得把他写的覆盖掉。
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = "这是上一个 AI 的交接文档和源码，都在附件里。请接着做，别从头再问一遍。"
        }

        if src.count > 0 {
            toast = "已生成交接文档 + 源码（\(src.count) 段代码），已放到输入框，点发送即可"
        } else {
            toast = "已生成交接文档（这次对话没有代码，没生成源码），点发送即可"
        }
    }

    /// 把产物挂到某个对话的输入框附件区（产物面板长按 →「添加到对话」）。
    ///
    /// 顺序很关键：`openSession` 会把 pending 清空（换对话就该从干净的输入区开始），
    /// 所以必须**先切对话、再挂附件**，反过来的话刚挂上的会被清掉。
    func attach(file: AIFile, to targetSessionId: String) {
        guard sessions.contains(where: { $0.id == targetSessionId }) else { return }
        guard let a = Attachment.file(from: file.url).0 else {
            toast = "这个文件读不出来，没法添加"
            return
        }
        if targetSessionId != currentSessionId {
            openSession(targetSessionId)
        }
        // 同名附件只留一份：连点几次不该在输入框里堆出好几个一样的芯片
        pending = pending.filter { $0.name != a.name } + [a]

        let name = sessions.first(where: { $0.id == targetSessionId })?.displayTitle ?? "对话"
        toast = "已添加到「\(name)」，去输入框点发送"
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

    /// 换模型。
    ///
    /// 2026-10-31：换模型也等于换了个 AI（尤其是跨来源时，opus 换 gpt
    /// 就是两套上下文）。用户要求「换账号别断开记忆」，所以走这里统一处理：
    /// 换了就标记下次发送要带背景。
    ///
    /// 为什么不让界面直接 `store.currentModel = id`：
    /// 那样散在各处赋值，很容易漏掉交接这一步。
    /// 收成一个方法，语义也清楚。
    func selectModel(_ id: String) {
        guard currentModel != id else { return }
        let hadTalk = messages.contains { !$0.recalled && !$0.text.isEmpty }
        currentModel = id
        if hadTalk { armAutoHandoff() }
    }

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
    ///
    /// 2026-10-31 用户要求「换另一个账号的 AI 继续，别断开记忆重新开始」，
    /// 并明确选了**自动化**方案（不要手动点按钮）。
    ///
    /// 所以换来源时只记两件事，不弹任何需要用户操作的窗：
    ///   1. 记下"换的这一刻已经聊到第几条"→ 这些算背景
    ///   2. 置一个标记，下一条消息发出去时会自动把背景带上
    /// 摘要完全在本地拼（buildHandoff），不额外调模型，不花积分。
    func switchProvider(_ id: String) async {
        guard settings.activeProvider != id else { return }
        settings.activeProvider = id
        models = []
        currentModel = ""
        base = nil
        pending = []
        await bootstrap()
        armAutoHandoff()
    }

    /// 标记「下次发送要带上之前的背景」。
    ///
    /// 只在真有内容可交接时才置位，空会话置位没有意义。
    private func armAutoHandoff() {
        let hasTalk = messages.contains { !$0.recalled && !$0.text.isEmpty }
        guard hasTalk else { return }
        autoHandoffCutoff = messages.count
        needsHandoffHint = true
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
        // 2026-10-31 修「选了文件点确定没反应」：
        // 一定要给反馈。原来这条路径三种结果（成功/半成功/失败）全都静默，
        // 用户根本不知道到底加没加进去。
        let (a, note) = AttachmentMaker.file(from: url)
        if let a {
            pending.append(a)
            // 半成功（二进制只发了文件名）也要说清楚，别让用户以为 AI 读到了内容
            toast = note ?? "已添加 \(a.name)"
        } else {
            toast = note ?? "这个文件读取失败"
        }
    }

    func removePending(_ a: Attachment) {
        pending.removeAll { $0.id == a.id }
    }

    // MARK: - 撤回

    /// 撤回一条消息。
    ///
    /// 2026-10-31 用户要求：「发出去的对 AI 指令的消息上面加一个撤回消息的功能」，
    /// 并补充「消息撤回后，AI 不在中转站请求响应，等我把下一条消息发给他的时候
    /// 他才能去请求响应」。
    ///
    /// 所以撤回要做三件事，缺一不可：
    ///   1. 标记 recalled —— 历史和界面上都不当它存在
    ///   2. 如果这条是"正在等回复"的那条 → cancel 发送任务，立刻断开上游流
    ///   3. 顺带把紧跟它的那条空的助手占位消息删掉（否则会留一个空气泡）
    func recall(_ msg: ChatMessage) {
        guard let i = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        guard !messages[i].recalled else { return }

        // 1. 标记
        messages[i].recalled = true

        // 2. 如果这条是「正在等回复」的那条，掐断请求
        //
        // 判断条件不能只看 sending：send() 建完 Task 到 runSend 里把 sending
        // 置 true 之间有几十微秒的空档，用户手快在这个空档撤回就会漏掉。
        // sendTask != nil 说明任务已经受理，一并算「在跑」。
        let wasStreaming = sending || sendTask != nil
        if wasStreaming {
            sendTask?.cancel()
            sendTask = nil
            sendStarting = false
            sending = false
        }

        // 3. 清掉它后面那个空的助手占位（只清紧邻且为空的，别误删有内容的）
        let next = i + 1
        if next < messages.count,
           messages[next].role == "assistant",
           messages[next].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: next)
        }

        if wasStreaming { errorText = nil }
        syncCurrentSession()
        toast = "已撤回"
    }

    /// 把一条已撤回消息的原文填回输入框，等于「反悔，我想重发」。
    ///
    /// 2026-10-31 改成气泡下方小图标后，这个动作挂在「点那条灰掉的消息」上。
    ///
    /// 注意这里**不调 recall()**：那个方法开头有
    /// `guard !messages[i].recalled else { return }`，对已撤回的消息会直接返回，
    /// 后面的恢复逻辑就永远不执行 —— 这正是撤回改版后最容易踩的坑。
    /// 恢复内容跟"要不要再撤回一次"没有关系，所以单独处理。
    func recallAndRestore(_ msg: ChatMessage) {
        // 输入框里已经有字就别覆盖了，用户可能正在写新的
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast = "输入框里还有内容，先发或清空再撤销"
            return
        }

        if !msg.recalled {
            // 还没撤回：先撤回（会掐断请求、删空气泡），再把原文填回去
            recall(msg)
        } else {
            // 已经撤回过：把它标回正式的，原文照样填进输入框。
            // 为什么不直接"取消撤回"：用户点这条多半是想改一改重发，
            // 填进输入框比在历史里复活更符合意图。
        }

        let old = msg.text
        if old.isEmpty {
            // 只有附件没有文字的消息，文字恢复不出来，给个提示别让他干等
            toast = "这条只有附件，附件没法恢复，请重新选一次"
        } else {
            input = old
            toast = "原文已填回输入框"
        }
    }

    // MARK: - 发送

    /// 发送入口。**不再是 async**——这是 2026-10-31 为"撤回能掐断请求"做的改造。
    ///
    /// 原来的写法是 `func send() async`，由界面 `Task { await store.send() }` 调用。
    /// 那样 Task 句柄建在外面、存不下来，撤回时 `sendTask?.cancel()` 永远是空操作，
    /// 界面上消息灰掉了，后台还在读上游 token，白烧积分。
    ///
    /// 现在改成：这里自己建 Task 并存进 `sendTask`，正文挪进 `runSend()`。
    /// 于是 `recall()` 里的 `sendTask?.cancel()` 才真的掐得上。
    ///
    /// 调用方要改：`await store.send()` → `store.send()`。
    func send() {
        guard !sendStarting, !sending else { return }
        sendStarting = true
        sendSeq += 1
        let seq = sendSeq
        // ChatStore 是 @MainActor，这里建出来的 Task 会继承同一个隔离域，
        // 所以 runSend 里的 self 操作不用再包 MainActor.run。
        sendTask = Task { [weak self] in
            await self?.runSend()
            guard let self else { return }
            // 只让最新那个任务清自己的句柄，别把后来者的也清了
            guard self.sendSeq == seq else { return }
            self.sendStarting = false
            self.sendTask = nil
        }
    }

    private func runSend() async {
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

        // 在等 bootstrap 的过程中用户可能已经撤回了，别把消息补进去
        if Task.isCancelled { return }

        input = ""
        pending = []
        errorText = nil
        capSuggestion = nil
        messages.append(ChatMessage(role: "user", text: text, attachments: attach))
        messages.append(ChatMessage(role: "assistant", text: "", model: model))
        let idx = messages.count - 1
        sending = true

        // 历史里只带「有文字或附件」的，跳过占位的空助手消息。
        // 2026-10-31：撤回的消息也要跳过——撤回的语义就是"当它没说过"。
        var history = messages.dropLast().compactMap { m -> (role: String, text: String, attachments: [Attachment])? in
            if m.recalled { return nil }
            if m.role == "assistant" && m.text.isEmpty && !m.failed { return nil }
            return (m.role, m.text, m.attachments)
        }

        // 2026-10-31 自动交接（用户选的「自动化」方案）：
        // 换过来源之后发第一条消息时，把之前的对话压成一段背景注进去，
        // 让新模型知道"这是在接着做"，而不是重新开始。
        //
        // 为什么做成一条 system 消息插在最前面，而不是把摘要拼进用户这句话里：
        // 拼进用户消息会让用户自己发的话被淹没在一大段背景后面，
        // 界面上看着也怪（他明明只打了一句"继续"）。
        // 用 system 角色语义最准确：这不是用户说的话，是环境交代。
        if let cutoff = autoHandoffCutoff {
            autoHandoffCutoff = nil        // 只交接一次，别每条都带
            needsHandoffHint = false
            // buildHandoff 返回的是非可选 String（空串表示没内容可交接），
            // 所以这里不能写 `if let brief = ...`，直接判空。
            let brief = buildHandoff(upTo: cutoff)
            if !brief.isEmpty {
                history.insert(("system", brief, []), at: 0)
            }
        }

        let key = settings.key(for: p)
        do {
            try await client.stream(base: b, key: key, model: model, messages: history) { delta in
                Task { @MainActor in
                    guard idx < self.messages.count else { return }
                    self.messages[idx].text += delta
                }
            }
        } catch is CancellationError {
            // 用户撤回导致的中断：不是错误，什么都不用提示。
            // 那条助手占位消息已经由 recall() 删掉了，这里别再去动 messages。
            sending = false
            sendStarting = false
            return
        } catch {
            // 撤回后不需要把错误甩给用户，也不该继续走"自动重连再发一遍"那套
            // ——用户就是要它停，别自作主张重发。
            if Task.isCancelled {
                sending = false
                sendStarting = false
                return
            }
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
                if Task.isCancelled { sending = false; sendStarting = false; return }
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
        // 撤回场景下 messages 已经被改过了（占位气泡被删），
        // 这时候再 sync / archive 会写进一条已撤回的内容，必须挡掉。
        if Task.isCancelled { return }
        syncCurrentSession()

        // 「生成交接」引发的那一轮回复：交给拆包逻辑处理，不做普通归档。
        // 否则产物库里会多出一份跟交接包重复的 md，用户看到两个一样的东西。
        if handoffBuilding {
            handoffBuilding = false
            handoffWatch?.cancel()
            materializeHandoffPack(at: idx)
            return
        }

        // 回复完成，把它存成文件进「我的文件」。
        // 放在 syncCurrentSession 之后：那时标题已经从首条用户消息补齐，
        // 文件名才能是「中转站搭建」而不是「新对话」。
        archiveReply(at: idx)
    }

    /// 把一条 AI 回复里**真正值得留存的产物**存成文件，放进「我的文件」。
    ///
    /// ⚠️ 2026-10-31 用户明确纠正（重要，别再退回旧行为）：
    ///   原话「不是说每句话都需要写进产物，全部产物中我只需要 ai 给我生成的文件
    ///   和 md 这个的，不是说把所有对话都生成 md」
    ///   「就比如咱们俩说的所有话你都没有生成产物，只是所有任务结束了，
    ///   你才把生成的产物给我」
    ///
    /// 所以规则从「每条回复都存」改成「**只有带交付物才存**」：
    ///   - 先剥离 ``` 代码块，看代码块**之外**还有没有成段正文
    ///   - 全是解释性文字（"好的""明白了""这是因为…"）→ **不存**
    ///   - 有代码块 / 有明确交付物（文件清单、步骤清单）→ 存，且只存交付部分
    ///
    /// 为什么要剥离代码块再判断：改代码时 AI 的回复往往是
    /// "问题在于 xxx，改成这样：```swift ...```"，正文只是解释，
    /// 真正的产物是那段代码。这种要存，但存的是代码，不是解释。
    private func archiveReply(at idx: Int) {
        guard idx >= 0, idx < messages.count else { return }
        let m = messages[idx]
        guard m.role == "assistant", !m.failed else { return }
        let body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        // 把回复拆成「正文」和「代码块」两部分（正文现在不写进文件，只用来判断）
        let parts = Self.splitCodeBlocks(body)
        let codeCount = parts.blocks.count

        // 判定标准（2026-10-31 第二次收紧，用户原话：
        // 「我不需要的是把 ai 的聊天记录都当成产物」）：
        //   **只有带代码块 / 文件内容块才算产物。**
        //
        // 上一版还允许「有编号列表、出现'步骤''清单'字样」也算，
        // 结果只要 AI 正常解释一件事（"分三步：1、… 2、…"），
        // 整段聊天就被存成 md —— 判定太松，等于没判定。
        // 这不是产物，这是聊天记录，聊天记录本来就在会话里。
        guard codeCount > 0 else { return }

        // 找这条回复对应的那个问题，做成文件标题
        var question = ""
        var i = idx - 1
        while i >= 0 {
            if messages[i].role == "user" { question = messages[i].text; break }
            i -= 1
        }

        // 文件里**只放产物本身**：一行标题 + 代码块。
        // 模型名、时间、解释性正文全部不写进去 ——
        // 那些是对话过程，写进文件会让产物看起来还是聊天记录。
        // 时间在文件名里已经有了（-20261031-001030），不重复。
        var doc = ""
        if !question.isEmpty {
            doc += "# \(question.replacingOccurrences(of: "\n", with: " "))\n\n"
        }
        doc += Self.reassemble(parts)
        doc += "\n"

        let title = question.isEmpty
            ? (currentSessionTitle.isEmpty ? "产出" : currentSessionTitle)
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

    /// 把一段文本拆出「去掉代码块的正文」和「所有代码块」
    private static func splitCodeBlocks(_ s: String) -> (prose: String, blocks: [(lang: String, code: String)]) {
        var prose = ""
        var blocks: [(String, String)] = []
        var inBlock = false
        var lang = ""
        var buf = ""
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inBlock {
                    blocks.append((lang, buf.trimmingCharacters(in: .newlines)))
                    buf = ""
                    lang = ""
                    inBlock = false
                } else {
                    inBlock = true
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inBlock { buf += line + "\n" } else { prose += line + "\n" }
        }
        if inBlock, !buf.isEmpty {   // 没闭合也认，别丢内容
            blocks.append((lang, buf.trimmingCharacters(in: .newlines)))
        }
        return (prose, blocks)
    }

    private static func reassemble(_ p: (prose: String, blocks: [(lang: String, code: String)])) -> String {
        var out = ""
        for (i, b) in p.blocks.enumerated() {
            if i > 0 { out += "\n\n" }
            out += "```" + b.lang + "\n" + b.code + "\n```\n"
        }
        return out
    }

    /// 没有代码块时，判断正文是不是「交付物形状」。
    ///
    /// ⚠️ 2026-10-31 起**已停用**（archiveReply 只认代码块）。
    /// 保留在这里只是为了说明教训：靠「出现'步骤''清单'字样」来判断产物，
    /// 任何一段正常解释都会被误判。真要做这层判断得靠模型返回结构化标记，
    /// 不能靠关键词命中。
    private static func hasDeliverableShape(_ s: String) -> Bool {
        guard s.count >= 80 else { return false }   // 太短的一律当对话
        let markers = ["1. ", "1、", "步骤", "清单", "保存为", "文件名",
                       ".md", ".swift", ".py", ".json", ".sh", "—>", "->"]
        var hits = 0
        for mk in markers where s.contains(mk) { hits += 1 }
        // 至少要像"列了几条要做的事"或者"给了文件名"，才当产物
        return hits >= 2
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
        send()
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
