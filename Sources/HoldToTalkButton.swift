import SwiftUI

// MARK: - 按住说话

/// 按住开始录音识别，松手把文字交回去。
///
/// 用 DragGesture(minimumDistance: 0) 而不是 LongPressGesture：
/// 后者要按住一定时间才触发，手感有延迟；而且松手事件不如拖拽手势可靠。
struct HoldToTalkButton: View {
    @ObservedObject var voice: VoiceInput
    var disabled = false
    let onText: (String) -> Void

    @State private var pressing = false
    /// 手指往上滑超过这个距离就取消，避免误发
    @State private var cancelled = false

    private let cancelDistance: CGFloat = 60

    var body: some View {
        // 参考图上这个位置是一枚声波图标（一个点 + 两道弧），不是麦克风：
        // `·))`。别用 mic —— 形状差得远，一眼就看出来不是原版。
        Image(systemName: voice.recording ? "waveform" : "dot.radiowaves.left.and.right")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .scaleEffect(voice.recording ? 1.1 : 1.0)
            .animation(.easeOut(duration: 0.12), value: voice.recording)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !disabled else { return }
                        if !pressing {
                            // pressing 是 @State，同步置位，onChanged 每帧连发也只会进一次
                            pressing = true
                            cancelled = false
                            voice.onFinish = { text in onText(text) }
                            Task { await voice.start() }
                        }
                        // 上滑取消：高度为负表示往上
                        if voice.recording {
                            let up = -g.translation.height
                            if up > cancelDistance, !cancelled {
                                cancelled = true
                                voice.cancel()
                            } else if up <= cancelDistance, cancelled {
                                // 滑回来了，重新开始
                                cancelled = false
                                Task { await voice.start() }
                            }
                        }
                    }
                    .onEnded { _ in
                        guard pressing else { return }
                        pressing = false
                        let wasCancelled = cancelled
                        cancelled = false
                        guard !disabled else { return }
                        // 取消过的不要再 stop（否则会把已经丢掉的结果又送一遍）
                        if !wasCancelled { voice.stop() }
                    }
            )
            .overlay(alignment: .top) {
                if voice.recording {
                    Text(cancelled ? "松开取消" : "松开发送 · 上滑取消")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(cancelled ? Color.red.opacity(0.85) : Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .fixedSize()
                        .offset(y: -34)
                        .allowsHitTesting(false)
                }
            }
    }

    private var color: Color {
        if cancelled { return .red }
        if voice.recording { return .red }
        // 平时用近黑（参考图里这枚图标是深色，不是灰的），禁用才退成灰
        return disabled ? Theme.sub : Theme.inkSoft
    }
}
