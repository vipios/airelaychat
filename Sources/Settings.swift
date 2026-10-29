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
    @Published var publicAddrs: [String] { didSet { store() } }
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
        var publicAddrs: [String]
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
            s = Stored(lanHost: v1.lanHost, publicAddrs: v1.publicAddrs,
                       gatewayKey: v1.gatewayKey, homeModel: v1.homeModel,
                       awayModel: v1.awayModel, port: v1.port, gistId: v1.gistId,
                       gistOwner: v1.gistOwner, providers: nil, activeProvider: nil)
        }

        // 默认值故意留空：第一次打开会按常见网段依次并发试，谁通用谁并记住。
        // 写死一个 IP 在不同 WiFi 下必然连不上。
        lanHost = s?.lanHost ?? ""
        publicAddrs = s?.publicAddrs ?? []
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
        let s = Stored(lanHost: lanHost, publicAddrs: publicAddrs, gatewayKey: gatewayKey,
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

        // 1) 用户手动填的，最可信
        if !lanHost.isEmpty { list.append(lanHost) }

        // 2) 手机当前 WiFi 网段推导（最能反映"现在这个 WiFi 是哪一段"）
        //    家用路由器管理地址绝大多数落在这几个尾巴上
        if let myIP = NetInfo.wifiIPv4() {
            let parts = myIP.split(separator: ".")
            if parts.count == 4 {
                let seg = "\(parts[0]).\(parts[1]).\(parts[2])"
                for tail in ["88", "250", "1"] {
                    let h = "\(seg).\(tail)"
                    if !list.contains(h) { list.append(h) }
                }
            }
        }

        // 3) 历史已知地址兜底（手机没拿到 WiFi IP 时才会用到）
        for h in ["192.168.1.88", "192.168.1.250", "192.168.2.1"] where !list.contains(h) {
            list.append(h)
        }
        return list
    }

    // MARK: 来源

    var homeProvider: Provider? { providers.first(where: { $0.isHome }) }

    var currentProvider: Provider? {
        providers.first(where: { $0.id == activeProvider && $0.enabled })
            ?? providers.first(where: { $0.enabled })
    }

    func provider(_ id: String) -> Provider? { providers.first(where: { $0.id == id }) }

    /// 中转站的密钥：优先用 Provider 自己的，没填才回落到全局 gatewayKey
    func key(for p: Provider) -> String {
        let k = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { return k }
        return p.isHome ? gatewayKey : ""
    }

    func cap(for model: String, in p: Provider) -> ModelCap {
        if let o = p.capOverrides[model] { return o }
        return CapInfer.infer(model)
    }
}
