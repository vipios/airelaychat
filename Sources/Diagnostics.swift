import Foundation
import UIKit
import Darwin   // getifaddrs / AF_INET / NI_MAXHOST

// MARK: - 手机自身的网络接口信息

/// 用 getifaddrs 读本机所有网卡的 IPv4/IPv6 地址。
/// 不需要任何权限，这是判断「手机到底在哪个网」最直接的办法。
struct NetIface {
    var name: String        // en0 = WiFi, pdp_ip0 = 蜂窝
    var ipv4: [String]
    var ipv6: [String]

    var isWiFi: Bool { name == "en0" }
    var isCellular: Bool { name.hasPrefix("pdp_ip") }

    var kindText: String {
        if isWiFi { return "WiFi" }
        if isCellular { return "蜂窝" }
        if name.hasPrefix("utun") { return "VPN" }
        if name.hasPrefix("bridge") { return "热点" }
        return name
    }
}

enum NetInfo {

    static func interfaces() -> [NetIface] {
        var out: [NetIface] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(first) }

        var table: [String: (v4: [String], v6: [String])] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if let sa = ifa.ifa_addr {
                let family = Int32(sa.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    // sa_len 在 iOS 上是 UInt8，直接转 socklen_t
                    let len = socklen_t(sa.pointee.sa_len)
                    if getnameinfo(sa, len, &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        var e = table[name] ?? ([], [])
                        // 过滤链路本地地址，对判断没意义还占篇幅
                        if family == AF_INET {
                            e.v4.append(ip)
                        } else if !ip.hasPrefix("fe80") {
                            e.v6.append(ip)
                        }
                        table[name] = e
                    }
                }
            }
            p = ifa.ifa_next
        }

        // en0 排前面，其余按名字
        for (name, v) in table.sorted(by: { a, b in
            if a.key == "en0" { return true }
            if b.key == "en0" { return false }
            return a.key < b.key
        }) {
            out.append(NetIface(name: name, ipv4: v.v4, ipv6: v.v6))
        }
        return out
    }

    /// 当前 WiFi 的 IPv4（没有就是没连 WiFi）
    static func wifiIPv4() -> String? {
        interfaces().first(where: { $0.isWiFi })?.ipv4.first
    }

    /// 判断两个 IPv4 是否在同一 /24 网段
    static func sameSubnet24(_ a: String, _ b: String) -> Bool {
        func prefix(_ s: String) -> String? {
            let parts = s.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return parts.prefix(3).joined(separator: ".")
        }
        guard let pa = prefix(a), let pb = prefix(b) else { return false }
        return pa == pb
    }
}

// MARK: - 诊断

struct DiagRow: Identifiable {
    let id = UUID()
    var target: String      // 探测的地址
    var label: String       // 这一步在干什么
    var ok: Bool
    var detail: String      // 耗时 / HTTP 码 / 错误原因
}

/// 连接问题的自我诊断。服务端明明正常但手机连不上时，用它定位是哪一环断了。
///
/// 排查顺序是有讲究的：先看手机自己在哪个网（这一步无法被权限干扰），
/// 再看能不能访问局域网。两者对照就能区分「没连 WiFi」「连错网」「权限被拒」。
@MainActor
final class Diagnostics: ObservableObject {
    @Published var rows: [DiagRow] = []
    @Published var running = false
    @Published var summary: String = ""
    @Published var localNetworkDenied = false
    @Published var suggestion: String = ""

