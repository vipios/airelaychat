import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var gistResult: String?
    @State private var gistLoading = false
    @State private var showAdmin = false
    @State private var adminURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                modelSection
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
                if let u = adminURL {
                    SafariView(url: u)
                }
            }
            .task { await loadModels() }
        }
    }

    // MARK: 连接

    private var connectionSection: some View {
        Section {
            HStack {
                Text("家里路由器地址")
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
        } header: {
            Text("连接")
        } footer: {
            Text("地址留空会自动试常见网段，哪个通用哪个，并记住结果。密钥就是中转站后台的访问密钥，填一次就行。")
        }
    }

    // MARK: 模型

    private var modelSection: some View {
        Section {
            Picker("在家用", selection: $settings.homeModel) {
                Text("不指定（用界面选的）").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            Picker("在外用", selection: $settings.awayModel) {
                Text("不指定（用界面选的）").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            if loadingModels {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读取模型列表…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("模型（按场景自动切换）")
                Spacer()
                Button("刷新") { Task { await loadModels() } }
                    .font(.system(size: 12))
            }
        } footer: {
            Text("进软件时自动判断你在家还是在外面，然后自动用对应模型。不指定就跟随聊天界面里选的模型。")
        }
    }

    // MARK: 公网地址

    private var publicSection: some View {
        Section {
            if settings.publicAddrs.isEmpty {
                Text("还没有记录（在家连一次就会自动填）")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
                Text(r)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("公网地址")
        } footer: {
            Text("路由器的 IPv6 前缀可能被运营商换掉。它每 5 分钟把最新地址写进 Gist，这里点一下就能拉回来。平时不用管——连不上时软件会自动去拉。")
        }
    }

    // MARK: 后台管理

    private var adminSection: some View {
        Section {
            Button {
                openAdmin()
            } label: {
                Label("打开中转站后台", systemImage: "safari")
            }
            if let u = adminBase() {
                Text(u)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("管理")
        } footer: {
            Text("在家走内网地址，在外面走公网地址，自动选。")
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

    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        let r = await RelayClient.shared.resolve()
        guard let b = r.base else { return }
        if let list = try? await RelayClient.shared.models(base: b) {
            models = list.map(\.id).sorted()
        }
    }

    private func refreshFromGist() async {
        gistLoading = true
        gistResult = nil
        defer { gistLoading = false }
        if let g = await RelayClient.shared.fetchGistAddr(), let ips = g.ipv6, !ips.isEmpty {
            settings.publicAddrs = ips
            if let p = g.port, p > 0 { settings.port = p }
            gistResult = "已更新 \(ips.count) 个地址" + (g.updated.map { "（设备时间 \($0)）" } ?? "")
        } else {
            gistResult = "拉取失败：检查网络，或确认 Gist ID 是否正确"
        }
    }

    private func adminBase() -> String? {
        let lan = settings.lanBase
        if !settings.publicAddrs.isEmpty {
            return lan + "（或公网）"
        }
        return lan
    }

    private func openAdmin() {
        // 优先内网（快），没内网再用公网第一个地址
        let lan = settings.lanBase
        adminURL = URL(string: lan)
        showAdmin = true
    }
}
