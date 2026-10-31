import SwiftUI
import UIKit

// MARK: - 网络环境（在家 / 在外 / 未知）

enum NetPlace: String, Codable {
    case home = "在家"
    case away = "在外"
    case unknown = "未连接"

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .away: return "antenna.radiowaves.left.and.right"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - 模型能力

/// 模型能吃什么。中转站 /v1/models 不返回能力，只能按模型名推断，
/// 所以这里用「保守 + 可手动纠正」的策略：推断错了用户在设置里能改。
enum ModelCap: String, Codable {
    case text    // 纯文本
    case image   // 能看图
    case video   // 能看视频
    case media   // 图 + 视频
}

enum CapInfer {
    /// 明确的视觉模型关键字（命中即认为能看图）
    private static let visionWords = [
        "glm-4.6v", "glm-5v", "glm-4v", "4.6v", "5v-turbo", "-vl", "vl-",
        "vision", "gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4",
        "claude", "gemini", "pixtral", "llava", "qvq", "internvl",
        "step-1v", "step-5", "step-3", "doubao-1.5-vision", "seed-1.6",
        "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen3.8",
        "hunyuan-vision", "hunyuan-turbos", "hunyuan-2.0",
        "kimi-k2", "kimi-k3", "minimax-m", "mimo-v", "hy3", "hy4",
        "deepseek-v4", "deepseek-v3.2", "deepseek-v3.1", "deepseek-r1",
        "spark-x", "auto", "balanced", "deep-model", "fast-model",
        "default-1", "space-bunny",
    ]

    /// 明确不支持看图的（优先于上面的宽泛匹配）
    private static let noVisionWords = [
        "completion", "codewise", "rewrite", "-nes-", "embedding", "rerank",
        "tts", "whisper", "moderation", "dall-e", "seedream", "image-alpha",
        "image-edit", "kling-video", "minimax-video", "hy-image", "qwen-image",
        "wb-lite", "hunyuan-3b", "hunyuan-7b",
    ]

    /// 支持视频的（目前就这几个系列实测支持）
    private static let videoWords = ["glm-5.3-flash", "kimi-k2.6", "minimax-m3", "mimo-v2.5", "qwen3.8-flash"]

    static func infer(_ model: String) -> ModelCap {
        let m = model.lowercased()
        for w in noVisionWords where m.contains(w) { return .text }
        let isVideo = videoWords.contains { m.contains($0) }
        var isImage = false
        for w in visionWords where m.contains(w) { isImage = true; break }
        if isVideo && isImage { return .media }
        if isVideo { return .video }
        if isImage { return .image }
        return .text
    }
}

// MARK: - 模型条目

struct ModelItem: Identifiable, Hashable {
    let id: String          // 发给上游的模型名
    let providerId: String  // 属于哪个来源
    let display: String     // 界面上显示的名字
    var cap: ModelCap       // 能力（可在设置里覆盖）

    /// 「来源」和「模型」可能重名，列表里带上短标识区分
    var label: String { display }
}

// MARK: - 来源（家里的中转站，或任意 OpenAI 兼容站点）

struct Provider: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    /// 家里中转站走自动探测（内网/公网），别的来源填固定 base_url
    var isHome: Bool = false
    var baseURL: String = ""
    var apiKey: String = ""
    var enabled: Bool = true
    /// 用户手动指定的能力覆盖：模型名 -> 能力
    var capOverrides: [String: ModelCap] = [:]
    /// 这个来源上次拉到的模型名
    var models: [String] = []

