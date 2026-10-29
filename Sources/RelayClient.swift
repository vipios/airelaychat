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
    let addrs: [String]?
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
            return "这个来源还没配置好，去「设置 → 模型来源」里填服务器地址和密钥。"
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

    private func get(_ urlString: String, timeout: TimeInterval = 3) async throws -> (Int, Data) {
        try await httpGet(urlString, timeout: timeout, session: session)
    }

    // MARK: - 在家判定（探测内网，不需要任何权限）

    /// 内网通了 = 在家。比读 WiFi 名字可靠得多，也不需要定位权限。
    /// 按多个候选地址并发试：不同 WiFi 下手机拿到的网段不同，只试一个会误判成"在外"。
    func probeLAN() async -> (base: String, health: HealthInfo)? {
        let hosts = await MainActor.run { settings.lanCandidates }
        let port = await MainActor.run { settings.port }
        let bases = hosts.map { "http://\($0):\(port)" }
        // 内网响应极快，2 秒不回来基本就是不在家
        guard let hit = await firstAlive(bases, timeout: 2.0, session: session) else { return nil }
        let host = hosts[hit.index]
        // 记住这次能通的地址，下次优先试它（只有真的变了才写，避免反复落盘）
        await MainActor.run {
            if settings.lanHost != host { settings.lanHost = host }
        }
        return (hit.base, hit.health)
    }

    // MARK: - 在外判定（先试缓存地址）

    func probePublic(addrs: [String]) async -> String? {
        let port = await MainActor.run { settings.port }
        let bases = addrs.map { "http://[\($0)]:\(port)" }
        guard let hit = await firstAlive(bases, timeout: 4.0, session: session) else { return nil }
        return hit.base
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
    func resolve() async -> (place: NetPlace, base: String?, health: HealthInfo?) {
        // 1) 在家：内网通了就是在家，顺手把服务器自己报的公网地址存下来
        if let lan = await probeLAN() {
            if let addrs = lan.health.addrs, !addrs.isEmpty {
                await MainActor.run { settings.publicAddrs = addrs }
            }
            return (.home, lan.base, lan.health)
        }

        // 2) 在外：先用上次缓存的地址（绝大多数时候这一步就通了，最快）
        let cached = await MainActor.run { settings.publicAddrs }
        if let pub = await probePublic(addrs: cached) {
            return (.away, pub, nil)
        }

        // 3) 缓存失效（运营商换了前缀）：问 Gist 要最新地址再试一次
        if let g = await fetchGistAddr(), let ips = g.ipv6, !ips.isEmpty {
            let newPort = (g.port ?? 0) > 0 ? g.port! : 0
            await MainActor.run {
                settings.publicAddrs = ips
                if newPort > 0 { settings.port = newPort }
            }
            if let pub = await probePublic(addrs: ips) {
                return (.away, pub, nil)
            }
        }

        return (.unknown, nil, nil)
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
}
