import Foundation
import UIKit

// MARK: - 诊断

/// 一条探测结果
struct DiagRow: Identifiable {
    let id = UUID()
    var target: String      // 探测的地址
    var label: String       // 这一步在干什么
    var ok: Bool
    var detail: String      // 耗时 / HTTP 码 / 错误原因
}

/// 连接问题的自我诊断。服务端明明正常但手机连不上时，用它定位是哪一环断了。
///
/// 最常见的元凶是 iOS 的「本地网络」权限：点过一次「不允许」后，系统会直接
/// 拦掉所有局域网请求，而且**不报错**（表现为超时或 "网络连接已中断"），
/// 用户完全看不出原因。
@MainActor
final class Diagnostics: ObservableObject {
    @Published var rows: [DiagRow] = []
    @Published var running = false
    @Published var summary: String = ""
    @Published var localNetworkDenied = false

    private let settings = Settings.shared
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func run() async {
        guard !running else { return }
        running = true
        rows = []
        summary = ""
        defer { running = false }

        // 0) 系统环境
        let v = UIDevice.current.systemVersion
        rows.append(DiagRow(target: "iOS \(v)", label: "系统版本", ok: true, detail: ""))
        rows.append(DiagRow(target: "\(settings.port)", label: "使用端口", ok: true, detail: ""))

        if let p = settings.currentProvider {
            rows.append(DiagRow(target: p.name, label: "当前来源",
                                ok: true, detail: p.isHome ? "家里中转站" : p.baseURL))
        }

        // 1) 本地网络权限。iOS 14+ 第一次访问局域网会弹框；
        //    被拒之后所有内网请求都会静默失败。这里探测一个必然不通的
        //    内网地址，如果立刻报 "No route to host / 无路由" 说明权限可能被拒。
        rows.append(DiagRow(target: "—", label: "开始探测内网", ok: true, detail: ""))

        var lanHit = false
        for host in settings.lanCandidates {
            let base = "http://\(host):\(settings.port)"
            let r = await probe(base + "/health")
            rows.append(DiagRow(target: base, label: "内网", ok: r.ok, detail: r.detail))
            if r.ok { lanHit = true }
        }

        // 2) 公网
        if !lanHit {
            let addrs = settings.publicAddrs
            if addrs.isEmpty {
                rows.append(DiagRow(target: "—", label: "公网", ok: false,
                                    detail: "没有缓存的公网地址，下面会去 Gist 拉"))
            } else {
                for ip in addrs {
                    let base = "http://[\(ip)]:\(settings.port)"
                    let r = await probe(base + "/health")
                    rows.append(DiagRow(target: base, label: "公网", ok: r.ok, detail: r.detail))
                }
            }
        }

        // 3) Gist
        let gistRows = await probeGist()
        rows.append(contentsOf: gistRows)

        // 4) 结论
        if lanHit {
            summary = "内网是通的。如果聊天还失败，问题在密钥或模型，不是网络。"
        } else if rows.contains(where: { $0.ok && $0.label == "公网" }) {
            summary = "内网不通但公网通。说明你现在不在家，或手机没连家里 WiFi。"
        } else {
            summary = "两条路都不通。请按下面的提示逐条排查。"
        }
        localNetworkDenied = !lanHit && rows.contains {
            $0.label == "内网" && $0.detail.contains("已中断")
        }
    }

    /// 探测一次，返回结果与可读的错误原因
    private func probe(_ urlString: String) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: urlString) else { return (false, "地址格式不对") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            if code == 200, body.contains("\"status\"") {
                return (true, "\(ms)ms · HTTP 200 · 服务正常")
            }
            if code == 401 {
                return (true, "\(ms)ms · HTTP 401（服务在，只是要密钥）")
            }
            return (false, "\(ms)ms · HTTP \(code) · \(body.prefix(60))")
        } catch let e as NSError {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (false, "\(ms)ms · \(describe(e))")
        }
    }

    /// 把 NSURLError 翻译成人能看懂的话
    private func describe(_ e: NSError) -> String {
        switch e.code {
        case NSURLErrorTimedOut:
            return "超时（对方没应答，可能是地址不对/不在同一网段/被系统拦截）"
        case NSURLErrorCannotConnectToHost:
            return "连不上该地址（服务没开，或端口不对）"
        case NSURLErrorCannotFindHost:
            return "找不到这个主机"
        case NSURLErrorNetworkConnectionLost:
            return "连接已中断（iOS 常见于本地网络权限被拒）"
        case NSURLErrorNotConnectedToInternet:
            return "手机没有网络"
        case NSURLErrorNoPermissionsToReadFile:
            return "没有权限"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "被 ATS 拦截（Info.plist 没放开 http）"
        default:
            return "错误 \(e.code)：\(e.localizedDescription)"
        }
    }

    private func probeGist() async -> [DiagRow] {
        var out: [DiagRow] = []
        let raw = "https://gist.githubusercontent.com/\(settings.gistOwner)/\(settings.gistId)/raw/relay-addr.json"
        let t0 = Date()
        do {
            var req = URLRequest(url: URL(string: raw)!)
            req.timeoutInterval = 6
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            out.append(DiagRow(target: "Gist", label: "地址上报",
                               ok: code == 200, detail: "\(ms)ms · HTTP \(code) · \(body.prefix(80))"))
        } catch let e as NSError {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            out.append(DiagRow(target: "Gist", label: "地址上报", ok: false,
                               detail: "\(ms)ms · \(describe(e))"))
        }
        return out
    }

    /// 复制成文本，方便发给我看
    func dump() -> String {
        var s = "AIRelayChat 诊断\n"
        for r in rows {
            s += "\(r.ok ? "OK  " : "FAIL") [\(r.label)] \(r.target) — \(r.detail)\n"
        }
        s += "\n结论：\(summary)\n"
        return s
    }
}
