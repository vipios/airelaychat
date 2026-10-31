import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store: ChatStore
    /// true = 作为「我的」页内嵌显示（没有导航栏、没有"完成"按钮）。
    /// 为什么要这个开关：同一个界面有两个入口 —— 抽屉底部点"设置"是弹窗（需要关闭按钮），
    /// 底部 Tab「我的」是整页（不需要关闭按钮，那一行会显得多余）。
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var loadingModels = false
    @State private var gistResult: String?
    @State private var gistLoading = false
    @State private var editing: Provider?

    // 重启路由器
    @State private var devStatus: DeviceStatus?
    @State private var devLoading = false
    @State private var devMsg: String?
    @State private var confirmReboot = false
    @State private var rebooting = false
    /// 重启后进入"等它回来"的倒计时状态
    @State private var waitingBack = false
    /// 后台密钥（access_key）的输入草稿。落盘走钥匙串，见 body 里的 onChange。
    @State private var adminKeyDraft = AdminKey.load()

    /// 长按某个来源 → 改名。用 alert 是因为 iOS 的 contextMenu 里
    /// 不能内嵌输入框，改名只能另开一层。
    @State private var renameTarget: Provider?
    @State private var nameDraft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 内嵌到「我的」Tab 时，自己画一个和聊天页同款的大标题。
                // 为什么不用 navigationTitle：inline 模式会把「我的」压成
                // 17pt 居中细字 + 一条导航栏底色，和演示图里左对齐的
                // 粗体标题完全不是一个观感；large 模式又会在滚动时变形。
                if embedded {
                    HStack {
                        Text("我的")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    // 顶部 14：和后台面板页保持同一个视觉基线
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                }

                Form {
                    providerSection
                    currentLinkSection
                    modelSection
                    connectionSection
                    deviceSection
                    publicSection
                    aboutSection
                }
                // Form 自带一层不透明底色，会把 Theme.page 盖掉，
                // 表现为"上半截灰、下半截白"的断层。
                .scrollContentBackground(.hidden)
                .background(Theme.page)
            }
            .background(Theme.page)
            .navigationTitle(embedded ? "" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
            .sheet(item: $editing) { p in
                ProviderEditor(provider: p) { saved in
                    saveProvider(saved)
                }
            }
            // 点「重启路由器」先弹这个确认框，确认才真的重启。
            // 用 alert 而不是 ActionSheet：这是不可撤销的破坏性操作，
            // 居中的系统弹窗比底部弹出的菜单更容易让人看清文字、不容易误触。
            .alert("重启路由器？", isPresented: $confirmReboot) {
                Button("取消", role: .cancel) {}
                Button("确认重启", role: .destructive) {
                    Task { await doReboot() }
                }
            } message: {
                Text("中转站会断开约 40 秒，正在进行的对话会中断。\n\n只在卡住不响应、后台几十秒才出来的时候才需要。")
            }
            // 长按来源 → 改名
            .alert("给来源改名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("名称", text: $nameDraft)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") { commitRename() }
            } message: {
                Text("只改显示名，地址和密钥不变。")
            }
            .task { await refreshModels() }
            .task { await loadDevice() }
        }
    }

    // MARK: 模型来源

    private var providerSection: some View {
        Section {
            ForEach(settings.providers) { p in
                // 点按 = 切到这家；长按 = 弹菜单（改名 / 执行 / 编辑 / 删除）。
                // 用户原话「点击和长按都有各自的功能」，两者都要有。
                Button {
                    Task { await store.switchProvider(p.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.isHome ? "house.fill" : "cloud.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(p.isHome ? Color.blue : Color.purple)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Text(subtitle(p))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if p.id == settings.activeProvider {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .contextMenu {
                    Button {
                        renameTarget = p
                        nameDraft = p.name
                    } label: {
                        Label("改名", systemImage: "pencil")
                    }
                    Button {
                        Task { await store.switchProvider(p.id) }
                    } label: {
                        Label("执行（切到这家）", systemImage: "arrow.right.circle")
                    }
                    Button {
                        editing = p
                    } label: {
                        Label("编辑地址和密钥", systemImage: "gearshape")
                    }
                    if !p.isHome {
                        Divider()
                        Button(role: .destructive) {
                            deleteProvider(p)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        editing = p
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)

                    if !p.isHome {
                        Button(role: .destructive) {
                            deleteProvider(p)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                editing = Provider(name: "", isHome: false, baseURL: "", apiKey: "")
            } label: {
                Label("添加供应商", systemImage: "plus.circle")
            }
        } header: {
            Text("模型来源")
        } footer: {
            Text("点一行切换当前来源，左滑可编辑。除了家里的中转站，还能直接接 OpenAI、DeepSeek、Claude 或任意 OpenAI 兼容站点，填服务器地址和密钥即可。")
        }
    }

    private func subtitle(_ p: Provider) -> String {
        if p.isHome {
            return "\(settings.lanCandidates.first ?? "")… · \(p.models.count) 个模型"
        }
        let host = p.baseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return host + " · \(p.models.count) 个模型"
    }

    private func saveProvider(_ p: Provider) {
        if let i = settings.providers.firstIndex(where: { $0.id == p.id }) {
            settings.providers[i] = p
        } else {
            settings.providers.append(p)
        }
        Task { await store.refreshModels() }
    }

    private func deleteProvider(_ p: Provider) {
        settings.providers.removeAll { $0.id == p.id }
        if settings.activeProvider == p.id {
            settings.activeProvider = settings.providers.first?.id ?? ""
            Task { await store.bootstrap() }
        }
    }

    private func commitRename() {
        guard var p = renameTarget else { return }
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !n.isEmpty, n != p.name else { return }
        p.name = n
        settings.updateProvider(p)
    }

    // MARK: 模型

    private var modelSection: some View {
        Section {
            Picker("在家用", selection: $settings.homeModel) {
                Text("不指定（用界面选的）").tag("")
                ForEach(store.models) { Text($0.display).tag($0.id) }
            }
            Picker("在外用", selection: $settings.awayModel) {
                Text("不指定（用界面选的）").tag("")
                ForEach(store.models) { Text($0.display).tag($0.id) }
            }
            if loadingModels {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读取模型列表…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await refreshModels() }
            } label: {
                Label("刷新模型列表", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("模型（按场景自动切换）")
        } footer: {
            Text("进软件时自动判断你在家还是在外面，然后自动用对应模型。不指定就跟随聊天界面里选的模型。")
        }
    }

    // MARK: 家里的连接

    private var connectionSection: some View {
        Section {
            HStack {
                Text("路由器地址")
                Spacer()
                TextField("自动检测", text: $settings.lanHost)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            HStack {
                Text("端口")
                Spacer()
                // 用 .number.grouping(.never) 而不是 .number：
                // 默认格式化会按本地化加千位分隔符，8080 会显示成「8,080」——
                // 端口号是个标识符，不是数量，加逗号既难看也容易让人误以为能改。
                TextField("8080", value: $settings.port,
                          format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
            }
            HStack {
                Text("访问密钥")
                Spacer()
                SecureField(settings.gatewayKey.isEmpty ? "sk-…" : "已保存（可改）",
                            text: $settings.gatewayKey)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            HStack {
                Text("固定域名")
                Spacer()
                TextField("在外面用", text: $settings.publicDomain)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            // 中转站有**两把不同的钥匙**，这里必须分开填：
            //   访问密钥（上面那个）= 网关 Key，形如 sk-relay-…，只能调 /v1 模型
            //   后台密钥（这一行）  = access_key，就是打开网页后台时输的密码，
            //                         /admin/api/* 只认这把
            // 之前只有一把输入框，重启必然 401 —— 用户看到的就是
            // 「读取失败：需要访问密钥 (access_key)」，但他明明填了密钥。
            HStack {
                Text("后台密钥")
                Spacer()
                SecureField(adminKeyDraft.isEmpty ? "网页后台的登录密码" : "已保存（可改）",
                            text: $adminKeyDraft)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: adminKeyDraft) { v in
                        // 存钥匙串，和「后台面板」共用同一条记录 ——
                        // 在哪边填过，另一边就自动能用，不用填两次。
                        AdminKey.save(v)
                    }
            }

            // 已记住的内网地址。
            //
            // 2026-10-31 用户要求「彻底解决连不上」：把 App 学到的东西摊开给用户看。
            // 出问题时一眼能知道它记住了哪些地址、是不是记了个已经作废的，
            // 而不是只能干等着看「连接中…」。
            if !settings.lanPool.isEmpty {
                HStack(alignment: .top) {
                    Text("已记住")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(settings.lanPool, id: \.self) { ip in
                            Text(ip)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(role: .destructive) {
                    // 万一记了一堆作废地址（比如搬了家、换了路由器），
                    // 给一个一键清空的出口，让 App 从干净状态重新学。
                    settings.lanPool = []
                    settings.lastLanBase = ""
                } label: {
                    Text("清空记住的地址")
                        .font(.system(size: 14))
                }
            }
        } header: {
            Text("家里中转站")
        } footer: {
            Text("地址留空会自动找：先试记住过的地址，再按当前 WiFi 网段推，最后把整个网段扫一遍，哪个通用哪个并记住。\n\n固定域名填中转站的公网域名（如 your.domain.com）。填了之后在外面优先走它，不依赖手机有没有 IPv6。\n\n「访问密钥」是给聊天用的网关 Key（sk-…）；「后台密钥」是打开网页后台时输的密码，重启路由器要用它，两个不一样。")
        }
    }

    // MARK: 公网地址

    private var publicSection: some View {
        Section {
            if settings.publicAddrs.isEmpty {
                Text("还没有记录（在家连一次就会自动填）")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ForEach(settings.publicAddrs, id: \.self) { ip in
                    Text(ip)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Text("Gist ID")
                Spacer()
                TextField("自动上报用", text: $settings.gistId)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 12, design: .monospaced))
            }
            Button {
                Task { await refreshFromGist() }
            } label: {
                HStack {
                    Text("从 Gist 拉取最新地址")
                    Spacer()
                    if gistLoading { ProgressView().scaleEffect(0.8) }
                }
            }
            .disabled(gistLoading || settings.gistId.isEmpty)
            if let r = gistResult {
                Text(r).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } header: {
            Text("公网地址")
        } footer: {
            Text("路由器的 IPv6 前缀可能被运营商换掉。它每 5 分钟把最新地址写进 Gist，连不上时软件会自动去拉。")
        }
    }

    // MARK: 当前连接

    private var linkStateText: String {
        if store.detecting && store.base == nil { return "连接中…" }
        if store.base == nil { return "没连上" }
        switch store.place {
        case .home: return "在家（内网直连）"
        case .away: return "在外（域名）"
        case .unknown: return "已连接"
        }
    }

    private var currentLinkSection: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                Text(linkStateText)
                    .font(.system(size: 13))
                    .foregroundStyle(store.base == nil ? Color.orange : Color.green)
            }
            if let b = store.base {
                HStack(alignment: .top) {
                    Text("正在用")
                    Spacer()
                    Text(b)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            Button {
                // 清掉所有缓存，逼它从零开始找一遍。
                //
                // 2026-10-31：现在这条路会一路退到底 ——
                //   记住的地址 → 当前网段推导 → **整个网段扫 254 个地址**。
                // 所以这个按钮就是「不管路由器换成什么网段都给我找出来」的开关。
                // 换了 WiFi、光猫改了网段、搬了家、或者出门很久再回来都用它。
                settings.lastLanBase = ""
                settings.lastPubBase = ""
                Task { await store.bootstrap() }
            } label: {
                HStack {
                    Label("彻底重查连接", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if store.detecting { ProgressView().scaleEffect(0.8) }
                }
            }
            .disabled(store.detecting)
        } header: {
            Text("当前连接")
        } footer: {
            Text("打开软件时会自动判断：连家里 WiFi 走内网直连，否则走固定域名。\n\n点了没反应或一直「连接中」的时候按上面那个按钮 —— 它会清掉旧地址，把整个网段扫一遍重新找，一般十几秒内就有结果。")
        }
    }

    // MARK: 设备（重启路由器）
    //
    // 原来这一栏叫「管理」，里面是「打开中转站后台 + 连接诊断」。
    // 2026-10-30 按用户要求删掉了：
    //   - 后台面板已经在底部 Tab 里了，这里再放一个入口是重复的
    //   - 现在改成一键重启，这才是手机端真正需要的运维操作

    private var deviceSection: some View {
        Section {
            if let d = devStatus {
                HStack {
                    Text("已运行")
                    Spacer()
                    Text(d.uptimeText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("可用内存")
                    Spacer()
                    Text(d.memText)
                        .font(.system(size: 13))
                        .foregroundStyle(d.memAvailKB < 3000 ? Color.red : Color.secondary)
                }
                HStack {
                    Text("负载")
                    Spacer()
                    Text(d.loadText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle((d.load.first ?? 0) > 8 ? Color.red : Color.secondary)
                }
                if d.swapTotalKB > 0 {
                    HStack {
                        Text("交换区已用")
                        Spacer()
                        Text("\(d.swapUsedPct)%")
                            .font(.system(size: 13))
                            .foregroundStyle(d.swapUsedPct >= 95 ? Color.red : Color.secondary)
                    }
                }
                // 只在该重启的时候才提示，平时不啰嗦
                if d.shouldReboot {
                    Label("内存紧张，建议重启一次", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
            } else if devLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读取设备状态…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                confirmReboot = true
            } label: {
                HStack {
                    // 重启中/等待恢复时不显示图标，避免和转圈叠在一起
                    if rebooting || waitingBack {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "power")
                    }
                    Text(rebooting ? "正在发送重启指令…"
                         : (waitingBack ? "等待设备恢复…" : "重启路由器"))
                    Spacer()
                }
            }
            .disabled(rebooting || waitingBack)

            if let m = devMsg {
                Text(m)
                    .font(.system(size: 12))
                    // 三元的两个分支必须是同一具体类型。
                    // .secondary 是 ShapeStyle 的静态成员、.red 是 Color，
                    // 混着写编译器推不出来（会报 "type 'any ShapeStyle' cannot conform"）。
                    .foregroundStyle(waitingBack ? Color.secondary : Color.red)
            }
        } header: {
            Text("设备")
        } footer: {
            Text("重启指令直接发给路由器，**不经过中转站** —— 中转站卡死、打不开后台的时候照样能重启。\n重启后约 40 秒自动恢复，App 会自己重新连上。")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        }
        // 原来的 footer「AIRelayChat · 家里的 AI 中转站客户端」已按用户要求删掉
    }

    // MARK: 动作

    private func refreshModels() async {
        loadingModels = true
        defer { loadingModels = false }
        await store.refreshModels()
    }

    // MARK: 设备状态 / 重启

    private func loadDevice() async {
        // 先看有没有后台密钥。没有就别发请求了 ——
        // 发了必定 401，用户看到「需要访问密钥 (access_key)」也不知道填在哪。
        guard !settings.accessKey.isEmpty else {
            devMsg = "还差后台密钥：在上面「家里中转站」里填后台密钥（就是打开网页后台时输的密码）"
            return
        }
        // 拿当前能用的地址。store.base 是「上次探测成功的地址」，
        // 探过就用它；没探过就先 bootstrap 一次，否则一定是空的。
        if store.base == nil { await store.bootstrap(loadModels: false) }
        guard let b = store.base else {
            devMsg = "中转站暂时连不上（后台可能打不开），但「重启路由器」照样能用 —— 那条指令是直连路由器的。"
            return
        }
        devLoading = true
        defer { devLoading = false }
        do {
            devStatus = try await RelayClient.shared.deviceStatus(base: b, key: settings.accessKey)
            devMsg = nil
        } catch {
            devMsg = authHint(error)
        }
    }

    private func doReboot() async {
        guard !settings.accessKey.isEmpty else {
            devMsg = "还差后台密钥，填了才能重启"
            return
        }
        rebooting = true
        defer { rebooting = false }

        // ── 第一步：走路由器的独立通道（不经过中转站）──
        //
        // 这条路径的意义：中转站是最会卡死的那个东西，路由卡了想重启、
        // 中转站也卡着，指令就永远发不出去。uhttpd 是 C 进程，和中转站
        // 无关，中转站整个停掉也能应答（已实测）。
        devMsg = "正在找路由器…"
        var hosts = settings.lanCandidates
        if !settings.bootHost.isEmpty { hosts.insert(settings.bootHost, at: 0) }

        if let host = await BootChannel.discover(candidates: hosts) {
            settings.bootHost = host          // 记住这条通的路，下次先用它
            do {
                try await BootChannel.reboot(host: host, key: settings.accessKey)
                devMsg = "重启指令已直接从路由器发出，约 40 秒后恢复…"
                waitingBack = true
                store.markRebooting()
                Task {
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    waitingBack = false
                    store.clearRebooting()
                    await store.bootstrap()
                    await loadDevice()
                    if devStatus != nil { devMsg = "设备已恢复" }
                }
                return
            } catch {
                // 通道在、但指令被拒（多半是密钥不对），如实报出来，别偷偷退回中转站
                if let e = error as? BootError, case .badKey = e {
                    devMsg = "后台密钥不对，重启被路由器拒绝"
                    return
                }
                devMsg = "直连通道没发成功，改走中转站…"
            }
        }

        // ── 第二步：退回到中转站（在外面没开 ZeroTier 时只能靠它）──
        guard let b = store.base else {
            devMsg = "连不上路由器：不在家里 WiFi 时请开 ZeroTier，或先用网页后台重启"
            return
        }
        do {
            devMsg = "正在通过中转站发重启指令…"
            try await RelayClient.shared.rebootDevice(base: b, key: settings.accessKey)
            // 指令已受理，设备 2 秒后真的重启，接下来约 40 秒会连不上。
            // 这里不干等，而是给个软提示 + 60 秒后自动刷一次状态，
            // 用户体验上就是"点完切出去干别的，回来它已经好了"。
            waitingBack = true
            devMsg = "已发送重启指令，约 40 秒后恢复…"
            // 立刻把连接灯翻成灰，表示"这会是我主动弄断的，不是故障"
            store.markRebooting()
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                waitingBack = false
                // 45 秒后重新探一次，把 base 和灯恢复过来
                store.clearRebooting()
                await store.bootstrap()
                await loadDevice()
                if devStatus != nil {
                    devMsg = "设备已恢复"
                }
            }
        } catch {
            devMsg = authHint(error)
        }
    }

    /// 把错误翻成「该去改哪里」。
    ///
    /// 401 是最容易让人迷惑的一种：用户明明填了「访问密钥」，
    /// 却被告知需要 access_key —— 因为那本来是**两把不同的钥匙**。
    /// 所以这里必须点名让他去填「后台密钥」，否则他会一直重试同一个框。
    private func authHint(_ e: Error) -> String {
        let raw = friendly(e)
        if raw.contains("access_key") || raw.contains("访问密钥") || raw.contains("401") {
            return "后台密钥不对或没填：在上面「家里中转站 → 后台密钥」里填网页后台的登录密码（不是 sk- 开头的网关 Key）"
        }
        return "操作失败：\(raw)"
    }

    private func friendly(_ e: Error) -> String {
        if let r = e as? RelayError {
            // RelayError.http 的第二个参数已经是我们翻好的人话
            // （服务端返回的 error.message，或 401/403/429 的中文说明）
            if case .http(_, let msg) = r, !msg.isEmpty {
                return msg
            }
            return r.errorDescription ?? "\(r)"
        }
        return e.localizedDescription
    }

    private func refreshFromGist() async {
        gistLoading = true
        gistResult = nil
        defer { gistLoading = false }
        if let g = await RelayClient.shared.fetchGistAddr(),
           let ips = g.ipv6, !ips.isEmpty {
            settings.publicAddrs = ips
            if let p = g.port, p > 0 { settings.port = p }
            gistResult = "已更新 \(ips.count) 个地址"
                + (g.updated.map { "（设备时间 \($0)）" } ?? "")
        } else {
            gistResult = "拉取失败：检查网络，或确认 Gist ID 是否正确"
        }
    }
}

// MARK: - 来源编辑器

struct ProviderEditor: View {
    @State var provider: Provider
    let onSave: (Provider) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false
    @State private var showCaps = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("名称")
                        Spacer()
                        TextField("比如 DeepSeek 官方", text: $provider.name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    if !provider.isHome {
                        HStack {
                            Text("服务器地址")
                            Spacer()
                            TextField("https://api.deepseek.com", text: $provider.baseURL)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 13))
                        }
                        HStack {
                            Text("密钥")
                            Spacer()
                            SecureField("sk-…", text: $provider.apiKey)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                    Toggle("启用", isOn: $provider.enabled)
                } header: {
                    Text("基本信息")
                } footer: {
                    if provider.isHome {
                        Text("家里的中转站，地址和密钥在上一页填。")
                    } else {
                        Text("填 OpenAI 兼容的地址即可，末尾带不带 /v1 都行。密钥只存在这台手机上。")
                    }
                }

                if !provider.isHome {
                    Section {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                Text("测试连接")
                                Spacer()
                                if testing { ProgressView().scaleEffect(0.8) }
                            }
                        }
                        .disabled(testing || provider.baseURL.isEmpty)
                        if let r = testResult {
                            Text(r).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("验证")
                    }
                }

                // 模型能力：中转站不返回，只能按名字猜，猜错了让用户改
                if !provider.models.isEmpty {
                    Section {
                        NavigationLink {
                            CapEditor(provider: $provider)
                        } label: {
                            HStack {
                                Text("模型能力")
                                Spacer()
                                Text("\(provider.models.count) 个")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("高级")
                    } footer: {
                        Text("软件按模型名自动判断能不能看图/视频。判断错了在这里手动改。")
                    }
                }
            }
            .navigationTitle(provider.isHome ? "家里中转站" : (provider.name.isEmpty ? "添加供应商" : provider.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var p = provider
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            p.name = p.isHome ? "家里中转站" : "新供应商"
                        }
                        onSave(p)
                        dismiss()
                    }
                    .disabled(!provider.isHome && provider.baseURL.isEmpty)
                }
            }
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }

        var b = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.lowercased().hasPrefix("http") { b = "https://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }

        do {
            let list = try await RelayClient.shared.models(base: b, key: provider.apiKey)
            provider.models = list.map(\.id)
            testResult = "连接成功，读到 \(list.count) 个模型"
        } catch {
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 能力编辑

struct CapEditor: View {
    @Binding var provider: Provider

    var body: some View {
        Form {
            Section {
                ForEach(provider.models, id: \.self) { m in
                    HStack {
                        Text(short(m))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Picker("", selection: binding(for: m)) {
                            Text("文本").tag(ModelCap.text)
                            Text("看图").tag(ModelCap.image)
                            Text("视频").tag(ModelCap.video)
                            Text("图+视频").tag(ModelCap.media)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } footer: {
                Text("默认按模型名自动判断。这里的修改只影响这台手机上显示和拦截逻辑。")
            }
        }
        .navigationTitle("模型能力")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 没手动改过就用自动推断值作为初始选中
    private func binding(for m: String) -> Binding<ModelCap> {
        Binding(
            get: { provider.capOverrides[m] ?? CapInfer.infer(m) },
            set: { provider.capOverrides[m] = $0 }
        )
    }

    private func short(_ m: String) -> String {
        if let i = m.firstIndex(of: "|") { return String(m[m.index(after: i)...]) }
        return m
    }
}
