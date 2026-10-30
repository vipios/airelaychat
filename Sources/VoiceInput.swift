import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - 语音转文字（点一下开始听，再点一下结束）

/// 点一下开始听，再点一下结束（或静音一段时间自动结束），
/// 边说边把识别到的文字**实时写进输入框**。
///
/// 2026-10-30 按用户要求重做。上一版的三个问题：
///
/// **1. 「已经说话了还显示没听清」**
/// 原因有两个：
///   a) `requiresOnDeviceRecognition = true` 被无脑打开。zh-CN 的设备端模型
///      在部分机型上根本不存在，一开就立刻报错，一个字都拿不到。
///   b) 松手后只等 350ms 就取最终结果，长句子最后几个字还没吐出来就判了「空」。
/// 现在：不再强制设备端（让系统自己选）、收尾等 1.2 秒、
/// 而且**只要有过任何 partial 就绝不报「没听清」**。
///
/// **2. 「识别出来的字只显示在胶囊里，没法编辑」**
/// 上一版把实时文字放在 `partial` 这个独立变量里，跟输入框是两套东西。
/// 现在 `onLive` 回调把每一版识别结果直接推给输入框，用户看到的就是
/// 输入框里在长字，随时能打断、能改。
///
/// **3. 「点输入框不弹键盘」**
/// 上一版录音时把整个输入栏替换成了「正在听…」，输入框被移出视图，
/// 焦点自然就丢了。现在输入栏结构不变，只改图标和指示灯。
@MainActor
final class VoiceInput: ObservableObject {
    /// 正在录（麦克风已开、识别已开始）
    @Published var recording = false
    /// 实时识别的中间结果（用于界面显示，也用于结束时兜底）
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
    /// 每次启动递增，回调里比对不上就丢弃（防止上一轮的迟到结果污染这一轮）
    private var generation = 0
    /// 本次录音是否真的收到过识别文字
    private var gotAnyText = false
    /// 静音自动结束：最后一次拿到文字的时间
    private var lastTextAt: Date = Date()
    private var silenceTimer: Timer?

    /// 静音多久自动结束。给 2.2 秒：说话时正常换气也就 0.5~1 秒，
    /// 2.2 秒没新字基本就是讲完了，比让用户手动点第二下更省事。
    private let silenceLimit: TimeInterval = 2.2

    /// 每次识别到新文字就回调（实时写进输入框）
    var onLive: ((String) -> Void)?
    /// 结束时回调最终文字。空字符串表示确实没识别到（这时界面不该弹错，
    /// 用户可能只是点了一下没说话）。
    var onFinish: ((String) -> Void)?

    /// 本轮开始前输入框里已有的文字。实时回调要拼在它后面，
    /// 否则识别一开口就会把用户之前打的字整个冲掉。
    private var baseText = ""

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

    /// 开始听。`prefix` 是输入框里已有的文字，识别结果会接在它后面。
    func start(prefix: String = "") async {
        // 这两行是同步的，能挡住手势的连发
        guard !starting, !recording else { return }
        starting = true
        generation += 1
        let gen = generation

        error = nil
        partial = ""
        denied = false
        gotAnyText = false
        lastTextAt = Date()
        baseText = prefix

        // 上一轮如果还留了东西，先彻底清掉（避免 tap 叠加导致重复识别）
        teardown()

        defer {
            // 走到这里说明启动流程结束（无论成功失败）
            if generation == gen { starting = false }
        }

        guard await ensurePermission() else { return }
        // 等权限期间用户可能已经再点了一下（想取消）
        guard generation == gen else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // measurement 模式会关掉系统降噪，识别率反而更高
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let eng = AVAudioEngine()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // 不再强制 requiresOnDeviceRecognition。
            // 强制端侧的后果是：机型上没有 zh-CN 端侧模型时直接报错，
            // 一个 partial 都拿不到 —— 就是用户说的「说了话还说没听清」。
            // 交给系统自己决定：有端侧用端侧，没有就走服务器。

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
                        let text = r.bestTranscription.formattedString
                        if !text.isEmpty {
                            self.gotAnyText = true
                            self.lastTextAt = Date()
                            self.partial = text
                            // 实时写进输入框：用户看到的就是"边说边长字"
                            self.onLive?(self.join(text))
                        }
                        // 识别器自己说结束了（比如检测到长停顿），主动收尾
                        if r.isFinal, self.recording {
                            self.stop()
                            return
                        }
                    }

