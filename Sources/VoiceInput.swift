import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - 语音转文字（按住说话）

/// 按住录音，松手把识别结果以文字形式交给上层。
///
/// 为什么用 SFSpeechRecognizer 而不是先录音再发：要「按住就说、松手出字」，
/// 边说边识别体验最好，也省去一次文件读写。识别走系统服务，不消耗中转站的额度。
@MainActor
final class VoiceInput: ObservableObject {
    /// 正在录
    @Published var recording = false
    /// 实时识别的中间结果（按住时显示）
    @Published var partial = ""
    /// 出错时的提示
    @Published var error: String?
    /// 权限被拒
    @Published var denied = false

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    /// 松手时回调，参数是最终文字。空字符串表示没识别出来。
    var onFinish: ((String) -> Void)?

    // MARK: 权限

    /// 麦克风 + 语音识别两套权限都要。任何一个是拒绝状态就返回 false。
    func ensurePermission() async -> Bool {
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else {
            denied = true
            error = "麦克风权限被拒。设置 → 隐私与安全性 → 麦克风 → 打开「中转站」。"
            return false
        }

        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizer.Status, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            denied = true
            switch speech {
            case .denied:
                error = "语音识别权限被拒。设置 → 隐私与安全性 → 语音识别 → 打开「中转站」。"
            case .restricted:
                error = "这台设备限制了语音识别。"
            case .notDetermined:
                error = "语音识别权限还没授予。"
            default:
                error = "语音识别不可用。"
            }
            return false
        }

        guard recognizer != nil, recognizer?.isAvailable == true else {
            error = "语音识别服务暂时不可用，稍后再试。"
            return false
        }
        return true
    }

    // MARK: 开始 / 结束

    func start() async {
        guard !recording else { return }
        error = nil
        partial = ""
        denied = false

        guard await ensurePermission() else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // measurement 模式会关掉系统降噪，识别率反而更高
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let eng = AVAudioEngine()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // 优先用设备端识别：快、且不上传音频
            if recognizer?.supportsOnDeviceRecognition == true {
                req.requiresOnDeviceRecognition = true
            }

            let node = eng.inputNode
            let fmt = node.outputFormat(forBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                req.append(buf)
            }

            eng.prepare()
            try eng.start()

            engine = eng
            request = req

            task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let r = result {
                        self.partial = r.bestTranscription.formattedString
                    }
                    if err != nil {
                        // 识别结束或出错；没拿到字就报个温和的提示
                        if self.partial.isEmpty { self.error = "没听清，再说一次？" }
                    }
                }
            }

            recording = true
        } catch {
            self.error = "录音启动失败：\(error.localizedDescription)"
            cleanup()
        }
    }

    /// 松手：结束识别，把最终文字回调出去
    func stop() {
        guard recording else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        recording = false

        request?.endAudio()
        // 给识别器一点时间吐出最后几个字，再收尾
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.cleanup()
            let final = self.partial.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = final.isEmpty ? text : final
            self.partial = ""
            if !out.isEmpty {
                self.onFinish?(out)
            } else if self.error == nil {
                self.error = "没听清，再说一次？"
            }
        }
    }

    /// 用户中途取消（比如手指滑开了）
    func cancel() {
        guard recording else { return }
        recording = false
        partial = ""
        cleanup()
    }

    private func cleanup() {
        if let e = engine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                     options: .notifyOthersOnDeactivation)
    }
}
