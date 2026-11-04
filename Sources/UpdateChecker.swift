import Foundation
import UIKit

// MARK: - 检查更新 & 一键安装
//
// 【为什么要有这个文件】
//
// 用户原话：
//   「他现在更新好以后只能存储到文件在去安装，能不能让他更新完就有共享功能，
//     然后我直接共享到巨魔就能安装了，要不的我还得储存到文件 app 在去共享到巨魔软件安装」
//   「点击更新他就自动下载了，下载完成，自己就更新成功了」
//
// 也就是说目标只有一条：**在 App 里点一下，更新就装好，中间不要碰「文件」App**。
//
// 【怎么做到的】
//
// TrollStore 在自己的 Info.plist 里注册了 URL Scheme `apple-magnifier`
// （伪装成系统「放大镜」，因为巨魔要绕过系统对第三方安装器的限制）。
// 它的 TSSceneDelegate.m 里明确写了两个入口：
//
//   ① 文件入口：open 一个 .ipa / .tipa 文件 URL → 弹安装框 → 安装
//   ② 远程入口：apple-magnifier://install?url=<https 地址>
//                → 走 handleAppInstallFromRemoteURL → **自己下载并安装**
//
// ②就是我们要的。所以不需要先存到「文件」App，也不需要分享菜单：
//   点「更新」→ App 检查 GitHub Release → 直接 open 这条 scheme → 巨魔接管安装。
//
// 【拿不到 TrollStore 时怎么办】
//
// 不是所有人都装了巨魔（或者装的是别的签名工具）。所以方案分三层，
// 从上到下依次降级，每一层都是完整可用的一条路：
//
//   1. 已装 TrollStore        → apple-magnifier://install 一键直装（最理想）
//   2. 没装巨魔但能分享        → 下载到本地 → 弹系统分享菜单（可发给任意 App）
//   3. 都不行                  → 打开 GitHub 页面，手动下载
//
// 为什么不直接依赖分享菜单：分享菜单里「拷贝到 TrollStore」这一步
// 在某些 iOS 版本上会把文件塞进「文件」App 的中转区，用户描述的那个弯路
// 就出在这里。能直装就不要走分享。

/// 一次更新的元信息（从 GitHub Release 读出来的）
struct UpdateInfo: Equatable {
    /// Release 里写的版本号（我们自己发版时写成 1.11.6 这种）
    let version: String
    let assetName: String
    let downloadURL: URL
    let sizeBytes: Int

