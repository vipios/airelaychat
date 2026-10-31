import Foundation

// MARK: - 数据模型

struct ModelInfo: Decodable, Identifiable {
    let id: String
    var object: String?
}

struct ModelList: Decodable {
    let data: [ModelInfo]
}

struct HealthInfo: Decodable {
    let status: String?
    let build: String?
    /// 公网 IPv6 列表（只在内网来源时返回）
    let addrs: [String]?
    /// 中转站自己的局域网 IPv4 列表（只在内网来源时返回）。
    ///
    /// 2026-10-31 新增，为了解决「路由器换网段 App 就连不上」这个老问题。
    /// 有了这个字段，App 只要在某一次连上时（哪怕走的是公网域名）读到它，
    /// 就等于**从中转站嘴里问到了它现在的内网地址**，直接存进地址池，
    /// 下次在家打开就能秒连，不用再靠猜网段。
    let lan: [String]?
}

/// Gist 里 relay-addr.json 的结构（路由器每 5 分钟自动写一次）
struct GistAddr: Decodable {
    let service: String?
    let updated: String?
    let ipv6: [String]?
    let port: Int?
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String        // user / assistant
    var text: String
    var failed: Bool = false
    var attachments: [Attachment] = []
    /// 用了哪个模型答的（助手消息上显示，方便对照）
    var model: String = ""
    /// 被用户撤回。
    ///
    /// 2026-10-31 用户要求：发出去的消息上面加撤回。
    /// 撤回后：
    ///   1. 这条消息**不参与**下一次请求的历史（等于没说过）
    ///   2. 界面上灰显划掉，不直接消失（用户要看得见自己撤了什么）
    var recalled: Bool = false
}

// MARK: - 错误

enum RelayError: LocalizedError {
    case noEndpoint
    case http(Int, String)
    case empty
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            return "连不上。在家请确认连着家里 WiFi；在外面请确认手机有 IPv6 网络。"
        case .http(let code, let msg):
            let brief = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 401 { return "密钥不对或没填，去「设置」里填一下。" }
            if code == 404 { return "接口地址不对，检查「设置」里的服务器地址。" }
            if brief.isEmpty { return "上游返回 HTTP \(code)" }
            return "HTTP \(code)：\(brief.prefix(160))"
        case .empty:
            return "上游没有返回内容，请重试。"
        case .notConfigured:
            return "这个供应商还没配置好，去「我的 → 模型来源」里填服务器地址和密钥。"
        }
    }
}

// MARK: - 底层请求（文件级函数，并发探测时不用捕获 self）

private func httpGet(_ urlString: String, timeout: TimeInterval,
                     session: URLSession) async throws -> (Int, Data) {
    guard let url = URL(string: urlString) else { throw RelayError.noEndpoint }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (code, data)
}

/// 服务活着吗？只认 status == "ok"，避免把别的网页当成中转站
private func probeHealth(_ base: String, timeout: TimeInterval,
                         session: URLSession) async -> HealthInfo? {
    do {
        let (code, data) = try await httpGet(base + "/health", timeout: timeout, session: session)
        guard code == 200,
              let h = try? JSONDecoder().decode(HealthInfo.self, from: data),
              h.status == "ok" else { return nil }
        return h
    } catch {
        return nil
    }
}

/// 并发探测的两种结果：家里内网命中 / 公网命中。
/// 定义成文件级类型而不是函数内嵌套，为了能安全地跨 TaskGroup 传递。
private enum ProbeHit {
    case lan(String, HealthInfo)
    case pub(String)
}

