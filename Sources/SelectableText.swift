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

        // 自己挂一个编辑菜单交互：系统没有"以代码显示菜单"的公开 API，
        // 这是让「全选」之后菜单能自动再弹出来的唯一路子（见 Coordinator.presentMenu）。
        // 它不影响长按 —— 长按仍由 UITextView 自带的交互处理。
        let editor = UIEditMenuInteraction(delegate: context.coordinator)
        tv.addInteraction(editor)
        context.coordinator.editMenu = editor

        tv.allowRecallMenu = allowRecall
        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
        tv.attributedText = Self.styled(text)
        tv.appliedText = text
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
        //
        // 2026-11-01 再加一道锁：比对的是**我们上次写进去的那串**，
        // 不是 `tv.text`。UITextView 会做规范化（行尾、换行符），
        // 一旦 `tv.text` 和原文永远不相等，这里就变成"每次刷新都重设一遍
        // attributedText"——选区被清、滚动位置被顶回去，
        // 表现就是用户说的「到底了一直在跳动」。
        if tv.appliedText != text {
            tv.appliedText = text
            tv.attributedText = Self.styled(text)
        }
        // 闭包捕获的是某一帧的 msg，必须每次刷新都换掉，
        // 否则撤回的会是上一次渲染时的那条消息（很隐蔽的 bug）
        tv.allowRecallMenu = allowRecall
        tv.onRecall = onRecall
        tv.onRecallAndEdit = onRecallAndEdit
        // delegate 里的菜单要用到 allowRecall，也得跟着刷新
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

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
    ///
    /// ⚠️ 2026-11-01 又抖（用户：「ai 给我回复我上滑的时候到底了一直在跳动」）。
    /// 上一版的缓存有个洞：proposal.width 为 nil 时用 `UIScreen.main.bounds.width`
    /// 当宽度去量，还把这个结果写进了缓存。于是同一个控件在两种量法之间来回切：
    ///   宽度有值 → maxW = 353 → 高度 748
    ///   宽度为 nil → maxW = 393 → 高度 812
    /// 两套结果交替命中缓存，就成了"每秒抖很多遍"。
    /// 现在两条规矩：
    ///   1. 宽度量化到 0.5pt 栅格 —— 半像素级的浮动不再触发重排；
    ///   2. proposal 没给宽度时**不写缓存**，只在有真实宽度时才落缓存。
    /// 另外返回的矩形宽度也用同一个量化值，控件宽度和量出来的宽度永远一致，
    /// 不会出现"按 350 量、按 353 摆"导致重新折行。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: PasteTextView,
                      context: Context) -> CGSize? {
        // 有真实宽度就用它；没有（ideal 询问）就退回上次量过的宽度，
        // 实在没有才用屏幕宽度兜底 —— 但这两种兜底都**不写缓存**。
        let rawWidth: CGFloat
        let cacheable: Bool
        if let w = proposal.width, w.isFinite, w > 0 {
            rawWidth = w
            cacheable = true
        } else if uiView.measureMaxWidth > 0 {
            rawWidth = uiView.measureMaxWidth
            cacheable = false
        } else {
            rawWidth = UIScreen.main.bounds.width
            cacheable = false
        }

        // 量化到 0.5pt：SwiftUI 传下来的宽度常在 353.0 / 352.98 之间来回，
        // 这点差值不足以改变排版，却足以让缓存失效、让一屏消息重排一遍。
        let maxW = (rawWidth * 2).rounded(.down) / 2
        guard maxW > 0 else { return nil }

        let key = uiView.text ?? ""
        if uiView.measureKey == key,
           uiView.measureFills == fillsWidth,
           abs(uiView.measureMaxWidth - maxW) < 0.01 {
            return uiView.measureSize
        }

        var result: CGSize
        if fillsWidth {
            // AI 大段正文：直接铺满，不做"贴合文字"那种收缩
            let h = uiView.sizeThatFits(CGSize(width: maxW,
                                               height: CGFloat.greatestFiniteMagnitude)).height
            result = CGSize(width: maxW, height: ceil(h))
        } else {
            // 这里必须写全 `CGFloat.greatestFiniteMagnitude`：
            // 直接写 `.greatestFiniteMagnitude` 时编译器在 CGFloat / Double / Int 之间
            // 无法决定（CI 报 "ambiguous use of"），一个都推断不出来。
            let unbounded = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude))
            guard unbounded.width > 0 else { return nil }
            let w = min(ceil(unbounded.width), maxW)
            let h = uiView.sizeThatFits(CGSize(width: w,
                                               height: CGFloat.greatestFiniteMagnitude)).height
            result = CGSize(width: w, height: ceil(h))
        }

        if cacheable {
            uiView.measureKey = key
            uiView.measureFills = fillsWidth
            uiView.measureMaxWidth = maxW
            uiView.measureSize = result
        }
        return result
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIEditMenuInteractionDelegate {
        /// 当前这一帧的配置。菜单里要不要「撤回」由它决定，
        /// 每次 updateUIView 都会刷新，不能只在 init 时拿一次。
        var parent: SelectableText
        /// 自己挂到 textView 上的编辑菜单交互。
        ///
        /// 为什么要自己挂一个：iOS 没有"以代码显示文字菜单"的公开 API，
        /// `selectAll(nil)` 只改选区、不会把菜单重新弹出来 —— 这才是
        /// 「点了全选还得再点一下才出复制」的真正原因（2026-11-01 用户第二次反馈）。
        /// `UIEditMenuInteraction` 是 iOS 16 公开类，`presentEditMenu(with:)`
        /// 能主动把菜单弹出来，菜单内容由下面 delegate 提供，和长按出来的那份完全一样。
        weak var editMenu: UIEditMenuInteraction?

        init(parent: SelectableText) { self.parent = parent }

        /// 点气泡空白处时别把键盘弹出来 —— 这里只需要"选"，不需要"编"。
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { false }

        /// 选区一变就登记"当前是谁在选"。
        /// 2026-11-01：点空白处取消选区要靠它知道该清哪一个控件。
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                SelectionKiller.shared.active = textView
            }
        }

        /// 接管长按弹出的那个菜单（iOS 16.0+）。
        ///
        /// 系统在简体中文里把这项叫「拷贝」，改不了本地化，只能整块换掉菜单。
        /// 返回自己的 `UIMenu` 就完全替换系统那版；返回 nil 则退回系统菜单。
        ///
        /// `.displayInline` 让它横排成一条（和原版截图一致），
        /// 不加会是竖排二级菜单。
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            // 只是点了下文字、没选中任何东西时（range 长度为 0）不接管，
            // 交给系统出「粘贴/查询」那套，免得点一下也弹四个纵向项。
            guard range.length > 0 else { return nil }
            return buildMenu(for: textView)
        }

        /// 菜单内容只在这里拼一次。
        ///
        /// 长按弹出的、和「全选」之后主动弹出的，必须是同一份 ——
        /// 两处各写一遍的话，改文案时总有一处会漏（这个坑踩过）。
        private func buildMenu(for textView: UITextView) -> UIMenu {
            var actions: [UIAction] = []

            // 「复制」= 系统 copy:，只拿走当前选中的那一段
            actions.append(UIAction(title: "复制",
                                    image: UIImage(systemName: "doc.on.doc")) { [weak textView] _ in
                textView?.copy(nil)
                Haptic.press()
            })

            // 「全选」：只在**还没全选**时才给这一项。
            //
            // 2026-11-01 用户：「前面已经全选了，然后自动弹出来复制就可以了，
            // 已经全选了还要弹出来全选为了什么」。对 —— 全选之后再点一次全选
            // 什么都不会变，纯占位子还挡着视线。所以按当前选区判断：
            // 选满了就把这一项拿掉，菜单只剩「复制」。
            let full = NSRange(location: 0, length: (textView.text as NSString).length)
            let allSelected = full.length > 0 && textView.selectedRange == full

            if !allSelected {
                // 选满之后**自己把菜单再弹一次**。
                // 2026-11-01 用户两次反馈：「全选完以后他不弹出来复制，还要我点击
                // 一次被选的位置才能出来复制」。上一版试过"先清零再设满选区"，
                // 指望系统因为选区变化自动重弹 —— 不行：菜单是被长按手势带出来的。
                // 所以改成显式 `presentEditMenu`。0.08s 是等系统把旧菜单收干净。
                actions.append(UIAction(title: "全选",
                                        image: UIImage(systemName: "textformat.size")) { [weak self, weak textView] _ in
                    guard let tv = textView else { return }
                    let range = NSRange(location: 0, length: (tv.text as NSString).length)
                    guard range.length > 0 else { return }
                    tv.becomeFirstResponder()
                    tv.selectedRange = range
                    // 选满了就要登记为"当前活动选区"，点空白才有东西可以取消
                    SelectionKiller.shared.active = tv
                    Haptic.tap()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        self?.presentMenu(on: tv)
                    }
                })
            }

            if parent.allowRecall {
                actions.append(UIAction(title: "撤回",
                                        image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    Haptic.hard()
                    // 菜单收起后再执行，否则弹窗和状态变更抢同一帧，会闪一下
                    DispatchQueue.main.async { self?.parent.onRecall() }
                })
                // 只改菜单上显示的字，动作还是原来那个（撤回 + 把原文填回输入框）
                actions.append(UIAction(title: "重新编辑",
                                        image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                    Haptic.tap()
                    DispatchQueue.main.async { self?.parent.onRecallAndEdit() }
                })
            }

            return UIMenu(options: .displayInline, children: actions)
        }

        /// 主动弹菜单。锚点取控件顶部中间：
        /// 全选时控件是整段正文那么高，取顶部才不会把菜单甩到屏幕外面去。
        func presentMenu(on tv: UITextView) {
            guard tv.window != nil, let menu = editMenu else { return }
            let point = CGPoint(x: max(1, tv.bounds.midX), y: max(1, tv.bounds.minY + 1))
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                               sourcePoint: point))
        }

        // MARK: UIEditMenuInteractionDelegate

        /// 主动弹出时菜单内容的来源。`presentEditMenu` 必调这个，
        /// 返回 nil 就什么也不显示。
        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let tv = interaction.view as? UITextView else { return nil }
            return buildMenu(for: tv)
        }
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

    /// 上一次真正写进 `attributedText` 的那串原文。
    /// 不能拿 `text` 属性去比对 —— UITextView 会做规范化，两者永远不相等
    /// 就会导致每次刷新都重设一遍文字（选区被清、滚动被顶回去，看着像在抖）。
    var appliedText: String = ""

    // MARK: 自定义菜单项

    /// 长按 / 拖选后弹出的那个菜单。
    ///
    /// 2026-10-31 CI 撞墙记录：这里本来写的是
    /// `override func editMenu(for:in:)`，编译直接报
    /// "method does not override any method from its superclass" ——
    /// 那个方法在 SDK 里不是 open 的，子类没法 override。
    ///
    /// 现在改成走 `UITextViewDelegate` 的
    /// `textView(_:editMenuForTextIn:suggestedActions:)`，见下面 Coordinator。
    /// 那是官方留给调用方的入口，同样能整块替换菜单。
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

