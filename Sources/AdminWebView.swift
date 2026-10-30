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

        /// 页面加载完后检查一下「拿到的到底是不是网页」。
        ///
        /// 为什么要这一步：服务端在拒绝访问时（比如 tunnel_admin 被关掉、
        /// 或者公网直连非 /v1 路径）返回的是 `{"error": {...}}` 这样的 JSON，
        /// WKWebView 会把它当纯文本渲染出来 —— 用户看到的就是满屏花括号加
        /// 一串乱码般的转义字符，完全不知道发生了什么（已收到这个反馈）。
        ///
        /// 这里不额外发请求（后台首页有 900 多 KB，多打一次纯浪费），
        /// 而是复用已经渲染好的页面：读 body 的纯文本，如果开头像 JSON 错误，
        /// 就把整页替换成一句人话，并把原始内容折叠在下面备查。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = """
            (function(){
              try {
                var t = (document.body && document.body.innerText) || '';
                t = t.trim();
                if (t.charAt(0) !== '{') return '';
                var o = null;
                try { o = JSON.parse(t); } catch(e) { return ''; }
                if (!o || !o.error) return '';
                var msg = o.error.message || '';
                var type = o.error.type || '';
                return JSON.stringify({msg: msg, type: type});
              } catch(e) { return ''; }
            })();
            """
            webView.evaluateJavaScript(js) { result, _ in
                guard let s = result as? String, !s.isEmpty,
                      let d = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return }
                let msg = (obj["msg"] as? String) ?? "后台拒绝了这次访问"
                let type = (obj["type"] as? String) ?? ""
                // 按错误类型给一句「怎么办」，光说哪里错了用户还是没法处理
                var hint = "请确认手机和路由器在同一个网络，或改用 App 里的内网地址。"
                if type == "private_only" {
                    hint = "后台目前只允许内网访问。想在外面也能管理，"
                         + "需要把路由器上的 tunnel_admin 打开（后台「设置 → 安全」里有这个开关）。"
                }
                let html = Self.errorPage(title: "进不去后台", message: msg, hint: hint, raw: s)
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        /// 生成一张跟 App 观感一致的提示页（浅灰底 + 居中卡片）。
        private static func errorPage(title: String, message: String,
                                      hint: String, raw: String) -> String {
            func esc(_ s: String) -> String {
                return s.replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                        .replacingOccurrences(of: "\"", with: "&quot;")
            }
            return """
            <!DOCTYPE html><html lang="zh-CN"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <style>
              :root { color-scheme: light dark; }
              body { margin:0; min-height:100vh; display:flex; align-items:center;
                     justify-content:center; padding:24px 20px; box-sizing:border-box;
                     background:#F8F8F8; font:400 15px/1.55 -apple-system,
                     BlinkMacSystemFont, "PingFang SC", sans-serif; color:#1C1C1E; }
              @media (prefers-color-scheme: dark) {
                body { background:#1C1C1E; color:#F2F2F7; }
                .card { background:#2C2C2E !important; }
                .hint { color:#AEAEB2 !important; }
                details { border-top-color:#3A3A3C !important; }
                pre { background:#1C1C1E !important; color:#AEAEB2 !important; }
              }
              .card { background:#FFFFFF; border-radius:20px; padding:22px 20px;
                      max-width:520px; width:100%; box-shadow:0 6px 24px rgba(0,0,0,.06); }
              .ic { font-size:26px; margin-bottom:10px; }
              h1 { font-size:17px; font-weight:600; margin:0 0 8px; }
              p { margin:0 0 10px; }
              .hint { color:#6C6C70; font-size:14px; margin-bottom:0; }
              details { margin-top:16px; border-top:1px solid #E5E5EA; padding-top:12px; }
              summary { font-size:13px; color:#8E8E93; cursor:pointer; outline:none; }
              pre { margin:10px 0 0; padding:10px; background:#F2F2F7; border-radius:10px;
                    font:400 11px/1.5 ui-monospace, Menlo, monospace;
                    white-space:pre-wrap; word-break:break-all; color:#6C6C70; }
            </style></head><body>
            <div class="card">
              <div class="ic">🔒</div>
              <h1>\(esc(title))</h1>
              <p>\(esc(message))</p>
              <p class="hint">\(esc(hint))</p>
              <details><summary>查看原始返回</summary><pre>\(esc(raw))</pre></details>
            </div>
            </body></html>
            """
        }
    }
}