/// 并发探一批地址，返回第一个通的。
///
/// 为什么要并发：串行时每个不通的地址都要等满自己的超时（内网 2 秒、公网 4 秒），
/// 在外冷启动最坏要等 2+2+2+4+4 ≈ 14 秒才有结果，用户会以为卡死。
/// 并发后总耗时约等于一个超时周期。
private func firstAlive(_ bases: [String], timeout: TimeInterval,
                        session: URLSession) async -> (index: Int, base: String, health: HealthInfo)? {
    guard !bases.isEmpty else { return nil }
    if bases.count == 1 {
        if let h = await probeHealth(bases[0], timeout: timeout, session: session) {
            return (0, bases[0], h)
        }
        return nil
    }
    return await withTaskGroup(of: (Int, String, HealthInfo)?.self) { group in
        for (i, b) in bases.enumerated() {
            group.addTask {
                if let h = await probeHealth(b, timeout: timeout, session: session) {
                    return (i, b, h)
                }
                return nil
            }
        }
        var hit: (Int, String, HealthInfo)?
        for await r in group {
            if let r = r { hit = r; break }
        }
        group.cancelAll()
        return hit
    }
}

// MARK: - 中转站客户端

final class RelayClient {
    static let shared = RelayClient()

    private let settings = Settings.shared

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// 专门给内网探测用的会话：超时短、不走缓存。
    /// 单独一个的好处是 request 级 timeoutInterval 不会被连接复用后的行为影响，
    /// 探测结果更接近真实耗时。
    private let lanSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.0
        c.timeoutIntervalForResource = 1.5
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldUsePipelining = true
        return URLSession(configuration: c)
    }()

    private func get(_ urlString: String, timeout: TimeInterval = 3) async throws -> (Int, Data) {
        try await httpGet(urlString, timeout: timeout, session: session)
    }

    // MARK: - 在家判定（探测内网，不需要任何权限）

    /// 内网通了 = 在家。比读 WiFi 名字可靠得多，也不需要定位权限。
    /// 按多个候选地址并发试：不同 WiFi 下手机拿到的网段不同，只试一个会误判成"在外"。
    ///
    /// 超时压到 0.9 秒：同一网段的路由器 20~50 毫秒就回，0.9 秒还不回来
    /// 基本可以断定不在这个网段，继续等只是浪费用户时间。
    func probeLAN() async -> (base: String, health: HealthInfo)? {
        let hosts = await MainActor.run { settings.lanCandidates }
        let port = await MainActor.run { settings.port }
        let bases = hosts.map { "http://\($0):\(port)" }
        guard let hit = await firstAlive(bases, timeout: 0.9, session: lanSession) else { return nil }
        let host = hosts[hit.index]

        // 记住这次能通的地址，并且在池子里把它提到最前面 —— 下次优先试它。
        // 2026-10-31：同时把中转站自己上报的内网地址也一并学进来，
        // 这样换网段后 App 不需要靠猜也能知道设备在哪。
        let reported = hit.health.lan ?? []
        await MainActor.run {
            settings.learnLan(host)
            for h in reported { settings.learnLan(h) }
            if settings.lastLanBase != hit.base { settings.lastLanBase = hit.base }
        }
        return (hit.base, hit.health)
    }

    // MARK: - 预热

    /// 提前把公网域名的连接热起来（DNS 解析 + TCP + TLS + Cloudflare 隧道）。
    ///
    /// 实测数据：域名冷启动第一次 4.3 秒，紧接着第二次 2.7 秒 —— 差的这 1.6 秒
    /// 全是握手开销。App 一启动就在后台打这一枪，等用户真正敲完字发消息时，
    /// 连接已经热的，首字能明显快一截。
    ///
    /// 打失败完全无所谓：这里只是热身，不写任何状态、不影响任何判定逻辑。
    /// 用 detached + utility 优先级，不跟界面抢资源。
    func prewarm() {
        let s = session
        Task.detached(priority: .utility) {
            let base: String? = await MainActor.run { Settings.shared.domainBase }
            guard let base = base else { return }
            _ = await probeHealth(base, timeout: 9.0, session: s)
        }
    }

    // MARK: - 全段扫描（最后的兜底）

    /// 扫描手机当前 /24 网段的全部 254 个地址，找出中转站在哪。
    ///
    /// 2026-10-31 用户要求：「让我在外面无忧无虑地用，彻底解决连不上的问题」。
    ///
    /// 前两层（地址池 + 网段推导）都是"猜"，路由器只要落到从没见过的地址上
    /// 就猜不中。这一层不猜 —— 直接把整个网段扫一遍，一定能找到。
    ///
    /// 为什么成本可以接受：
    ///   - 只看当前 /24，一共 254 个地址，不是整个内网
    ///   - 单个超时 0.35 秒（同网段设备实测 20~50ms 就回，0.35 秒绰绰有余）
    ///   - 每批 64 个并发（iOS 对单机并发连接有上限，64 是安全值）
    ///   - 找到第一个立刻返回，后续全部取消
    /// 最坏情况（网段里真没有）约 254/64 × 0.35 ≈ 1.4 秒。
    ///
    /// 而且它只在「地址池和推导地址全都失败」之后才跑，正常在家时永远不会触发。
    func scanSubnet() async -> (base: String, health: HealthInfo)? {
        guard let myIP = NetInfo.wifiIPv4() else { return nil }
        let parts = myIP.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let seg = "\(parts[0]).\(parts[1]).\(parts[2])"

        let port = await MainActor.run { settings.port }
        // 已经试过的地址不重复扫（省掉几十个必然失败的目标）
        let known = await MainActor.run { Set(settings.lanCandidates) }

        var bases: [String] = []
        for i in 1...254 {
            let h = "\(seg).\(i)"
            if h == myIP || known.contains(h) { continue }
            bases.append("http://\(h):\(port)")
        }
        guard !bases.isEmpty else { return nil }

        let s = lanSession
        var i = 0
        while i < bases.count {
            let end = min(i + 64, bases.count)
            let chunk = Array(bases[i..<end])
            if let hit = await firstAlive(chunk, timeout: 0.35, session: s) {
                let host = URL(string: hit.base)?.host ?? ""
                await MainActor.run {
                    if !host.isEmpty { settings.learnLan(host) }
                    for h in (hit.health.lan ?? []) { settings.learnLan(h) }
                    if settings.lastLanBase != hit.base { settings.lastLanBase = hit.base }
                }
                return (hit.base, hit.health)
            }
            i = end
        }
        return nil
    }

    /// 最后的兜底：ZeroTier 固定地址 +（连着 WiFi 时）整个网段扫描。
    ///
    /// 走到这里说明域名、裸 IPv6、缓存地址、网段推导**全都失败了**。
    /// 这两条路是最后的希望：
    ///   - **ZeroTier** `10.47.67.100:8080`：手机装了 ZeroTier 客户端并加入
    ///     家里那个网络就能用。实测 DIRECT 59ms，比域名快一个数量级，
    ///     而且完全不依赖 Cloudflare 隧道是否活着。
    ///   - **全段扫描**：连着 WiFi 但网段陌生时，把 254 个地址扫一遍找设备。
    ///
    /// 两者并发，谁先通用谁。只有这样，才能说「不管什么情况都能连上」——
    /// 域名挂了还有 ZeroTier，ZeroTier 没装还有内网扫描，内网换了网段也能扫出来。
    private func lastResort() async -> (base: String, place: NetPlace)? {
        let port = await MainActor.run { settings.port }
        let zt = "http://10.47.67.100:\(port)"
        let onWiFi = NetInfo.hasUsableWiFi()
        let s = session

        // 元素用 (地址, 是不是内网) 而不是带 NetPlace 的元组：
        // 基础类型在并发闭包之间传递更安全，不会被 Sendable 检查挑刺。
        let hit = await withTaskGroup(of: (String, Bool)?.self) { group -> (String, Bool)? in
            group.addTask {
                // 没装 ZeroTier 时这里会超时，但因为和扫描是并发的，不额外拖时间
                await probeHealth(zt, timeout: 4.0, session: s) != nil ? (zt, false) : nil
            }
            if onWiFi {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    if let r = await self.scanSubnet() { return (r.base, true) }
                    return nil
                }
            }
            var first: (String, Bool)?
            for await r in group {
                if let r = r { first = r; break }
            }
            group.cancelAll()
            return first
        }

        guard let h = hit else { return nil }
        if h.1 {
            return (h.0, .home)
        }
        await MainActor.run {
            if settings.lastPubBase != h.0 { settings.lastPubBase = h.0 }
        }
        return (h.0, .away)
    }

    // MARK: - 在外判定（先试域名，再试缓存 IPv6）
    /// 探测固定域名（Cloudflare 隧道）。
    ///
    /// 单独一个方法而不是塞进 probePublic(addrs:)：那条走的是
    /// `http://[IPv6]:8080`，这条走 `https://域名`（443 + 证书），
    /// 拼装规则完全不同。
    ///
    /// 超时给 8 秒：隧道是设备主动外连、经 Cloudflare 边缘中转，
    /// 首次握手实测 1~3 秒，8 秒足够；比内网的 0.9 秒宽，但比不带域名的
    /// IPv6 直连（4 秒×N 个地址串行）总耗时短得多。
    func probeDomain() async -> (base: String, health: HealthInfo)? {
        let base = await MainActor.run { settings.domainBase }
        guard let base = base else { return nil }
        if let h = await probeHealth(base, timeout: 8.0, session: session) {
            await MainActor.run {
                if settings.lastPubBase != base { settings.lastPubBase = base }
                // 2026-10-31：如果中转站上报了自己的内网地址，就学进来。
                // 这意味着「在外面用流量走域名连过一次，回家就能直接命中内网」，
                // 不需要再猜网段。
                for ip in (h.lan ?? []) { settings.learnLan(ip) }
            }
            return (base, h)
        }
        return nil
    }

    func probePublic(addrs: [String]) async -> String? {
        let port = await MainActor.run { settings.port }
        let bases = addrs.map { "http://[\($0)]:\(port)" }
        guard let hit = await firstAlive(bases, timeout: 4.0, session: session) else { return nil }
        await MainActor.run {
            if settings.lastPubBase != hit.base { settings.lastPubBase = hit.base }
        }
        return hit.base
    }

    // MARK: - 连接灯心跳

    /// 单独探一次「现在这个地址还活着吗」。
    ///
    /// 和 bootstrap 的区别：这里只打一次 /health、超时很短、不改任何状态，
    /// 纯粹给顶栏/输入栏那颗小灯用。返回 true = 通。
    ///
    /// 超时给 4 秒而不是 1 秒：走 Cloudflare 隧道时首包可能要 1~3 秒，
    /// 用 1 秒会把「其实通着、只是慢」误判成红灯，灯一闪一闪的更烦人。
    func ping(base: String) async -> Bool {
        await probeHealth(base, timeout: 4.0, session: session) != nil
    }

    // MARK: - 冷启动秒连（用上次成功的地址，不先探测）

    /// 用户原话：「打开能直接对话」。要做到这一点，打开 App 的第一秒就必须有一个
    /// 能用的 base，而探测（内网候选 × 0.9 秒、域名 × 8 秒）本身就要时间。
    ///
    /// 做法：把上次成功的 base 直接拿来用，同时后台悄悄校验一次。
    /// 校验失败就把缓存丢掉、退回正常探测流程，用户最多看到一次"重试"，不会有长时间空白。
    ///
    /// 为什么两条缓存分开存：在家用 `http://192.168.1.88:8080`，
    /// 在外用 `https://域名`，二者不能互相替代。合并成一个的话，
    /// 出门第一次打开会先拿内网地址去撞墙，反而更慢。
    /// 用上次成功的地址快速验证一次。
    ///
    /// ⚠️ 2026-10-31 重写（这是「连不上」的核心 bug）：
    ///
    /// 原实现有两个致命问题：
    ///   1. **串行**：先探内网 0.8 秒，失败了再探公网 2.5 秒，最坏 3.3 秒才出结果；
    ///   2. **公网超时给太短**：域名走 Cloudflare 隧道，实测首包 2.7~4.3 秒，
    ///      而这里只等 2.5 秒 —— 等于**每次都必然判失败**，然后清空缓存、
    ///      退回去做全套探测，再等一轮。用户看到的就是「一直连不上」。
    ///
    /// 现在：两路并发、公网按域名/裸 IP 分别给 8 秒 / 4 秒、失败也不清缓存
    /// （并发下坏缓存等于零成本，好缓存价值极大，清掉只会让下次更慢）。
    private func cachedCandidate() async -> (place: NetPlace, base: String)? {
        let lan = await MainActor.run { settings.lastLanBase }
        let pub = await MainActor.run { settings.lastPubBase }

        // 内网缓存只在手机确实连着 WiFi 时才试：没连 WiFi 还拿内网地址去连，
        // 必定超时，纯粹浪费用户时间。
        let onWiFi = NetInfo.hasUsableWiFi()
        let tryLan = onWiFi && !lan.isEmpty
        let tryPub = !pub.isEmpty
        guard tryLan || tryPub else { return nil }

        // 先取到局部常量再进 TaskGroup：闭包不捕获 self，避免并发告警
        let lanS = lanSession
        let pubS = session

        let hit = await withTaskGroup(of: (Int, String)?.self) { group -> (Int, String)? in
            if tryLan {
                group.addTask {
                    await probeHealth(lan, timeout: 0.9, session: lanS) != nil ? (0, lan) : nil
                }
            }
            if tryPub {
                group.addTask {
                    // 域名（https）给 8 秒：隧道冷启动实测 2.7~4.3 秒，
                    // 给 4 秒都不够稳。裸 IPv6 直连给 4 秒。
                    let t: TimeInterval = pub.hasPrefix("https://") ? 8.0 : 4.0
                    await probeHealth(pub, timeout: t, session: pubS) != nil ? (1, pub) : nil
                }
            }
            var lanHit: (Int, String)?
            var pubHit: (Int, String)?
            for await r in group {
                guard let r = r else { continue }
                // 内网通了就立刻收工（它比域名快一个数量级）
                if r.0 == 0 { lanHit = r; break }
                // 公网先到也先记着，继续等内网那一秒
                if pubHit == nil { pubHit = r }
            }
            group.cancelAll()
            return lanHit ?? pubHit
        }

        guard let h = hit else { return nil }
        if h.0 == 0 {
            // 顺手把这个地址学进池子，并同步到设置页显示
            if let host = URL(string: h.1)?.host, !host.isEmpty {
                await MainActor.run { settings.learnLan(host) }
            }
            return (.home, h.1)
        }
        return (.away, h.1)
    }

    // MARK: - Gist 读地址（三路降级）

    /// GitHub raw 直连不通时用公共加速站兜底。
    private func gistURLs() async -> [String] {
        let owner = await MainActor.run { settings.gistOwner }
        let gid = await MainActor.run { settings.gistId }
        guard !gid.isEmpty else { return [] }
        let raw = "https://gist.githubusercontent.com/\(owner)/\(gid)/raw/relay-addr.json"
        return [
            raw,
            "https://gh-proxy.com/" + raw,
            "https://ghfast.top/" + raw
        ]
    }

    /// 从 Gist 拿路由器最新公网地址。只在「缓存地址连不上」时才走，
    /// 所以平时不会给对话增加任何延迟。三路也是并发：直连通常 0.6 秒就回来。
    func fetchGistAddr() async -> GistAddr? {
        let urls = await gistURLs()
        guard !urls.isEmpty else { return nil }

        func tryOne(_ u: String) async -> GistAddr? {
            do {
                let (code, data) = try await get(u, timeout: 5)
                guard code == 200,
                      let g = try? JSONDecoder().decode(GistAddr.self, from: data),
                      let ips = g.ipv6, !ips.isEmpty else { return nil }
                return g
            } catch {
                return nil
            }
        }

        if urls.count == 1 { return await tryOne(urls[0]) }

        return await withTaskGroup(of: GistAddr?.self) { group in
            for u in urls {
                group.addTask { await tryOne(u) }
            }
            var hit: GistAddr?
            for await r in group {
                if let r = r { hit = r; break }
            }
            group.cancelAll()
            return hit
        }
    }

    // MARK: - 核心：判定场景并给出家里的地址

    /// 返回 (场景, 可用 base, health)。会顺带更新缓存的公网地址。
    /// 注意：settings 的 @Published 属性只能在主线程改，否则 SwiftUI 会
    /// 报 "Publishing changes from background threads"，界面还可能不刷新。
    ///
    /// 设计要点（2026-10-29 重构）：
    /// 用户的原话是「连 WiFi 就是在家里，没连 WiFi 就是外面」。
    /// 所以第一判断不用"能不能连通"（那要等超时），而是"手机有没有拿 WiFi IP"——
    /// 这个从网卡直接读，零权限、零延迟、不会猜错。
    ///
    /// 有 WiFi 时也不再去猜家里是哪个地址：内网候选和 Gist 地址同时并发探，
    /// 谁先回来用谁。这样「连了别的 WiFi（比如公司）」也能自动落到公网地址，
    /// 不会傻等内网超时。
    func resolve() async -> (place: NetPlace, base: String?, health: HealthInfo?) {
        // 第一步：上次成功的地址（在家内网 / 在外域名）直接验证一下。
        // 通畅就立刻返回，跳过下面所有探测 —— 这是「打开就能直接对话」的关键。
        if let c = await cachedCandidate() {
            return (c.place, c.base, nil)
        }

        let onWiFi = NetInfo.hasUsableWiFi()

        if onWiFi {
            // 在家/在别的 WiFi：内网候选 + 公网地址 并行探，谁通用谁。
            // 用 TaskGroup 而不是 async let：内网先回来时能显式中断另一路，
            // 也不会因为 return 提前离开作用域产生"未 await"的警告。
            let hit = await withTaskGroup(of: ProbeHit?.self) { group -> ProbeHit? in
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    if let l = await self.probeLAN() { return .lan(l.base, l.health) }
                    return nil
                }
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    if let p = await self.publicCandidate() { return .pub(p) }
                    return nil
                }
                var lanHit: ProbeHit?
                var pubHit: ProbeHit?
                for await r in group {
                    guard let r = r else { continue }
                    if case .lan = r { lanHit = r; group.cancelAll(); break }
                    if case .pub = r, pubHit == nil { pubHit = r }
                    // 内网结果还没来之前，公网先到了也先记着，不立刻中断：
                    // 连 WiFi 时优先内网（更快更稳），但万一内网全不通还能兜底。
                }
                return lanHit ?? pubHit
            }

            switch hit {
            case .lan(let base, let health):
                if let addrs = health.addrs, !addrs.isEmpty {
                    await MainActor.run { settings.publicAddrs = addrs }
                }
                // 顺手把中转站上报的内网地址学进池子（换网段后靠它秒连）
                if let lans = health.lan, !lans.isEmpty {
                    await MainActor.run { for h in lans { settings.learnLan(h) } }
                }
                return (.home, base, health)
            case .pub(let pub):
                return (.away, pub, nil)
            case .none:
                // 上面两条路都不通 —— 进最后的兜底。
                // 走到这里说明地址池和网段推导都没命中（典型场景：路由器换到了
                // 一个从没见过的网段），ZeroTier 和全段扫描是唯一剩下的办法。
                // 只要命中，地址就进了池子，下次打开直接秒连。
                if let r = await lastResort() {
                    return (r.place, r.base, nil)
                }
                return (.unknown, nil, nil)
            }
        }

        // 没连 WiFi（流量）：直接走公网，一步到位
        if let pub = await publicCandidate() {
            return (.away, pub, nil)
        }
        // 域名和裸 IPv6 都不行 —— 试 ZeroTier。
        // 这是「在外面」的最后一道保险：域名要依赖 Cloudflare 隧道活着，
        // ZeroTier 不需要，只要手机装了客户端并加入网络就能直连。
        if let r = await lastResort() {
            return (r.place, r.base, nil)
        }
        return (.unknown, nil, nil)
    }

    /// 公网地址候选：域名和裸 IPv6 同时并发试，谁先回来用谁。
    ///
    /// 2026-10-31 变更：家用公网的 IPv6 入站已被按用户要求全部封堵
    /// （实测 `[2409:...]:8080` → ConnectionRefused），裸 IPv6 这条路
    /// 只作为「万一将来重新放开」的兜底，不再当成主路径。
    /// 所以顺序改成：域名优先、并发打 IPv6 只当备份，且**不再因为 IPv6
    /// 失败就去拉 Gist**——那会白白多花几秒。
    private func publicCandidate() async -> String? {
        let cached = await MainActor.run { settings.publicAddrs }
        let hasDomain = await MainActor.run { !settings.publicDomain.isEmpty }

        if !hasDomain && cached.isEmpty { return nil }

        let hit = await withTaskGroup(of: String?.self) { group -> String? in
            if hasDomain {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    return await self.probeDomain()?.base
                }
            }
            if !cached.isEmpty {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    return await self.probePublic(addrs: cached)
                }
            }
            var first: String?
            for await r in group {
                if let r = r { first = r; break }
            }
            group.cancelAll()
            return first
        }
        if let hit = hit { return hit }

        // 只有「完全没配域名」时才去问 Gist 兜底。
        // 配了域名还去拉 Gist，等于每次外网失败都多等一次网络请求。
        guard !hasDomain else { return nil }

        if let g = await fetchGistAddr(), let ips = g.ipv6, !ips.isEmpty {
            let newPort = (g.port ?? 0) > 0 ? g.port! : 0
            await MainActor.run {
                settings.publicAddrs = ips
                if newPort > 0 { settings.port = newPort }
            }
            return await probePublic(addrs: ips)
        }
        return nil
    }

    /// 解析某个来源实际要用的 base。
    /// 家里的走自动探测（内网优先，公网兜底）；别家来源直接用填的地址。
    func base(for p: Provider) async -> (base: String?, place: NetPlace) {
        if p.isHome {
            let r = await resolve()
            return (r.base, r.place)
        }
        var b = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return (nil, .unknown) }
        // 允许用户只填 example.com 或 example.com/v1，统一补成完整 base
        if !b.lowercased().hasPrefix("http://"), !b.lowercased().hasPrefix("https://") {
            b = "https://" + b
        }
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return (b, .away)
    }

    // MARK: - 模型列表

    func models(base: String, key: String) async throws -> [ModelInfo] {
        guard let url = URL(string: base + "/v1/models") else { throw RelayError.noEndpoint }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ModelList.self, from: data).data
    }

    // MARK: - 流式对话（真流式：逐字出现）

    /// 用 bytes 逐行读 SSE，边收边显示。
    /// attachments 里的图片/视频会以多模态 content 发出。
    func stream(base: String, key: String, model: String,
                messages: [(role: String, text: String, attachments: [Attachment])],
                onDelta: @escaping (String) -> Void) async throws {

        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw RelayError.noEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let msgs: [[String: Any]] = messages.map { m in
            ["role": m.role,
             "content": PayloadBuilder.content(text: m.text, attachments: m.attachments)]
        }
        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": msgs
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayError.empty }
        guard http.statusCode == 200 else {
            var buf = Data()
            for try await b in bytes {
                buf.append(b)
                if buf.count > 4096 { break }
            }
            throw RelayError.http(http.statusCode, String(data: buf, encoding: .utf8) ?? "")
        }

        var got = false
        var sawSSE = false
        var collected = ""

        for try await line in bytes.lines {
            // 2026-10-31 用户要求「撤回后 AI 不再请求响应」：
            // 撤回时 ChatStore 会 cancel 掉发送 Task，这里每读一行检查一次，
            // 一旦被取消就立刻停止读流、断开连接（URLSession 的 bytes 流在
            // Task 取消后会抛 CancellationError，这里提前 return 更干脆）。
            if Task.isCancelled { throw CancellationError() }
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("data:") else { continue }
            sawSSE = true
            let body = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if body == "[DONE]" { break }
            guard let d = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]] else { continue }
            if let delta = choices.first?["delta"] as? [String: Any],
               let c = delta["content"] as? String, !c.isEmpty {
                got = true
                collected += c
                onDelta(c)
            } else if let msg = choices.first?["message"] as? [String: Any],
                      let c = msg["content"] as? String, !c.isEmpty {
                got = true
                collected += c
                onDelta(c)
            }
        }

        // 上游忽略 stream、或流里没拿到内容时，用非流式补一次，保证不出现空白回答
        if !sawSSE || !got {
            let text = try await nonStream(base: base, key: key, model: model, messages: messages)
            if !text.isEmpty {
                onDelta(text)
            } else if collected.isEmpty {
                throw RelayError.empty
            }
        }
    }

    /// 非流式兜底（上游不认 stream、或流式失败时用）
    func nonStream(base: String, key: String, model: String,
                   messages: [(role: String, text: String, attachments: [Attachment])]) async throws -> String {
        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw RelayError.noEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let msgs: [[String: Any]] = messages.map { m in
            ["role": m.role,
             "content": PayloadBuilder.content(text: m.text, attachments: m.attachments)]
        }
        let payload: [String: Any] = ["model": model, "messages": msgs]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = doc["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return "" }

        // content 可能是字符串，也可能是多模态数组
        if let c = msg["content"] as? String { return c }
        if let arr = msg["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    // MARK: - 设备状态 / 一键重启

    /// 设备状态快照：开机多久、还剩多少内存、该不该重启。
    ///
    /// 为什么不在客户端自己算「该不该重启」：
    /// 阈值（内存低于多少算紧张、load 超过多少算异常）属于运维策略，
    /// 放在服务端改了立刻生效，不用重新发版。
    func deviceStatus(base: String, key: String) async throws -> DeviceStatus {
        guard let url = URL(string: base + "/admin/api/device") else { throw RelayError.noEndpoint }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-Access-Key") }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, Self.humanError(code, data))
        }
        return try JSONDecoder().decode(DeviceStatus.self, from: data)
    }

    /// 一键重启路由器。
    ///
    /// 注意三点：
    /// 1. 服务端先回 200 再真的重启，所以这里拿到响应 ≠ 已经重启完，
    ///    只是「指令已受理」。界面要自己提示"约 40 秒后恢复"。
    /// 2. 超时给 12 秒：要在隧道握手上再叠一层重启前的 2 秒延迟。
    /// 3. confirm 字段是防手滑的二次确认，服务端缺了它会回 400。
    func rebootDevice(base: String, key: String) async throws {
        guard let url = URL(string: base + "/admin/api/device/reboot") else {
            throw RelayError.noEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-Access-Key") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["confirm": "reboot"])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, Self.humanError(code, data))
        }
    }

    /// 把服务端返回的错误 JSON 翻成人话。
    /// 直接抛 "HTTP 403" 用户看不懂，尤其是「后台只允许内网访问」这种。
    private static func humanError(_ code: Int, _ data: Data) -> String {
        if let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = doc["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        switch code {
        case 401: return "访问密钥不对，去设置里检查一下"
        case 403: return "这个地址不允许远程访问"
        case 429: return "操作太频繁，稍等一会再试"
        default: return "HTTP \(code)"
        }
    }
}

// MARK: - 设备状态

/// 服务端 /admin/api/device 的返回。
/// 字段和 relay.py 里的 admin_device() 一一对应，改那边记得同步这里。
struct DeviceStatus: Decodable {
    var uptime: Int = 0
    var uptimeText: String = ""
    var load: [Double] = []
    var memTotalKB: Int = 0
    var memAvailKB: Int = 0
    var swapTotalKB: Int = 0
    var swapUsedPct: Int = 0
    var relayRSSKB: Int = 0
    var shouldReboot: Bool = false

    enum CodingKeys: String, CodingKey {
        case uptime
        case uptimeText = "uptime_text"
        case load
        case memTotalKB = "mem_total_kb"
        case memAvailKB = "mem_avail_kb"
        case swapTotalKB = "swap_total_kb"
        case swapUsedPct = "swap_used_pct"
        case relayRSSKB = "relay_rss_kb"
        case shouldReboot = "should_reboot"
    }

    /// 「8.1 / 116 MB」这种一眼能看的格式
    var memText: String {
        guard memTotalKB > 0 else { return "-" }
        let avail = Double(memAvailKB) / 1024.0
        let total = Double(memTotalKB) / 1024.0
        return String(format: "%.1f / %.0f MB", avail, total)
    }

    var loadText: String {
        load.isEmpty ? "-" : load.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }
}