// MARK: - 点空白处取消选区

/// 选了一段以后，点没选中的地方应该"取消这一次选择"。
///
/// 2026-11-01 用户：「全选或者选择复制的时候，不想复制了，点击没选择的地方
/// 应该对此次的复制进行取消，你现在都取消不了」，并附了截图 ——
/// 菜单已经收了，绿色高亮还整段留在那儿。
///
/// 为什么不用 SwiftUI 的 `onTapGesture`：它和 ScrollView 的拖动、
/// 和 UITextView 自己的长按/拖动手柄会抢手势，表现很不稳
/// （有时点一下滚不动、有时点了没反应，还得靠真机反复试）。
///
/// 这里改成在 **window 最外层**挂一个 tap 识别器：
///   · `cancelsTouchesInView = false` —— 不吞事件，输入框、按钮照常工作；
///   · 点在当前选区那块文本自己身上 → 不管，交给 UITextView 调光标；
///   · 点在别处 → 收菜单 + 清选区 + 交还第一响应者。
final class SelectionKiller: NSObject, UIGestureRecognizerDelegate {
    static let shared = SelectionKiller()

    /// 当前有选区的那个控件。弱引用：消息滑出屏幕被回收后自动变 nil，
    /// 不会拖着一堆已经不在树上的 textView。
    weak var active: UITextView?