    var isConfigured: Bool {
        if isHome { return true }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 持久化配置

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var lanHost: String { didSet { store() } }
    /// 固定域名（Cloudflare 隧道）。这条路径不依赖 IPv6 前缀、不需要端口、
    /// 不受运营商 CGNAT 影响，是「在外面」最稳的一条路，所以排在最前面试。
    @Published var publicDomain: String { didSet { store() } }
    @Published var publicAddrs: [String] { didSet { store() } }
    /// 上次「在家」成功用过的内网地址（含端口），冷启动时直接拿来用，不等探测。
    @Published var lastLanBase: String { didSet { store() } }
    /// 历史连通过的内网 IP 池（最近成功的排前面，最多 8 个）。
    ///
    /// 2026-10-31 用户要求「在外面无忧无虑地用，彻底解决连不上的问题」。
    /// 原来只记一个 `lanHost`，路由器一换网段（192.168.2.x → 192.168.1.x）
    /// 那个地址就永久失效，App 只能靠"猜常见尾巴"，猜不到就彻底连不上。
    /// 现在改成记一池：每次真正连通都把地址学进来，换网段后旧地址失效，
    /// 新地址还能从池子里命中，不必重新猜。
    @Published var lanPool: [String] { didSet { store() } }
    /// 上次「在外」成功用过的公网地址（域名或裸 IPv6），同样用于冷启动秒连。
    @Published var lastPubBase: String { didSet { store() } }
    @Published var gatewayKey: String { didSet { store() } }
    @Published var homeModel: String { didSet { store() } }
    @Published var awayModel: String { didSet { store() } }
    @Published var port: Int { didSet { store() } }
    @Published var gistId: String { didSet { store() } }
    @Published var gistOwner: String { didSet { store() } }
    @Published var providers: [Provider] { didSet { store() } }
    /// 当前选中的来源（Provider.id）
    @Published var activeProvider: String { didSet { store() } }

    private let key = "airelay.settings.v2"
    private let oldKey = "airelay.settings.v1"

    private struct Stored: Codable {
        var lanHost: String
        var publicDomain: String?
        var publicAddrs: [String]
        var lastLanBase: String?
        var lastPubBase: String?
        /// 学到的内网地址池。
        ///
        /// ⚠️ 必须写成可选类型：这个字段是后加的，老版本存下来的 JSON 里没有它。
        /// 如果声明成非可选的 `[String]`，JSONDecoder 会因为缺 key 直接抛错，
        /// 导致**整个设置解码失败** —— 用户的 API Key、模型选择、来源配置全丢，
        /// App 会像刚装一样要重新配一遍。可选类型缺 key 时自动变 nil，旧数据安全。
        var lanPool: [String]?
        var gatewayKey: String
        var homeModel: String
        var awayModel: String
        var port: Int
        var gistId: String
        var gistOwner: String?
        var providers: [Provider]?
        var activeProvider: String?
    }

    /// 旧版只有中转站一个来源，迁移成 Provider
    private struct StoredV1: Codable {
        var lanHost: String
        var publicAddrs: [String]
        var gatewayKey: String
        var homeModel: String
        var awayModel: String
        var port: Int
        var gistId: String
        var gistOwner: String?
    }

    private init() {
        let d = UserDefaults.standard.data(forKey: key)
        var s = d.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }

        // 从 v1 迁移（老用户不用重新填 key）
        if s == nil, let old = UserDefaults.standard.data(forKey: oldKey),
           let v1 = try? JSONDecoder().decode(StoredV1.self, from: old) {
            s = Stored(lanHost: v1.lanHost, publicDomain: nil, publicAddrs: v1.publicAddrs,
                       lastLanBase: nil, lastPubBase: nil, lanPool: nil,
                       gatewayKey: v1.gatewayKey, homeModel: v1.homeModel,
                       awayModel: v1.awayModel, port: v1.port, gistId: v1.gistId,
                       gistOwner: v1.gistOwner, providers: nil, activeProvider: nil)
        }

        // 默认值故意留空：第一次打开会按常见网段依次并发试，谁通用谁并记住。
        // 写死一个 IP 在不同 WiFi 下必然连不上。
        lanHost = s?.lanHost ?? ""
        // 默认值从 Info.plist 读（构建时注入），和 Gist 一样不在源码里写死域名。
        // 注意：老版本会把 publicDomain 存成空串，空串要当成"没配"，
        // 否则升级到带域名的新包之后，旧用户永远拿不到默认域名。
        let bundledDomain = Bundle.main.infoDictionary?["AIRelayPublicDomain"] as? String ?? ""
        let savedDomain = (s?.publicDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        publicDomain = savedDomain.isEmpty ? bundledDomain : savedDomain
        publicAddrs = s?.publicAddrs ?? []
        lastLanBase = s?.lastLanBase ?? ""
        lastPubBase = s?.lastPubBase ?? ""
        // 老数据没有这个字段（nil）：用上次成功的内网地址给它"种"一颗种子，
        // 这样升级上来的用户第一轮探测就有可用的历史地址，不用从零猜。
        if let pool = s?.lanPool, !pool.isEmpty {
            lanPool = pool
        } else if let seed = s?.lastLanBase, let h = URL(string: seed)?.host, !h.isEmpty {
            lanPool = [h]
        } else {
            lanPool = []
        }
        gatewayKey = s?.gatewayKey ?? ""
        homeModel = s?.homeModel ?? ""
        awayModel = s?.awayModel ?? ""
        port = s?.port ?? 8080
        // 默认值从 Info.plist 读，构建时注入。源码里不留真实 ID——
        // 否则仓库公开就等于把「家里地址上报渠道」公开了。
        gistId = s?.gistId ?? Bundle.main.infoDictionary?["AIRelayGistId"] as? String ?? ""
        gistOwner = s?.gistOwner ?? Bundle.main.infoDictionary?["AIRelayGistOwner"] as? String ?? ""

        var ps = s?.providers ?? []
        if ps.isEmpty {
            ps = [Provider(name: "家里中转站", isHome: true, baseURL: "", apiKey: "")]
        }
        providers = ps
        let active = s?.activeProvider ?? ""
        activeProvider = ps.contains(where: { $0.id == active }) ? active : (ps.first?.id ?? "")
    }

    private func store() {
        let s = Stored(lanHost: lanHost, publicDomain: publicDomain, publicAddrs: publicAddrs,
                       lastLanBase: lastLanBase, lastPubBase: lastPubBase,
                       lanPool: lanPool,
                       gatewayKey: gatewayKey,
                       homeModel: homeModel, awayModel: awayModel, port: port,
                       gistId: gistId, gistOwner: gistOwner,
                       providers: providers, activeProvider: activeProvider)
        if let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    // MARK: 内网探测

    /// 内网基地址（用户没填时给个兜底显示值）
    var lanBase: String { "http://\(lanHost.isEmpty ? "192.168.1.88" : lanHost):\(port)" }

    /// 在家判定要试的内网地址，按优先级排列。
    ///
    /// 顺序很重要（2026-10-29 修正）：
    /// 用户手动填的排最前（他填了就是他知道），其次是手机当前网段推导出来的，
    /// 最后才是历史已知地址。
    ///
    /// 曾经把 192.168.2.1 排在第一位，结果它是路由器 LAN 侧地址，
    /// 手机连光猫 WiFi 拿到的是 192.168.1.x，根本到不了 192.168.2.x，
    /// 每次冷启动都要在这个死地址上空等两秒 —— 这就是"未连接"的直接原因。
    var lanCandidates: [String] {
        var list: [String] = []
        func add(_ h: String) {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !list.contains(t) else { return }
            list.append(t)
        }

        // 1) 用户手动填的，最可信（他填了就是他知道）
        add(lanHost)

        // 2) 学到过的地址池：这些**真的连通过**，比任何猜测都可靠。
        //    路由器换网段时，旧地址会在这里被跳过，新学到的地址排最前面。
        for h in lanPool { add(h) }

        // 3) 手机当前 WiFi 网段推导（最能反映"现在这个 WiFi 是哪一段"）
        //
        //    2026-10-31 扩充：原来只试 88/250/1 三个尾巴，只覆盖了很小一部分路由器。
        //    现在补上家用设备常见的其它尾巴（2/254/100/10/8/18/3），
        //    并且这些都只是并发候选，多一个不增加总耗时（最坏也就等一个 0.9 秒）。
        if let myIP = NetInfo.wifiIPv4() {
            let parts = myIP.split(separator: ".")
            if parts.count == 4 {
                let seg = "\(parts[0]).\(parts[1]).\(parts[2])"
                for tail in ["88", "250", "1", "2", "254", "100", "10", "8", "18", "3"] {
                    add("\(seg).\(tail)")
                }
            }
        }

        // 4) 历史已知地址 + ZeroTier 固定地址兜底。
        //
        //    `10.47.67.100` 是路由器上 ZeroTier 的固定 IP：手机装了 ZeroTier 的话，
        //    在外面用流量也能走这条（实测 DIRECT 59ms，比域名快一个数量级）。
        //    没装的时候它会超时，但因为候选是并发探测的，不会拖慢别人。
        for h in ["192.168.1.88", "10.47.67.100", "192.168.1.250", "192.168.2.1"] {
            add(h)
        }
        return list
    }

    /// 记下一个「真的连通过」的内网地址。
    ///
    /// 调用时机：任何一次 /health 探测成功。学到的地址会一直带着，
    /// 下次换到同一个网段时直接命中，不用再从一堆猜测里挨个试。
    ///
    /// 只学 IPv4 字面量：`lanHost` 这个字段是被当作 `http://<host>:<port>`
    /// 拼接的，塞进去一个域名或 IPv6 会把地址拼坏。
    func learnLan(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.contains(":"), h.contains(".") else { return }
        // 回环 / 自分配地址没有任何意义，别污染池子
        guard !h.hasPrefix("127."), !h.hasPrefix("169.254.") else { return }

        var next = lanPool.filter { $0 != h }
        next.insert(h, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        if next != lanPool { lanPool = next }
        if lanHost != h { lanHost = h }
    }

    // MARK: 来源

    /// 启动瞬间能直接用的 base（上次成功的地址），没缓存就返回 nil。
    ///
    /// 只挑一个：连着 WiFi 优先内网（快），否则用公网。
    /// 这里不做任何校验——校验交给 bootstrap，那个是异步的，
    /// 校验期间界面已经能显示地址、能点发送了。
    var cachedBaseForLaunch: (base: String, place: NetPlace)? {
        // 不在主线程之外调 NetInfo：getifaddrs 是系统调用，放后台线程读没问题，
        // 但 ChatStore.init 本身就是主线程，这里保持同步、不做 await 最稳。
        let onWiFi = NetInfo.hasUsableWiFi()
        if onWiFi, !lastLanBase.isEmpty {
            return (lastLanBase, .home)
        }
        if !lastPubBase.isEmpty {
            return (lastPubBase, .away)
        }
        // 没 WiFi 也没有公网缓存时，内网地址也只是个念想，交给 bootstrap 去探测更好
        return nil
    }

    /// 固定域名基地址（没有配置就返回 nil）。
    ///
    /// 为什么单列一条而不是塞进 publicAddrs：publicAddrs 里存的是裸 IPv6，
    /// 拼装方式是 `http://[ip]:port`；域名走的是 `https://域`（443、带证书）。
    /// 两者协议、端口、证书校验都不同，混在一个数组里会互相污染。
    var domainBase: String? {
        let d = publicDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        // 用户可能连 https:// 一起粘进来，剥掉再统一拼
        var host = d
        for p in ["https://", "http://"] where host.lowercased().hasPrefix(p) {
            host = String(host.dropFirst(p.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host.isEmpty ? nil : "https://" + host
    }

    var homeProvider: Provider? { providers.first(where: { $0.isHome }) }

    var currentProvider: Provider? {
        providers.first(where: { $0.id == activeProvider && $0.enabled })
            ?? providers.first(where: { $0.enabled })
    }

    func provider(_ id: String) -> Provider? { providers.first(where: { $0.id == id }) }

    /// 整体替换一个来源（改名、改地址都走这里）。
    /// 用整条替换而不是逐字段赋值，是为了让 didSet 一定能触发落盘。
    func updateProvider(_ p: Provider) {
        guard let i = providers.firstIndex(where: { $0.id == p.id }) else { return }
        var next = providers
        next[i] = p
        providers = next
    }

    /// 删除来源。不许删掉最后一个，否则 App 会变成没有任何来源的砖。
    @discardableResult
    func removeProvider(_ id: String) -> Bool {
        guard providers.count > 1 else { return false }
        var next = providers.filter { $0.id != id }
        if next.isEmpty { return false }
        providers = next
        if activeProvider == id { activeProvider = next.first?.id ?? "" }
        return true
    }

    func addProvider(_ p: Provider) {
        providers.append(p)
    }

    /// 中转站的密钥：优先用 Provider 自己的，没填才回落到全局 gatewayKey
    func key(for p: Provider) -> String {
        let k = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { return k }
        return p.isHome ? gatewayKey : ""
    }

    /// 调用**管理接口**（/admin/api/*）用的密钥。
    ///
    /// 注意这跟 `key(for:)` 不是一回事：
    ///   - 模型接口 (/v1/*) 认 access_key 或任一网关 Key
    ///   - 管理接口 (/admin/api/*) **只认 access_key**
    /// 所以不能用网关 Key 去调重启，权限对不上会 401。
    /// 这里和后台网页共用同一个钥匙串项，用户只需在首次进后台时输过一次。
    var accessKey: String {
        let k = AdminKey.load().trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { return k }
        // 兜底：有些用户只在设置里填过「访问密钥」，从没开过后台。
        // 中转站的 access_key 和这个字段是同一样东西，直接用。
        return gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cap(for model: String, in p: Provider) -> ModelCap {
        if let o = p.capOverrides[model] { return o }
        return CapInfer.infer(model)
    }
}
