import Foundation

/// 独立重启通道：直连路由器自带的 uhttpd，**完全不经过中转站**。
///
/// 为什么必须有这条通道（2026-10-31 用户拍板）：
/// 之前「重启路由器」是调中转站的 `/admin/api/device/reboot`，而中转站恰恰是
/// 最会卡死的那个东西（Python 单进程、内存不够就 swap 颠簸）。结果就是
/// 「路由卡了 → 想重启 → 中转站也卡着 → 指令发不出去」的死锁。
///
/// 现在改成直连 uhttpd 上的 `/cgi-bin/airboot`：
///   - uhttpd 是 C 写的，procd 托管，跟 Python 一点关系没有
///   - 中转站进程被杀、8080 全挂，这条通道照样能应答（已实测）
///   - 不需要登录态，只要内网可达 + 后台密钥对得上
///
/// 判断依据是返回的 `"svc":"airboot"`，不会把别的 Web 服务误认成路由器。
enum BootChannel {

    /// CGI 路径，和设备上 `/www/cgi-bin/airboot` 对应
    static let path = "/cgi-bin/airboot"

    /// 单次探测超时。
    ///
    /// 给 1.2 秒而不是 0.4 秒：uhttpd 要 fork+exec 一个 shell 脚本，
    /// 这台路由器的 CPU 又很弱，0.4 秒经常还没 exec 完就被判超时，
    /// 结果「明明在家却显示连不上」。
    static let probeTimeout: TimeInterval = 1.2

    // MARK: - 探活

    /// 这个地址上有没有 airboot 通道。
    ///
    /// 用 ephemeral session：不复用 cookie/连接池，避免拿着一个已经死掉的
    /// 长连接在那干等（这正是之前「重连要等十几秒」的原因之一）。
    static func ping(host: String, timeout: TimeInterval = 1.2) async -> Bool {
        guard let u = url(host: host, query: "action=ping") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        // 只认自家标记：光猫/别的路由器也有 80 端口，但它们不认 svc=airboot
        return (doc["ok"] as? Bool) == true && (doc["svc"] as? String) == "airboot"
    }

    // MARK: - 找地址

    /// 并发探一批候选地址，谁先应答就用谁。
    ///
    /// 并发而不是挨个试：候选就有十来个，串行最坏要十几秒；
    /// 并发的话总耗时约等于最慢的那一个（1.2 秒）。
    static func discover(candidates: [String],
                        timeout: TimeInterval = 1.2) async -> String? {
        let hosts = candidates.reduce(into: [String]()) { acc, h in
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !acc.contains(t) else { return }
            acc.append(t)
        }
        guard !hosts.isEmpty else { return nil }

        return await withTaskGroup(of: String?.self) { group in
            for h in hosts {
                group.addTask { await ping(host: h, timeout: timeout) ? h : nil }
            }
            for await r in group {
                if let hit = r {
                    group.cancelAll()
                    return hit
                }
            }
            return nil
        }
    }

    // MARK: - 发指令

    /// 让路由器重启。
    ///
    /// 服务端**先回 200 再真重启**（延迟 2 秒），所以拿到响应只代表
    /// 「指令已受理」，不代表已经重启完 —— 界面要自己提示"约 40 秒后恢复"。
    static func reboot(host: String, key: String, timeout: TimeInterval = 8) async throws {
        guard !key.isEmpty else { throw BootError.noKey }
        guard let u = url(host: host,
                          query: "action=reboot&k=" + escaped(key)) else {
            throw BootError.badHost
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 502/500 也常见：脚本已经 exec 了 reboot，uhttpd 等不到输出就报错。
        // 这种其实"已经重启了"，不能当失败处理，否则用户会重复点。
        if code != 200 && code != 500 && code != 502 {
            throw BootError.http(code)
        }
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if code == 500 || code == 502 { return }
            throw BootError.badReply
        }
        if (doc["ok"] as? Bool) == true { return }
        let err = (doc["err"] as? String) ?? ""
        switch err {
        case "bad-key", "no-token": throw BootError.badKey
        case "lan-only": throw BootError.notLan
        default: throw BootError.rejected(err)
        }
    }

    // MARK: - 小工具

    /// 组装请求地址。候选可以是裸 IP（内网），也可以是带协议的完整地址（公网域名）。
    ///
    /// 为什么允许带协议：在家走内网 `http://192.168.1.88`，在外面走
    /// `https://<域名>`（Cloudflare 隧道），两者只差一个前缀，
    /// 没必要为它们写两套代码。
    private static func url(host: String, query: String) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h = String(h.dropLast()) }
        guard !h.isEmpty else { return nil }
        if !h.contains("://") { h = "http://" + h }
        return URL(string: h + path + "?" + query)
    }

    private static func escaped(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

enum BootError: LocalizedError {
    case noKey, badHost, badKey, notLan, badReply, http(Int), rejected(String)

    var errorDescription: String? {
        switch self {
        case .noKey:            return "还差后台密钥"
        case .badHost:          return "路由器地址不对"
        case .badKey:           return "后台密钥不对，重启被拒绝"
        case .notLan:           return "重启通道只允许内网访问（要在家里 WiFi 或开 ZeroTier）"
        case .badReply:         return "路由器返回了看不懂的内容"
        case .http(let c):      return "路由器返回 HTTP \(c)"
        case .rejected(let e):  return "路由器拒绝了：\(e)"
        }
    }
}
