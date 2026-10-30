import SwiftUI

// MARK: - 语音按钮（点一下开始听，再点一下结束）

/// 参考图里这个位置是一枚声波图标（一个点 + 两道弧）`·))`，不是麦克风。
///
/// 2026-10-30 按用户要求从「按住说」改成「点一下开始、再点一下结束」：
///
/// 为什么改：按住这种交互在胶囊里很难受 —— 手指按着就不能点别的地方，
/// 而且用户按一下马上松手会被判成「说完了但没听到内容」。
/// 现在点一下开始听，说完可以再点一下停，或者静音 2.2 秒自己停。
///
/// 三个回调：
///   onFinish —— 最终文字（已经拼好开始前输入框里原有的内容）
///   onLive   —— 每一版中间结果，直接写进输入框，做出「边说边长字」的效果
///   onStarted—— 刚开始听（上层用它收起键盘）
struct HoldToTalkButton: View {
    @ObservedObject var voice: VoiceInput
    var disabled = false
    /// 点之前输入框里已有的文字。识别结果要接在它后面，不能把它冲掉。
    var existingText: String = ""

    let onFinish: (String) -> Void
    let onLive: (String) -> Void
    let onStarted: () -> Void

    var body: some View {
        Button {
            guard !disabled else { return }
            if voice.recording {
                voice.stop()
            } else {
                wire()
                onStarted()
                Task { await voice.start(prefix: existingText) }
            }
        } label: {
            ZStack {
                if voice.recording {
                    // 录音中：红点 + 呼吸圈，一眼看出"正在听"
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(disabled ? Theme.sub : Theme.inkSoft)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: voice.recording)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// 每次开始听之前把回调接上。
    /// 放在按钮动作里而不是 onAppear：回调要带上「这一次」的 existingText，
    /// 而 existingText 每次点的时候都可能不同。
    private func wire() {
        voice.onLive = { t in onLive(t) }
        voice.onFinish = { t in onFinish(t) }
    }
}
