import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - 语音转文字（按住说话）

/// 按住录音，松手把识别结果以文字形式交给上层。
///
/// 为什么用 SFSpeechRecognizer 而不是先录音再发：要「按住就说、松手出字」，
/// 边说边识别体验最好，也省去一次文件读写。识别走系统服务，不消耗中转站的额度。
///
/// ## 2026-10-29 修的两个 bug
///
/// **1. 识别结果重复（说一句"喂"出来"喂喂喂喂"）**
/// 根因是 `start()` 里 `recording` 是在最后才置 true，而这之前有
/// `await ensurePermission()` 的异步等待。按钮的 onChanged 每帧都触发，
/// 于是这个守卫形同虚设 —— 一次按住会真的启动好几个 AVAudioEngine，
/// 每个都往自己的识别请求里塞同一段麦克风数据，识别器就听到了 N 遍。
/// 现在用 `starting` 同步置位堵死并发，并用 `generation` 让过期回调失效。
///
/// **2. 权限弹窗期间松手，麦克风停不下来**
/// `stop()` 里 `guard recording` 会在 start 还没完成时直接返回，
/// 之后 start 完成把 recording 置 true，录音就一直开着。
/// 现在 stop 会先记 `pendingStop`，start 一完成立刻自我收尾。
@MainActor
final class VoiceInput: ObservableObject {
    /// 正在录（麦克风已开、识别已开始）
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

    /// 启动流程进行中（含等待权限）。同步置位，用来挡住重复启动。
    private var starting = false
    /// 启动还没完成时用户就松手了
    private var pendingStop = false
    /// 每次启动递增，回调里比对不上就丢弃（防止上一轮的迟到结果污染这一轮）
    private var generation = 0

    /// 松手时回调，参数是最终文字。空字符串表示没识别出来。
    var onFinish: ((String) -> Void)?

    // MARK: 权限

    /// 麦克风 + 语音识别两套权限都要。任何一个是拒绝状态就返回 false。
    private func ensurePermission() async -> Bool {
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else {
            denied = true
            error = "麦克风权限被拒。设置 → 隐私与安全性 → 麦克风 → 打开「中转站」。"
            return false
        }

        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
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
        // 这两行是同步的，能挡住 onChanged 的连发
        guard !starting, !recording else { return }
        starting = true
        pendingStop = false
        generation += 1
        let gen = generation

        error = nil
        partial = ""
        denied = false

        // 上一轮如果还留了东西，先彻底清掉（避免 tap 叠加导致重复识别）
        teardown()

        defer {
            // 走到这里说明启动流程结束（无论成功失败）
            if generation == gen { starting = false }
        }

        guard await ensurePermission() else { return }
        // 等权限期间用户可能已经松手
        guard generation == gen, !pendingStop else { return }

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
                    guard let self = self, self.generation == gen else { return }
                    if let r = result {
                        self.partial = r.bestTranscription.formattedString
                    }
                    if err != nil {
                        // 识别结束或出错；没拿到字就报个温和的提示
                        if self.partial.isEmpty, self.recording {
                            self.error = "没听清，再说一次？"
                        }
                    }
                }
            }

            recording = true

            // 关键：启动期间用户已经松手了，这里立刻自我收尾
            if pendingStop {
                pendingStop = false
                stop()
            }
        } catch {
            self.error = "录音启动失败：\(error.localizedDescription)"
            teardown()
        }
    }

    /// 松手：结束识别，把最终文字回调出去
    func stop() {
        // 还在启动（比如权限弹窗）——记下来，start 完成时会自动收尾
        if starting && !recording {
            pendingStop = true
            return
        }
        guard recording else { return }

        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        recording = false
        let gen = generation

        request?.endAudio()
        // 给识别器一点时间吐出最后几个字，再收尾
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            // 这期间用户又按下了新的一轮，就别清掉新的状态
            guard self.generation == gen else { return }
            self.teardown()
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
        if starting && !recording {
            pendingStop = true
            return
        }
        guard recording else { return }
        recording = false
        partial = ""
        generation += 1   // 让这一轮的迟到回调全部失效
        teardown()
    }

    private func teardown() {
        if let e = engine {
            if e.isRunning { e.stop() }
            // removeTap 在没装过 tap 时会抛异常，判一下更稳
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
