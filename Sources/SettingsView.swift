import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var loadingModels = false
    @State private var gistResult: String?
    @State private var gistLoading = false
    @State private var showAdmin = false
    @State private var adminURL: URL?
    @State private var editing: Provider?

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                modelSection
                connectionSection
                publicSection
                adminSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdmin) {
                if let u = adminURL { SafariView(url: u) }
            }
            .sheet(item: $editing) { p in
                ProviderEditor(provider: p) { saved in
                    saveProvider(saved)
                }
            }
            .task { await refreshModels() }
        }
    }

    // MARK: 模型来源

    private var providerSection: some View {
        Section {
            ForEach(settings.providers) { p in
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
                Label("添加别家模型来源", systemImage: "plus.circle")
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
                TextField("8080", value: $settings.port, format: .number)
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
        } header: {
            Text("家里中转站")
        } footer: {
            Text("地址留空会自动试常见网段，哪个通用哪个并记住。密钥就是中转站后台的访问密钥。\n\n固定域名填中转站的公网域名（如 your.domain.com）。填了之后在外面优先走它，不依赖手机有没有 IPv6。")
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

    // MARK: 后台管理

    private var adminSection: some View {
        Section {
            Button {
                adminURL = URL(string: settings.lanBase)
                showAdmin = true
            } label: {
                Label("打开中转站后台", systemImage: "safari")
            }
            NavigationLink {
                DiagView()
            } label: {
                Label("连接诊断", systemImage: "stethoscope")
            }
        } header: {
            Text("管理")
        } footer: {
            Text("连不上的时候点「连接诊断」，它会告诉你卡在哪一步。")
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
        } footer: {
            Text("AIRelayChat · 家里的 AI 中转站客户端")
        }
    }

    // MARK: 动作

    private func refreshModels() async {
        loadingModels = true
        defer { loadingModels = false }
        await store.refreshModels()
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
            .navigationTitle(provider.isHome ? "家里中转站" : "模型来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var p = provider
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            p.name = p.isHome ? "家里中转站" : "未命名来源"
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
