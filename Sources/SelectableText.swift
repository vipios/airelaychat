import SwiftUI
import UIKit

// MARK: - 既能任意选词复制、长按菜单里又带自定义项的文本

/// 消息气泡里那段可交互的文字。
///
/// ⚠️ 2026-10-31 用户要求（两条，必须同时满足）：
///   1. 「长按的时候，弹出来的弹窗里面包括所有」
///   2. 「在文字上加上可以任意复制字符选择复制」
///
/// 为什么不能用 SwiftUI 原生 `Text`：
///   `Text` 的 `.textSelection(.enabled)` 和 `.contextMenu` 抢的是**同一个**
///   长按手势。实测下来 textSelection 优先级更高 —— 长按出的是系统的
///   「拷贝/全选」条，contextMenu 根本不弹。
///   上一版为了拿到撤回菜单把 textSelection 关掉了，结果用户想复制自己
///   发过的话都复制不了，这是个真实的体验倒退。所以这一版换方案。
///
/// 为什么 UITextView 能两个都要：
///   它的选择菜单是系统给的（选词、拖手柄、拷贝/全选/查询全都有），
///   而自定义项可以靠重写 `canPerformAction` 直接塞进**同一个菜单**里。
///   等于"一个弹窗装下所有操作"，正好是用户要的形态。
struct SelectableText: UIViewRepresentable {
    let text: String
    /// 长按菜单里点「撤回」
    let onRecall: () -> Void
    /// 长按菜单里点「撤回并重新编辑」
    let onRecallAndEdit: () -> Void

    func makeUIView(context: Context) -> PasteTextView {
        let tv = PasteTextView()
        tv.delegate = context.coordinator
        tv.isEditable = false
        tv.isSelectable = true          // 必须 true，否则选不了字
        tv.isScrollEnabled = false      // 让它在 SwiftUI 里自适应高度，别自己滚
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.font = UIFont.systemFont(ofSize: 15.5)
        tv.textColor = .label
        tv.dataDetectorTypes = []       // 别自动把链接变成可点，会和选词打架
        tv.adjustsFontForContentSizeCategory = true
        // 让父级决定宽度，自己只关心高度
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: PasteTextView, context: Context) {
        if tv.text != text { tv.text = text }
        // 闭包捕获的是某一帧的 msg，必须每次刷新都换掉，
        // 否则撤回的会是上一次渲染时的那条消息（很隐蔽的 bug）
        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// 点气泡空白处时别把键盘弹出来 —— 这里只需要"选"，不需要"编"。
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { false }
    }
}

/// 带自定义菜单项的 UITextView。
///
/// 关键在 `canPerformAction`：返回 true 的 selector 会被系统加进
/// 长按弹出的那个菜单里，和「拷贝」「全选」排在一起。
/// 这样用户长按 → 一个菜单里既有复制也有撤回，不用记两套手势。
final class PasteTextView: UITextView {

    var onRecall: (() -> Void)?
    var onRecallAndEdit: (() -> Void)?

    // MARK: 高度自适应

    /// UITextView 在 isScrollEnabled = false 时仍会给出一个不靠谱的
    /// intrinsicContentSize，必须自己按宽度算一次，否则要么被截一行、
    /// 要么留一大片空白。
    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            // 首帧还没布局，先给个占位，等 layoutSubviews 会再来一次
            return CGSize(width: UIView.noIntrinsicMetric, height: 22)
        }
        let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fit.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 宽度变了要重算高度（旋转、字体大小变化、气泡变宽都会走到这）
        if abs(bounds.width - lastLaidWidth) > 0.5 {
            lastLaidWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    private var lastLaidWidth: CGFloat = 0

    // MARK: 自定义菜单项

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(menuRecall) || action == #selector(menuRecallAndEdit) {
            return true
        }
        // 其余（拷贝 / 全选 / 查询 / 翻译…）交给系统
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func menuRecall() {
        // 菜单收起后再执行，否则弹窗和状态变更抢同一帧，会闪一下
        DispatchQueue.main.async { [weak self] in
            self?.onRecall?()
        }
    }

    @objc private func menuRecallAndEdit() {
        DispatchQueue.main.async { [weak self] in
            self?.onRecallAndEdit?()
        }
    }
}
