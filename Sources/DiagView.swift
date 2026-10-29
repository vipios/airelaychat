import SwiftUI

// MARK: - 诊断界面

/// 服务端正常但手机连不上时用这个页面定位。
/// 每一步都显示真实耗时和原始错误，不用猜。
struct DiagView: View {
    @StateObject private var diag = Diagnostics()
    @ObservedObject var settings = Settings.shared
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await diag.run() }
                } label: {
                    HStack {
                        Label("开始诊断", systemImage: "play.circle.fill")
                        Spacer()
                        if diag.running { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(diag.running)
            } footer: {
                Text("会依次探测每个内网地址、公网地址和 GitHub Gist，把真实错误抓出来。")
            }

            if !diag.rows.isEmpty {
                Section {
                    ForEach(diag.rows) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(r.ok ? Color.green : Color.red)
                                Text(r.label)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if !r.target.isEmpty && r.target != "—" {
                                    Text(r.target)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if !r.detail.isEmpty {
                                Text(r.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("探测结果")
                } footer: {
                    if !diag.summary.isEmpty {
                        Text(diag.summary)
                            .foregroundStyle(.primary)
                    }
                }

                // 本地网络权限被拒是最常见的坑，单独给修复指引
                if diag.localNetworkDenied {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("本地网络权限可能被拒", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("iOS 第一次访问局域网会弹「是否允许查找本地网络设备」。点过「不允许」之后，系统会一直拦掉所有内网请求，而且不报明确错误。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("修复：设置 → 隐私与安全性 → 本地网络 → 找到「中转站」→ 打开开关。改完必须彻底退出 App 再进（从多任务里上滑划掉）。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            if let u = URL(string: UIApplication.openSettingsURLString) {
                                openURL(u)
                            }
                        } label: {
                            Label("打开本 App 设置", systemImage: "gear")
                        }
                    }
                }
            }

            // 手动指定地址：自动探测失败时的兜底
            Section {
                HStack {
                    Text("路由器地址")
                    Spacer()
                    TextField("自动", text: $settings.lanHost)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 13, design: .monospaced))
                }
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8080", value: $settings.port, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(width: 70)
                }
            } header: {
                Text("手动配置")
            } footer: {
                Text("自动探测失败时可以手填。比如直接用 192.168.1.88。")
            }

            if !diag.rows.isEmpty {
                Section {
                    Button {
                        UIPasteboard.general.string = diag.dump()
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制诊断结果",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("复制后发给我，我能直接看出问题在哪。")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自己排查的顺序").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(tips.enumerated()), id: \.offset) { i, t in
                        Text("\(i + 1). \(t)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if diag.rows.isEmpty { await diag.run() }
        }
    }

    private let tips = [
        "先确认手机连的是家里 WiFi，不是流量，也不是别的 WiFi。",
        "路由器的内网地址可能是 192.168.2.1，也可能是 192.168.1.88 / .250，三个都要能试到。",
        "如果提示「已中断」或全部超时，先检查本地网络权限。",
        "在外面要用公网直连，手机必须有 IPv6。有些公共 WiFi 没有 IPv6，会表现为连不上。",
        "在家连上了但在外面连不上，说明 IPv6 前缀变了，去「设置 → 公网地址 → 从 Gist 拉取」更新。",
    ]
}