    private let settings = Settings.shared
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func run() async {
        guard !running else { return }
        running = true
        rows = []
        summary = ""
        suggestion = ""
        localNetworkDenied = false
        defer { running = false }

        // ---------- 第一步：手机自己在哪个网 ----------
        // 注意：这一步纯本地读取，不会被任何权限影响，结论最可靠
        let ifaces = NetInfo.interfaces()
        let wifi = ifaces.first(where: { $0.isWiFi })
        let wifiIP = wifi?.ipv4.first
        let cellular = ifaces.filter { $0.isCellular && !$0.ipv4.isEmpty }

        rows.append(DiagRow(target: "iOS \(UIDevice.current.systemVersion)",
                            label: "系统", ok: true, detail: UIDevice.current.model))

        if let w = wifi, !w.ipv4.isEmpty {
            rows.append(DiagRow(target: w.ipv4.joined(separator: " / "),
                                label: "WiFi 地址", ok: true, detail: "网卡 en0"))
        } else {
            rows.append(DiagRow(target: "无",
                                label: "WiFi 地址", ok: false,
                                detail: "手机没有连 WiFi（en0 没有 IPv4）"))
        }

        if !cellular.isEmpty {
            let ip = cellular.compactMap { $0.ipv4.first }.first ?? ""
            rows.append(DiagRow(target: ip, label: "蜂窝地址", ok: true, detail: "走流量"))
        }

        // WiFi 的 IPv6（公网直连需要它）
        if let w = wifi, let v6 = w.ipv6.first(where: { !$0.hasPrefix("fd") }) {
            rows.append(DiagRow(target: v6, label: "WiFi IPv6", ok: true, detail: "可走公网直连"))
        }

        // ---------- 第二步：能不能访问内网 ----------
        var lanHit: Bool = false
        var hitHost: String?
        for host in settings.lanCandidates {
            let base = "http://\(host):\(settings.port)"
            let r = await probe(base + "/health")
            // 附带说明：这个地址和手机是否同网段
            var note = r.detail
            if let ip = wifiIP, !NetInfo.sameSubnet24(ip, host) {
                note += "（手机 \(ip) 与它不同网段）"
            }
            rows.append(DiagRow(target: base, label: "内网", ok: r.ok, detail: note))
            if r.ok { lanHit = true; hitHost = host }
        }

        // ---------- 第三步：公网 ----------
        var pubHit = false
        if !lanHit {
            let addrs = settings.publicAddrs
            if addrs.isEmpty {
                rows.append(DiagRow(target: "—", label: "公网", ok: false,
                                    detail: "没有缓存的公网地址"))
            } else {
                for ip in addrs {
                    let base = "http://[\(ip)]:\(settings.port)"
                    let r = await probe(base + "/health")
                    rows.append(DiagRow(target: base, label: "公网", ok: r.ok, detail: r.detail))
                    if r.ok { pubHit = true }
                }
            }
        }

        // ---------- 第四步：Gist ----------
        rows.append(contentsOf: await probeGist())

        // ---------- 结论 ----------
        if lanHit {
            summary = "内网通了（\(hitHost ?? "")）。如果聊天还失败，问题在密钥或模型，不是网络。"
        } else if pubHit {
            summary = "内网不通但公网通。说明你现在不在家里 WiFi 上，或者手机连的是别的 WiFi。"
            suggestion = "想在家走内网的话：连上家里 WiFi 再点一次诊断。"
        } else if wifiIP == nil {
            summary = "手机没有连任何 WiFi，内网地址当然访问不到。"
            suggestion = cellular.isEmpty
                ? "打开 WiFi 连上家里的路由器，或者确认手机有移动网络。"
                : "你现在在走流量。在家请连家里 WiFi；在外面需要手机支持 IPv6 才能连公网。"
        } else {
            // 连了 WiFi 但内网不通：要么连错 WiFi，要么权限被拦
            let anySameSeg = settings.lanCandidates.contains {
                NetInfo.sameSubnet24(wifiIP!, $0)
            }
            if !anySameSeg {
                summary = "手机连的 WiFi（\(wifiIP!)）和家里路由器不在同一网段。"
                suggestion = """
                说明你连的不是家里路由器的 WiFi，可能是邻居的、公司的、或者光猫另一个 SSID。
                解决：连上家里路由器发出的那个 WiFi 再试。
                或者：把下面「手动配置」里的地址改成这个 WiFi 的网关 IP 再诊断一次。
                """
            } else {
                summary = "同一网段却连不上，基本可以确定是 iOS 的「本地网络」权限被拦。"
                suggestion = """
                修复步骤：
                1. 设置 → 隐私与安全性 → 本地网络 → 找到「中转站」→ 打开
                2. 如果列表里没有「中转站」，说明还没弹过权限框，重装一次 App 会重新弹
                3. 改完从多任务里彻底划掉 App，再重新打开
                """
                localNetworkDenied = true
            }
        }
    }

    /// 探测一次，返回结果与可读的错误原因
    private func probe(_ urlString: String) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: urlString) else { return (false, "地址格式不对") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
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
            if code == 0 {
                return (false, "\(ms)ms · 没有 HTTP 响应")
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
            return "超时（对方没应答：地址不对 / 不在同网段 / 被系统拦）"
        case NSURLErrorCannotConnectToHost:
            return "连不上（服务没开或端口不对）"
        case NSURLErrorCannotFindHost:
            return "找不到这个主机"
        case NSURLErrorNetworkConnectionLost:
            return "连接被中断（iOS 常见于本地网络权限被拒）"
        case NSURLErrorNotConnectedToInternet:
            return "手机没有网络"
        case NSURLErrorNoPermissionsToReadFile:
            return "没有权限"
        case NSURLErrorSecureConnectionFailed:
            return "安全连接失败"
        default:
            return "错误 \(e.code)：\(e.localizedDescription)"
        }
    }

    private func probeGist() async -> [DiagRow] {
        let raw = "https://gist.githubusercontent.com/\(settings.gistOwner)/\(settings.gistId)/raw/relay-addr.json"
        guard let u = URL(string: raw) else { return [] }
        let t0 = Date()
        do {
            var req = URLRequest(url: u)
            req.timeoutInterval = 8
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            return [DiagRow(target: "Gist", label: "地址上报", ok: code == 200,
                            detail: "\(ms)ms · HTTP \(code) · \(body.prefix(90))")]
        } catch let e as NSError {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return [DiagRow(target: "Gist", label: "地址上报", ok: false,
                            detail: "\(ms)ms · \(describe(e))")]
        }
    }

    /// 复制成文本，方便发给别人看
    func dump() -> String {
        var s = "AIRelayChat 诊断\n"
        for r in rows {
            s += "\(r.ok ? "OK  " : "FAIL") [\(r.label)] \(r.target) — \(r.detail)\n"
        }
        s += "\n结论：\(summary)\n"
        if !suggestion.isEmpty { s += "建议：\(suggestion)\n" }
        return s
    }
}
