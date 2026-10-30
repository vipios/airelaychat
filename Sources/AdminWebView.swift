import SwiftUI
import WebKit
import Security

// MARK: - 后台管理密钥（存钥匙串）

/// 后台网页用一个 access_key 登录，前端把它存在 localStorage['relayKey']。
///
/// 为什么要存钥匙串而不是 UserDefaults：
/// UserDefaults 是明文 plist，越狱设备或备份里能直接看到；
/// 钥匙串有系统级加密，同样一行代码的事，没必要省这一步。
enum AdminKey {
    private static let service = "com.vipios.airelaychat.admin"
    private static let account = "access_key"
    /// 老版本可能把它存过 UserDefaults，一并读一下做迁移
    private static let legacyUDKey = "airelay.adminKey"

    static func load() -> String {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &item)
        if st == errSecSuccess, let d = item as? Data,
           let s = String(data: d, encoding: .utf8), !s.isEmpty {
            return s
        }
        // 迁移：老版本存在 UserDefaults 里的
        let legacy = UserDefaults.standard.string(forKey: legacyUDKey) ?? ""
        if !legacy.isEmpty {
            save(legacy)
            UserDefaults.standard.removeObject(forKey: legacyUDKey)
        }
        _ = q
        return legacy
    }

    static func save(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        let data = Data(k.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - 后台面板（App 内嵌，免登录）

/// 把中转站的网页后台套进 App。
///
/// 为什么不用 SafariViewController：
///  1. 它是独立进程、独立数据，我们没法在页面加载前把密钥塞进 localStorage，
///     只能让用户每次手输；而且「进去就白屏几秒」也没法加自己的加载态。
///  2. 用户明确要求「只有首次需要密码，以后自动登录」。
///
/// 这里用 WKWebView + 持久化数据存储 + documentStart 注入，做到：
///  - localStorage（后台的登录标记）跟着 App 一直留着
///  - 就算 localStorage 被清（换 WebView 版本、用户手动清），
///    下一次加载会用钥匙串里的密钥重新写回去，等于永远免登录
struct AdminWebView: UIViewRepresentable {
    /// 后台地址，比如 http://192.168.1.88:8080
    let base: String
    /// 访问密钥（空 = 后台没设密码）
    let key: String
    /// 每次切到这个 Tab 时 +1，用来触发 reload
    let reloadTick: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 默认数据存储就是持久化的：cookie / localStorage 会跨启动保留
        cfg.websiteDataStore = .default()

        // 关键：在页面任何脚本跑之前，把登录标记写进 localStorage。
        // 必须 atDocumentStart —— atDocumentEnd 时后台的 JS 已经判断过"没登录"、
        // 把锁屏页面渲染出来了，再写就晚了（页面不会自己重画）。
        // forMainFrameOnly = false 是为了让后台可能弹出的子页也带上。
        let escaped = jsString(key)
        if !key.isEmpty {
            let js = """
            (function(){
              try {
                localStorage.setItem('relayKey', \(escaped));
              } catch(e) {}
            })();
            """
            let script = WKUserScript(source: js,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
            cfg.userContentController.addUserScript(script)
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        // 后台页面是给手机浏览器做的，但有些输入框字号偏小，允许缩放更稳
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.973, green: 0.973, blue: 0.973, alpha: 1)
        context.coordinator.load(wv, base: base, tick: reloadTick)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        // 只有 reloadTick 变了才重新加载：否则每次 cell 复用都会刷一次，
        // 用户刚点进某个子页面就被弹回首页。
        context.coordinator.load(wv, base: base, tick: reloadTick)
    }

    /// 把 Swift 字符串安全地变成 JS 字面量
    private func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // ["xxx"] -> "xxx"
        str = String(str.dropFirst().dropLast())
        return str
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var loadedURL: String = ""
        private var lastTick: Int = -1
        private var loadedKey: String = ""

        func load(_ wv: WKWebView, base: String, tick: Int) {
            let url = base.hasSuffix("/") ? base + "admin" : base + "/admin"
            let changedKey = (loadedKey != base)
            guard tick != lastTick || loadedURL != url || changedKey else { return }
            lastTick = tick
            loadedURL = url
            loadedKey = base
            guard let u = URL(string: url) else { return }
            wv.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        }

        /// 后台有可能弹出 target=_blank 的链接（比如复制 Key 的说明页），
        /// 直接在当前 WebView 里打开，别丢给系统浏览器（那样会跳出 App）。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