                    if err != nil {
                        // 关键修正：**有字就不报错**。
                        // SFSpeechRecognizer 在"录音结束/静音"时经常带一个
                        // err 回调出来，那不代表失败。上一版只要 err 就判空，
                        // 于是明明识别到了还弹「没听清」。
                        if self.recording, !self.gotAnyText, self.partial.isEmpty {
                            // 真的一个字都没有：不弹错，安静收尾。
                            self.stop()
                        }
                    }
                }
            }

            recording = true
            startSilenceWatch(gen)

        } catch {
            self.error = "录音启动失败：\(error.localizedDescription)"
            teardown()
        }
    }

    /// 把识别结果接在原有文字后面
    private func join(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return t }
        // 中文不需要空格，英文/数字之间补一个
        if baseText.hasSuffix(" ") || baseText.hasSuffix("\n") { return baseText + t }
        return baseText + " " + t
    }

    /// 静音看门狗：一段时间没有新文字就自动结束。
    ///
    /// 为什么需要它：用户说完话不一定会再点一下图标（第一版是按住说的，
    /// 习惯还没改过来）。有这个兜底，"说完了字就停在那儿"，不会一直录着耗电。
    ///
    /// 并发写法注意（2026-10-30 编译报错过）：
    /// 不能在 Timer 闭包里先 `[weak self]` 再在 `Task { @MainActor in }`
    /// 里用那个 self —— 捕获的 weak 变量跨进并发闭包会被判为
    /// "reference to captured var 'self' in concurrently-executing code"。
    /// 正解：把 weak 直接标在 Task 闭包上，让弱引用本身在 MainActor 里解包。
    private func startSilenceWatch(_ gen: Int) {
        silenceTimer?.invalidate()
        // 先把参数拷成不可变局部量，避免闭包直接引用函数参数
        // （在并发上下文里引用外层可变绑定会被编译器拦下）
        let targetGen = gen
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.recording, self.generation == targetGen else { return }
                // 一直没字的不自动收（用户可能还在组织语言，或权限框刚点完）
                guard self.gotAnyText else { return }
                if Date().timeIntervalSince(self.lastTextAt) >= self.silenceLimit {
                    self.stop()
                }
            }
        }
    }

    /// 结束：把最终文字交给上层
    func stop() {
        guard recording else { return }
        recording = false
        silenceTimer?.invalidate()
        silenceTimer = nil

        let gen = generation
        let snapshot = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadText = gotAnyText

        request?.endAudio()

        // 给识别器时间吐最后几个字。
        // 350ms 太短了（上一版就是这么丢字的），1.2 秒更稳；
        // 这期间界面已经把字填进输入框了，用户感觉不到在等。
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.generation == gen else { return }
            self.teardown()

            let final = self.partial.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = final.isEmpty ? snapshot : final
            self.partial = ""

            if !out.isEmpty {
                self.onFinish?(self.join(out))
            } else if !hadText {
                // 一个字都没有 —— 不报「没听清」。
                // 多数情况是点错了或环境太吵，安静收场比红字友好。
                self.error = nil
            }
        }
    }

    /// 用户中途取消
    func cancel() {
        guard recording else { return }
        recording = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        partial = ""
        generation += 1   // 让这一轮的迟到回调全部失效
        teardown()
    }

    private func teardown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
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
