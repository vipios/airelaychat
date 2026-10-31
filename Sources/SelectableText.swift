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
    /// 长按菜单里是否带「撤回 / 撤回并重新编辑」。
    ///
    /// 只有**用户自己发的**消息才给这两项：AI 的回复撤不了，
    /// 菜单里挂上去点了也没用，纯粹碍事。
    var allowRecall: Bool = true
    /// 是否占满父级宽度。
    ///
    /// 用户消息要**贴合文字**（气泡跟着内容长短走），所以默认 false；
    /// 改成 true 就是铺满整行（AI 正文用这个）。
    ///
    /// 历史：AI 正文曾经因为滚动抖动退回 `Text`，又因为要改菜单文案和选区颜色
    /// 换回来。真正解决抖动的是「流式那段仍用 Text」，见 ChatView 里的 streaming 分支 ——
    /// 不是把控件换掉。别再为了防抖把它改回 Text，那样绿手柄和「复制」文案会一起没了。
    var fillsWidth: Bool = false
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
        tv.font = Self.bodyFont
        tv.textColor = .label
        // 选区高亮和两个圆点手柄都跟着 tintColor 走 —— 换一处等于换两处
        tv.tintColor = Theme.selectionUIColor
        tv.dataDetectorTypes = []       // 别自动把链接变成可点，会和选词打架
        tv.adjustsFontForContentSizeCategory = true
        // 让父级决定宽度，自己只关心高度
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tv.allowRecallMenu = allowRecall
        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
        tv.attributedText = Self.styled(text)
        return tv
    }

    /// 正文字号与行距。
    ///
    /// 2026-10-31 照原版截图改：原版正文比我们之前那版大一号（16pt），
    /// 而且行与行之间是松的（行距 5pt，约 1.45 倍行高）。
    /// 之前 15.5 + 默认行距，整段读起来是"糊成一坨"的感觉。
    private static let bodyFont = UIFont.systemFont(ofSize: Theme.bodySize)

    private static func styled(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: p,
        ])
    }

    func updateUIView(_ tv: PasteTextView, context: Context) {
        // 只在文字真的变了才重设 attributedText：
        // 每帧重设会把用户正在拖的选区手柄打断。
        if tv.text != text { tv.attributedText = Self.styled(text) }
        // 闭包捕获的是某一帧的 msg，必须每次刷新都换掉，
        // 否则撤回的会是上一次渲染时的那条消息（很隐蔽的 bug）
        tv.allowRecallMenu = allowRecall
        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 让气泡宽度贴合文字（2026-10-31 用户：「气泡样式发送指令的时候要自动对齐会话长度」）。
    ///
    /// 只靠 `intrinsicContentSize` 做不到：UITextView 的 intrinsic width 是"没有概念"，
    /// SwiftUI 会把 HStack 里的剩余宽度整个分给它，于是短消息（「你好」）
    /// 也会被拉成半个屏幕宽，气泡右边一大块空白。
    ///
    /// 这里换成按 proposal 量：先假设宽度无限，量出「一句话排一行」要多宽，
    /// 再和父级给的最大宽度取小值 —— 一行放得下就贴着字，放不下才换行。
    ///
    /// ⚠️ 2026-10-31 修抖动：这个函数在滚动时会被**每一帧、每一条消息**各调一次。
    /// 每次都真去 `sizeThatFits` 量一遍文字，量出来的高度差半像素就会让
    /// SwiftUI 重新排一次列表，一连串消息同时重排 —— 表现就是滑到底以后
    /// 所有文字一起抖。所以这里按 (文字, 宽度) 缓存，没变化直接返回上次结果。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: PasteTextView,
                      context: Context) -> CGSize? {
        let maxW = proposal.width ?? UIScreen.main.bounds.width
        guard maxW.isFinite, maxW > 0 else { return nil }

        let key = uiView.text ?? ""
        if uiView.measureKey == key,
           uiView.measureFills == fillsWidth,
           abs(uiView.measureMaxWidth - maxW) < 0.5 {
            return uiView.measureSize
        }

        var result: CGSize
        if fillsWidth {
            // AI 大段正文：直接铺满，不做"贴合文字"那种收缩
            let h = uiView.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude)).height
            result = CGSize(width: maxW, height: ceil(h))
        } else {
            let unbounded = uiView.sizeThatFits(CGSize(width: .greatestFiniteMagnitude,
                                                      height: .greatestFiniteMagnitude))
            guard unbounded.width > 0 else { return nil }
            let w = min(ceil(unbounded.width), maxW)
            let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
            result = CGSize(width: w, height: ceil(h))
        }

        uiView.measureKey = key
        uiView.measureFills = fillsWidth
        uiView.measureMaxWidth = maxW
        uiView.measureSize = result
        return result
    }

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
    /// false 时菜单里只有系统的「拷贝 / 全选 / 查询」（AI 消息用这个）
    var allowRecallMenu: Bool = true

    // MARK: 尺寸缓存

    /// ⚠️ 2026-10-31 修抖动（用户：「ai 给我回复我上滑的时候有一种抖的感觉，
    /// 滑到底以后所有的文字都一秒抖很多遍」）。
    ///
    /// 上一版这里还同时重写了 `intrinsicContentSize` 和 `layoutSubviews`，
    /// 在 `layoutSubviews` 里发现宽度变了就 `invalidateIntrinsicContentSize()`。
    /// 这三样凑在一起就成环：
    ///   布局 → 宽度微变 → invalidate → SwiftUI 重排 → 宽度再微变 → 又 invalidate …
    /// 一条消息抖不明显，一屏十几条同时抖就是"文字在抖"。
    ///
    /// 现在高度只由 SwiftUI 的 `sizeThatFits(proposal:)` 一处决定，
    /// 并且按 (文字, 宽度) 缓存，没变化就不重量 —— 布局不再自己触发自己。
    var measureKey: String = ""
    var measureFills: Bool = false
    var measureMaxWidth: CGFloat = 0
    var measureSize: CGSize = .zero

    // MARK: 自定义菜单项

    /// 长按 / 拖选后弹出的那个菜单。
    ///
    /// 2026-10-31 用户拿原版截图要求：「拷贝换成复制，拖动的样式和图中一样」。
    /// 系统给的标准项在简体中文里叫「拷贝」，这个名字没法通过本地化改，
    /// 只能整块接管菜单 —— iOS 16 起 `UITextView` 提供 `editMenu(for:in:)`，
    /// 返回自己的 `UIMenu` 就完全替换掉系统那一版。
    ///
    /// `.displayInline` 让它横着排（和截图里一样是一条白色胶囊），
    /// 不加这个会是竖排的二级菜单。
    override func editMenu(for textRange: UITextRange, in rect: CGRect) -> UIMenu? {
        var actions: [UIAction] = []

        // 「复制」= 系统 copy:，只拿走当前选中的那一段
        actions.append(UIAction(title: "复制",
                                image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copy(nil)
        })

        actions.append(UIAction(title: "全选") { [weak self] _ in
            self?.selectAll(nil)
        })

        if allowRecallMenu {
            actions.append(UIAction(title: "撤回",
                                    image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                // 菜单收起后再执行，否则弹窗和状态变更抢同一帧，会闪一下
                DispatchQueue.main.async { self?.onRecall?() }
            })
            // 只改菜单上显示的字，动作还是原来那个（撤回 + 把原文填回输入框）
            actions.append(UIAction(title: "重新编辑",
                                    image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                DispatchQueue.main.async { self?.onRecallAndEdit?() }
            })
        }

        return UIMenu(options: .displayInline, children: actions)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(menuRecall) || action == #selector(menuRecallAndEdit) {
            // AI 回复不给撤回项：撤了它也没用，而且会让菜单变长挡住「拷贝」
            return allowRecallMenu
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
