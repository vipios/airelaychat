# 中转站 App（AIRelayChat）

家里的 AI 中转站手机客户端。打开就能聊，**自动判断你在家还是在外面**，不用手动切任何东西。

---

## 它能做什么

| 场景 | App 的行为 |
|---|---|
| 在家，连着家里 WiFi | 探测内网 `192.168.2.1:8080` 通 → 判定「在家」，走内网直连（最快），顺手把路由器自己的公网 IPv6 记下来 |
| 在外面，用流量 | 内网探测不通 → 用记下的公网 IPv6 直连，**不需要开 ZeroTier** |
| 在外面，运营商换了 IPv6 前缀 | 缓存地址连不上 → 自动去 GitHub Gist 拉最新地址 → 再连一次 |
| GitHub 也不通 | Gist 读取自动走加速站（直连 → gh-proxy.com → ghfast.top） |
| 回到家里 | 下次打开/切回前台自动重连，切回内网模型 |

模型可以**在家用一个、在外面用一个**，进软件自动切换。

---

## 怎么装到手机

### 方式一：巨魔（TrollStore）—— 推荐，最简单

1. 等 GitHub Actions 跑完（推代码就自动跑）
2. 打开仓库的 **Actions** → 最新一次 **Build IPA** → 页面底部 **Artifacts** → 下载 `AIRelayChat-ipa`
3. 解压得到 `AIRelayChat.ipa`，传到手机（AirDrop / 微信文件传输都行）
4. 用巨魔打开这个 ipa → **Install**

未签名的 ipa 巨魔可以直接装，不用证书。

### 方式二：用自己的证书签名

1. 拿到 `AIRelayChat.ipa`
2. 用 **Sideloadly**（电脑）或 **爱思助手** 打开，选你的 p12 证书 + 描述文件，重签后安装
3. 免费证书 7 天过期，需要重签；付费开发者证书 1 年

### 方式三：自己有 Mac

```bash
cd AIRelayChat
brew install xcodegen
xcodegen generate
open AIRelayChat.xcodeproj
```
选自己的开发者账号，直接 Run 到手机。

---

## 第一次打开要做的两件事

打开 App → 右上角 **齿轮** → 设置：

1. **访问密钥**：填中转站后台的 `access_key`（在路由器后台「设置」里能看到）
2. **模型**：「在家用」和「在外用」各选一个（不选就跟随聊天界面上方选的）

地址默认 `192.168.2.1:8080`，如果你家路由器内网网段不是这个，改成实际 IP。

填完回聊天页，顶栏应该显示 **「在家 · 内网直连」**，能直接发消息。

---

## 常见问题

**Q：顶栏一直显示「未连接」**
- 在家：确认手机连着家里 WiFi；确认路由器上中转站在跑（浏览器打开 `http://192.168.2.1:8080/health` 能看到 JSON）
- 在外：确认手机有 IPv6（iOS 设置 → 蜂窝网络 → 蜂窝数据选项 → 语音与数据，能看到 IPv6 地址）；确认路由器防火墙放行了 8080

**Q：在外面能用，但换了个地方就连不上**
运营商换了 IPv6 前缀。正常情况 App 会自动去 Gist 拉新地址，等几秒会自动连上。如果还不行，去设置里点「从 Gist 拉取最新地址」。

**Q：提示「访问密钥不对」**
去设置里重新填 access_key。密钥在后台「设置」页，也可以在路由器上执行：
```
cat /etc/ai_relay/config.json | grep access_key
```

**Q：聊天时提示 HTTP 502 / 所有账号均不可用**
这是中转站那边所有上游账号都失败了，跟 App 无关。去后台「请求日志」看具体错误。

**Q：耗电/流量**
App 没有后台常驻、没有轮询。只有你打开 App 时才探测一次（内网 2 秒超时），平时零消耗。

---

## 技术说明（想改代码的人看）

```
Sources/
├── AIRelayChatApp.swift   App 入口 + 前后台切换重连 + SafariView
├── Settings.swift         配置持久化（UserDefaults）
├── RelayClient.swift      网络层：场景判定、Gist 降级、SSE 流式解析
├── ChatStore.swift        状态：对话、发送、重试
├── ChatView.swift         聊天界面
└── SettingsView.swift     设置界面
```

关键设计：
- **在家判定不用 WiFi SSID**，改用内网 `/health` 探测。因为读 SSID 需要定位权限，自签/巨魔环境经常拿不到，会直接导致功能失效。探测法零权限、100% 可靠。
- **SSE 逐字流式**：`URLSession.bytes(for:)` 按行读，边收边显示，不用等全部返回。
- **非流式兜底**：万一上游忽略 `stream: true`，自动补一次普通请求，保证不出现空白回答。
- **所有 settings 写操作走 `MainActor.run`**，避免 SwiftUI 后台线程改 `@Published` 导致的崩溃/不刷新。

## 打包

仓库根目录即工程目录，推上去 GitHub Actions 自动出 ipa。产物在 Actions → Build IPA → Artifacts。
