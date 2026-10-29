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
        Image(systemName: voice.recording ? "mic.circle.fill" : "mic.circle")
            .font(.system(size: 27))
            .foregroundStyle(color)
            .scaleEffect(voice.recording ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.12), value: voice.recording)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !disabled else { return }
                        if !pressing {
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
                        pressing = false
                        guard !disabled else { return }
                        if voice.recording { voice.stop() }
                        cancelled = false
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
        return disabled ? .secondary : .accentColor
    }
}
