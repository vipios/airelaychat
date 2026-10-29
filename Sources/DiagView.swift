import SwiftUI
import UIKit

// MARK: - 诊断界面

/// 服务端正常但手机连不上时用这个页面定位。
/// 先看手机自己在哪个网（这一步不会被权限干扰），再看能不能访问内网，
/// 两者对照就能区分「没连 WiFi」「连错网」「权限被拒」。
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
                Text("会先读手机自己的 IP，再逐个探测内网地址、公网地址和 GitHub Gist。")
            }

            // 结论放最前面，用户最需要看这个
            if !diag.summary.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(diag.summary)
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if !diag.suggestion.isEmpty {
                            Text(diag.suggestion)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 3)

                    if diag.localNetworkDenied {
                        Button {
                            if let u = URL(string: UIApplication.openSettingsURLString) {
                                openURL(u)
                            }
                        } label: {
                            Label("打开本 App 设置", systemImage: "gear")
                        }
                    }
                } header: {
                    Text("结论")
                }
            }

            if !diag.rows.isEmpty {
                Section("探测明细") {
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
                                        .truncationMode(.middle)
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
                Text("自动探测失败时可以手填。诊断结论里如果提到同网段，就填那个网关地址。")
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
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if diag.rows.isEmpty { await diag.run() }
        }
    }
}