    var sizeText: String {
        let b = Double(sizeBytes)
        if b < 1024 { return "\(sizeBytes) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1024 / 1024)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {

    /// 固定不变的发布地址。CI 每次构建都会重建 tag 为 `latest` 的 Release，
    /// 所以这个地址永远指向最新的一个包（见 .github/workflows/ios.yml）。
    static let releaseAPI = URL(string: "https://api.github.com/repos/vipios/airelaychat/releases/tags/latest")!
    static let fallbackPage = URL(string: "https://github.com/vipios/airelaychat/releases/latest")!

    enum Phase: Equatable {
        case idle
        case checking
        /// 查到有新版，等用户点「立即更新」
        case available(UpdateInfo)
        case upToDate
        /// 正在下载（只有在走分享兜底时才需要下载，直装由巨魔自己下）
        case downloading(Double)
        /// 下载完，正在弹分享菜单
        case readyToShare(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// App 自己的版本号，用来和 Release 上的比
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: 检查

    /// 查一次 GitHub，看有没有比现在新的版本。
    ///
    /// 版本比较用数字逐段比，不能用字符串 —— 否则 "1.9.0" 会被判成比 "1.10.0" 新。
    func check() async {
        phase = .checking
        do {
            var req = URLRequest(url: Self.releaseAPI)
            req.timeoutInterval = 15
            // GitHub API 不带 User-Agent 会 403
            req.setValue("AIRelayChat", forHTTPHeaderField: "User-Agent")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.badResponse
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else {
                throw UpdateError.badJSON
            }

            // 优先找 .ipa，其次 .tipa —— CI 发的是 .ipa。
            // 分开两行写而不是 ?? 串联：右边的尾随闭包跟在 ?? 后面
            // 有解析歧义风险（编译器会把闭包当成 ?? 的参数）。
            let ipaAssets = assets.filter { ($0["name"] as? String)?.hasSuffix(".ipa") == true }
            let tipaAssets = assets.filter { ($0["name"] as? String)?.hasSuffix(".tipa") == true }
            let pick: [String: Any]? = ipaAssets.first ?? tipaAssets.first
            guard let a = pick,
                  let name = a["name"] as? String,
                  let urlStr = a["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else {
                throw UpdateError.noAsset
            }

            // 版本号藏在 Release 标题里："AIRelayChat latest (v1.11.6)"
            let title = (json["name"] as? String) ?? (json["tag_name"] as? String) ?? ""
            let latest = Self.versionIn(title) ?? "0"

            let info = UpdateInfo(
                version: latest,
                assetName: name,
                downloadURL: url,
                sizeBytes: (a["size"] as? Int) ?? 0
            )

            if Self.isNewer(latest, than: currentVersion) {
                phase = .available(info)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    // MARK: 安装

    /// 用户点了「立即更新」。
    ///
    /// 先试 TrollStore 直装（一条 URL 就够，巨魔自己去下载 + 安装）；
    /// 手机没装巨魔时这条 URL 打不开，此时再退回「下载 + 分享」。
    func install(_ info: UpdateInfo) async {
        // 先看这手机到底装没装巨魔。
        // 为什么不直接 open 试一下：没装的时候 open 会失败，系统还可能
        // 弹一个「无法打开」的提示，看起来像报错，体验很差。先问一句更干净。
        if Self.hasTrollStore(),
           let direct = Self.trollStoreInstallURL(for: info.downloadURL),
           await Self.open(direct) {
            // 巨魔已经接手了，后面全由它做（它自己下载、自己弹安装确认）。
            // 这里不改 phase，保留「有新版」状态，用户从巨魔回来后点一下即可重新检查。
            return
        }
        // 没有巨魔 → 下载到本地再弹分享
        await downloadThenShare(info)
    }

    /// 直接把更新交给系统分享菜单（用户主动选「分享安装包」时用）
    func shareInstead(_ info: UpdateInfo) async {
        if case .readyToShare = phase { return }
        await downloadThenShare(info)
    }

    private func downloadThenShare(_ info: UpdateInfo) async {
        phase = .downloading(0)
        do {
            var req = URLRequest(url: info.downloadURL)
            req.timeoutInterval = 120
            req.setValue("AIRelayChat", forHTTPHeaderField: "User-Agent")

            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.badResponse
            }
            // 下载落在 tmp，系统随时可能清掉，必须搬到自己的 Documents 下。
            // 用 .ipa 后缀 —— TrollStore 靠后缀识别能否安装。
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dst = dir.appendingPathComponent(info.assetName)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            phase = .readyToShare(dst)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// 分享/安装完把临时包删掉，别占着手机空间（一个包 1.5MB 也会越积越多）
    func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if case .readyToShare = phase { phase = .idle }
    }

    // MARK: 工具

    /// 生成 TrollStore 的安装 URL。
    ///
    /// 格式来自 TrollStore 源码 TSSceneDelegate.m：
    ///   host == "install" 时读 query 里的 url，交给
    ///   handleAppInstallFromRemoteURL 去下载安装。
    ///
    /// 注意 remote 安装**只接受 https**（源码里会校验），
    /// GitHub Release 的资源地址正好是 https，符合要求。
    static func trollStoreInstallURL(for ipa: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "apple-magnifier"
        c.host = "install"
        c.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return c.url
    }

    /// 手机是否装了 TrollStore（用 canOpenURL 探测，需先在 Info.plist 里
    /// 把 apple-magnifier 加进 LSApplicationQueriesSchemes，否则永远返回 false）
    static func hasTrollStore() -> Bool {
        guard let u = URL(string: "apple-magnifier://install") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    /// open 一条 URL。成功返回 true。
    ///
    /// 这里必须拿到真实的成败：如果手机没装 TrollStore，
    /// open 会失败，我们要靠这个结果决定是否降级到分享。
    ///
    /// 标 @MainActor 是因为 UIApplication.shared 只能在主线程碰；
    /// 整个类本来就是 @MainActor，显式标一下让 Swift 6 的并发检查也放行。
    @MainActor
    @discardableResult
    static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // UIApplication.open 的回调固定回主线程，所以这里直接 resume 是安全的
            UIApplication.shared.open(url, options: [:]) { ok in
                cont.resume(returning: ok)
            }
        }
    }

    /// 从 "AIRelayChat latest (v1.11.6)" 里抠出 1.11.6
    static func versionIn(_ text: String) -> String? {
        guard let r = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// 逐段按数字比版本，避免 "1.9" > "1.10" 这类字符串比较错误
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(x.count, y.count)
        for i in 0..<n {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func describe(_ e: Error) -> String {
        if let u = e as? UpdateError { return u.text }
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "没有网络，连不上 GitHub"
            case NSURLErrorTimedOut: return "连 GitHub 超时了，过会儿再试"
            default: break
            }
        }
        return "检查失败：\(ns.localizedDescription)"
    }

    enum UpdateError: Error {
        case badResponse, badJSON, noAsset
        var text: String {
            switch self {
            case .badResponse: return "GitHub 返回异常，过会儿再试"
            case .badJSON:     return "GitHub 返回的内容看不懂（可能被限流了）"
            case .noAsset:     return "这个版本里没找到安装包"
            }
        }
    }
}