    private var installed = false
    private var retry = 0

    /// App 启动时调一次。必须在 window 已经存在之后 ——
    /// 拿不到就等 0.3 秒再来，最多 6 次（约 2 秒）。
    func install() {
        guard !installed else { return }
        guard let w = Self.keyWindow() else {
            guard retry < 6 else { return }
            retry += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.install()
            }
            return
        }
        installed = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        w.addGestureRecognizer(tap)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let tv = active else { return }
        // 点在自己身上：可能是想改选词/挪光标，交给 UITextView 自己处理
        if tv.bounds.contains(g.location(in: tv)) { return }
        // 立刻解绑，再去清。不能等 0.05 秒后才解绑 ——
        // 这中间用户可能已经点了另一条消息、把 active 换成了新的控件，
        // 延迟里再置空就会把"新的那个"的登记抹掉，之后点空白又清不掉它。
        active = nil
        clear(tv)
    }

    /// 收菜单 → 清选区 → 交还第一响应者。
    ///
    /// ⚠️ 故意晚 0.05 秒再清，这不是凑数：
    /// 点菜单上「复制」那一下，window 的 tap 和菜单的 UIAction 在同一个 runloop
    /// 里都会被触发。要是我们抢在前头把选区清了，`copy(nil)` 拿到的就是空内容 ——
    /// 表现成"点了复制什么都没进剪贴板"。延后一帧让 action 先跑完，清不清都无所谓。
    func clear(_ tv: UITextView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for i in tv.interactions {
                (i as? UIEditMenuInteraction)?.dismissMenu()
            }
            tv.selectedRange = NSRange(location: 0, length: 0)
            tv.resignFirstResponder()
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// 点在"编辑菜单"本身上时直接不接管。
    ///
    /// 菜单是系统私有类的视图（`_UIEditMenuView` / `…PlatterView` 之类），
    /// 没有公开类型可以比对，只能沿 superview 链看类名。这一步是上面那个
    /// 0.05 秒延迟之外的第二道保险 —— 只要识别器收不到这一下，就绝不会
    /// 在用户点「全选」时把刚弹出来的菜单又收掉。
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var node = touch.view
        while let cur = node {
            let name = String(describing: type(of: cur))
            if name.contains("EditMenu") || name.contains("ContextMenu") || name.contains("Platter") {
                return false
            }
            node = cur.superview
        }
        return true
    }

    /// 和滚动、和文本自己的手势同时识别，互不阻塞。
    /// 返回 false 的话，滚动过程中只要手指一开始碰到按钮就会判定失败。
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
