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
}

// MARK: - 错误

enum RelayError: LocalizedError {
    case noEndpoint
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            return "连不上中转站。在家请确认连着家里 WiFi；在外面请确认手机有 IPv6 网络。"
        case .http(let code, let msg):
            let brief = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 401 { return "访问密钥不对或没填，去「设置」里填一下。" }
            if brief.isEmpty { return "上游返回 HTTP \(code)" }
            return "HTTP \(code)：\(brief.prefix(160))"
        case .empty:
            return "上游没有返回内容，请重试。"
        }
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

    // MARK: - 基础请求

    private func get(_ urlString: String, timeout: TimeInterval = 3) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw RelayError.noEndpoint }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    /// 服务活着吗？只认 status == "ok"，避免把别的网页当成功
    private func alive(_ base: String, timeout: TimeInterval) async -> HealthInfo? {
        do {
            let (code, data) = try await get(base + "/health", timeout: timeout)
            guard code == 200,
                  let h = try? JSONDecoder().decode(HealthInfo.self, from: data),
                  h.status == "ok" else { return nil }
            return h
        } catch {
            return nil
        }
    }

    // MARK: - 在家判定（探测内网，不需要任何权限）

    /// 内网通了 = 在家。比读 WiFi 名字可靠得多，也不需要定位权限。
    func probeLAN() async -> (base: String, health: HealthInfo)? {
        let base = await MainActor.run { settings.lanBase }
        // 内网响应极快，2 秒不回来基本就是不在家，不必等太久
        if let h = await alive(base, timeout: 2.0) {
            return (base, h)
        }
        return nil
    }

    // MARK: - 在外判定（先试缓存地址）

    func probePublic(addrs: [String]) async -> String? {
        let port = await MainActor.run { settings.port }
        for ip in addrs {
            let base = "http://[\(ip)]:\(port)"
            if await alive(base, timeout: 4.0) != nil {
                return base
            }
        }
        return nil
    }

    // MARK: - Gist 读地址（三路降级）

    /// GitHub raw 直连不通时依次走公共加速站。每路 5 秒，全失败返回 nil。
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
    /// 所以平时不会给对话增加任何延迟。
    func fetchGistAddr() async -> GistAddr? {
        for u in await gistURLs() {
            do {
                let (code, data) = try await get(u, timeout: 5)
                guard code == 200,
                      let g = try? JSONDecoder().decode(GistAddr.self, from: data),
                      let ips = g.ipv6, !ips.isEmpty else { continue }
                return g
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - 核心：判定场景并给出本次要用的地址

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

    // MARK: - 模型列表

    func models(base: String) async throws -> [ModelInfo] {
        guard let url = URL(string: base + "/v1/models") else { throw RelayError.noEndpoint }
        let key = await MainActor.run { settings.gatewayKey }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ModelList.self, from: data).data
    }

    // MARK: - 流式对话（真流式：逐字出现）

    /// 用 bytes 逐行读 SSE，边收边显示
    func stream(base: String, model: String, messages: [ChatMessage],
                onDelta: @escaping (String) -> Void) async throws {

        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw RelayError.noEndpoint
        }
        let key = await MainActor.run { settings.gatewayKey }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
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

        // 累积所有增量，交给调用方一次判空：避免每个字符都跨 actor 切换
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
            let text = try await nonStream(base: base, model: model, messages: messages)
            if !text.isEmpty {
                onDelta(text)
            } else if collected.isEmpty {
                throw RelayError.empty
            }
        }
    }

    /// 非流式兜底（上游不认 stream 时用）
    private func nonStream(base: String, model: String, messages: [ChatMessage]) async throws -> String {
        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw RelayError.noEndpoint
        }
        let key = await MainActor.run { settings.gatewayKey }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RelayError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = doc["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let c = msg["content"] as? String else { return "" }
        return c
    }
}
