import SwiftUI
import UIKit

// MARK: - 主题（按 WorkBuddy 手机端截图逐像素取色）

/// 从参考截图上直接采到的值：
///
///   页面背景 / 顶栏 / Tab 栏   = #F8F8F8   （三处同色，整页没有一条分隔线）
///   输入胶囊 / 用户气泡 / 按钮  = #FFFFFF   （纯白）
///
/// 规则就一句话：**底色是浅灰，浮在上面的东西才用白**。
///
/// 我第一版做反了 —— 白底配灰控件，单看每个零件都"像"，整体一看就不是那个 App。
/// 这类差距不在控件本身，而在"谁比谁更亮"这一层。
enum Theme {

    /// 页面底色 #F8F8F8。深色模式用 #1C1C1E 而不是纯黑：
    /// 纯黑会让白色控件对比过猛，WorkBuddy 那种克制的观感就没了。
    static let page = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
            : UIColor(red: 0.973, green: 0.973, blue: 0.973, alpha: 1)
    })

    /// 浮起来的白块：输入胶囊、消息气泡、抽屉里的「新建任务」。
    static let card = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.172, green: 0.172, blue: 0.180, alpha: 1)
            : .white
    })

    /// 次要文字（Tab 未选中、副标题、占位符）
    static let sub = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)   // #8E8E93
            : UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    })

    /// 抽屉底色 #FAFAFA。
    ///
    /// 比页面底色（#F8F8F8）亮两个色阶，肉眼几乎看不出来 ——
    /// 但它让抽屉里的「新建任务」白按钮有了一层极薄的对比，
    /// 靠描边 + 2 个色阶的差就能"浮"起来，不需要更重的阴影。
    static let sheet = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.140, green: 0.140, blue: 0.150, alpha: 1)
            : UIColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1)
    })

    /// 输入胶囊里那个声波图标的颜色（参考图是近黑，不是灰）
    static let inkSoft = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.780, green: 0.780, blue: 0.800, alpha: 1)
            : UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
    })

    /// 产物卡片的底色 #F2F2F7。
    ///
    /// 2026-10-31 对着原版截图核出来的：产物卡片**不是**白色上面浮着，
    /// 而是铺一层浅灰、没有描边。之前用的是白底 + 0.7pt 描边，
    /// 描边在浅灰页面上会显出一道"线框"，一眼就不像原版。
    static let tile = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.172, green: 0.172, blue: 0.180, alpha: 1)   // #2C2C2E
            : UIColor(red: 0.949, green: 0.949, blue: 0.965, alpha: 1)   // #F2F2F7
    })

    // MARK: - 字号

    /// 正文 / 输入框 / 气泡共用的唯一字号。
    ///
    /// 2026-10-31 用户要求：「输入框还用咱们的字体大小」。
    /// 之前这三个地方各写各的数字（15.5 / 16），一调整就有一处掉队，
    /// 所以干脆收到一处，以后只改这一个数。
    static let bodySize: CGFloat = 16

    /// 选中 / 按下的底色：深灰。
    ///
    /// 2026-11-01 用户：「在所有的界面都添加一个选中的状态…选中状态改为深灰色也行你自己定」。
    /// 之前选中态用的是 `Color.primary`（纯黑），在白底上对比太硬，
    /// 一排按钮里只要有一个黑的，整屏视线全被它抢走；深灰既明确又不刺眼。
    static let press = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.780, green: 0.780, blue: 0.800, alpha: 1)   // 深色模式下反过来用浅灰
            : UIColor(red: 0.235, green: 0.235, blue: 0.247, alpha: 1)   // #3C3C3F
    })

    /// 选中行/选中块的浅底（列表里那种"我在这一行"的提示，不能太重）
    static let selectedRow = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.240, green: 0.240, blue: 0.255, alpha: 1)
            : UIColor(red: 0.898, green: 0.898, blue: 0.918, alpha: 1)   // #E5E5EA
    })

    /// 选中文字的高亮底色 + 两端手柄的颜色。
    ///
    /// 2026-10-31 用户拿 WorkBuddy 原版截图要求「拖动的样式和图中的一样的」：
    /// 那边是**深一点的墨绿**（截图放大取色约 #0E9C69），不是 iOS 默认的蓝，
    /// 也不是我第一版调的亮青绿。手柄形状（竖杆 + 圆点）是系统固定的，
    /// 改 `tintColor` 就能同时换掉选区底色和手柄 —— 两者由同一个值派生。
    static let selection = Color(UIColor(red: 0.055, green: 0.612, blue: 0.412, alpha: 1))
    static let selectionUIColor = UIColor(red: 0.055, green: 0.612, blue: 0.412, alpha: 1)
}

extension View {

    /// 悬浮白卡片：大圆角 + 极淡阴影。
    ///
    /// 参考图上这层阴影几乎看不见（白块只比 #F8F8F8 亮 7 个色阶），
    /// 所以千万别做成"卡片投影"那种厚重效果 —— 那会立刻变成另一个 App 的样子。
    func floatingCard(corner: CGFloat = 24, shadow: CGFloat = 0.05) -> some View {
        self
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: Color.black.opacity(shadow), radius: 7, y: 1)
    }

    /// 弹层大圆角。
    ///
    /// 系统原生的 `.presentationCornerRadius` 要 iOS 16.4+，
    /// 而本工程部署目标是 16.0 —— 直接写会编译报错：
    ///   error: 'presentationCornerRadius' is only available in iOS 16.4 or newer
    ///
    /// 所以包一层做版本判断：16.4 及以上走原生（弹层真的变圆），
    /// 更老的系统原样返回（弹层是系统默认圆角，观感略平但不会崩）。
    /// 这样 16.0~16.3 的老机型也装得上，不会为了一个圆角砍掉兼容区间。
    @ViewBuilder
    func roundSheet(_ radius: CGFloat = 28) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}

// MARK: - 按键反馈与胶囊按钮

/// 震动反馈（2026-11-01 用户：「所有的按键假装一个震动反馈」）。
///
/// 为什么单独收一个 enum：全站十几个按钮都要震，每处各写一遍
/// `UIImpactFeedbackGenerator` 既啰嗦又容易漏 `prepare()` ——
/// 没 prepare 的第一下经常不震（生成器还没被唤起），用户就会觉得"有的按钮震有的不震"。
///
/// 强度选择：
///   `.light`  —— 普通按钮按下 / 切换 Tab（轻一下，不烦）
///   `.medium` —— 有结果的提交（发送、保存）
///   `.rigid`  —— 长按菜单里的破坏性操作（删除、撤回）
enum Haptic {
    /// 常驻的生成器，省掉每次新建 + 预热的那点延迟。
    /// 只在主线程用，UITouch 本身也是主线程，不用加锁。
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()

    /// 普通按钮按下
    static func tap() {
        light.impactOccurred(intensity: 0.7)
        light.prepare()
    }

    /// 确认类动作（发送、复制成功）
    static func press() {
        medium.impactOccurred(intensity: 0.85)
        medium.prepare()
    }

    /// 删除 / 撤回这类"有点重"的动作
    static func hard() {
        rigid.impactOccurred(intensity: 1.0)
        rigid.prepare()
    }

    /// 成功 / 失败的系统提示音（配合系统手势）
    static func notifySuccess() {
        notify.notificationOccurred(.success)
        notify.prepare()
    }

    /// 先把生成器叫醒。列表进入时调一次，第一下点击就不会哑掉。
    static func warmUp() {
        light.prepare()
        medium.prepare()
        rigid.prepare()
    }
}

/// 通用按压反馈：按下去缩一点、暗一点，同时震一下。
///
/// 2026-10-31 用户反馈「按键有明显的视觉感，不要和没反应一样」。
/// iOS 默认的 `.plain` 样式在自定义视图上完全不显示按下态 ——
/// 点下去屏幕上一动不动，人就会以为卡了、再点第二下。
/// 这层缩放（0.94）+ 变淡（0.72）足够让人确认"收到了"，
/// 又不至于像系统高亮那样闪一片灰。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    /// 按下时的轻微变淡。**只用来补一点点"软"的感觉**，不再是主要反馈 ——
    /// 白按钮变透明等于变得更接近背景色，肉眼几乎看不出来。
    var dim: CGFloat = 0.94
    /// 按下时叠一层的底色强度。给**没有背景**的元素（纯图标、纯文字）用：
    /// 它们没有像素可以变暗，不叠底就完全看不出按下了。
    var tint: Double = 0
    /// 上面那层底的圆角。圆形按钮传 999。
    var tintRadius: CGFloat = 10
    /// 按下时变暗的强度。
    var darken: Double = 0.20
    /// 按下时震一下。默认开 —— 用户要求「所有的按键都加一个震动反馈」。
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            // 2026-11-01 用户：「怎么只有返回按键有反馈效果啊」。
            //
            // 上一版按下是"缩 5% + 变淡到 0.52"，问题是：变淡 = 变透明
            // = 浅色按钮往回退到页面底色里，本来就同色系的两种白，一淡就没了。
            // 变暗才是肉眼能立刻抓住的方向 —— 并且 brightness 是像素级滤镜，
            // 只作用于不透明像素，形状（圆角/胶囊/圆）自动跟随，不用另画底。
            .brightness(pressed ? -darken : 0)
            .scaleEffect(pressed ? scale : 1)
            // 没有底色的元素（纯图标、纯文字）变暗不可见，靠这层补。
            // tint 默认 0，等于完全不画，不会影响已有底色的按钮。
            .background(
                RoundedRectangle(cornerRadius: tintRadius, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? tint : 0))
                    .padding(-4)
            )
            .opacity(pressed ? dim : 1)
            // 按下要"立刻"（0.05s，几乎是一帧），松开才慢慢褪（0.20s）。
            // 一前一后不一致是有意的：延迟出现在按下端 = 感觉迟钝；
            // 出现在松开端 = 有余韵，快速点一下也能看见那一下。
            .animation(pressed ? .easeOut(duration: 0.05)
                               : .easeOut(duration: 0.20),
                       value: pressed)
            // 2026-11-01 用户：「所有的按键加一个震动反馈」。
            // 只在"按下"这一侧触发（松手不再震），强度 light，
            // 连点也不会震成打字机那样。
            //
            // 这里用的是 iOS 16 的 onChange(of:perform:) 旧签名 ——
            // 17 起被标记弃用，但工程最低支持 16.0，走新签名就得 #available 分叉，
            // 一个按钮的震动不值得为它把视图类型拆成两支。
            .onChange(of: pressed) { now in
                if now, haptic { Haptic.tap() }
            }
    }
}

/// 只加震动、**完全不动外观**的按钮样式。
///
/// 给 Form / List 里那些系统自己就带高亮的按钮用（设置页、诊断页）。
/// 换成 PressableStyle 会给每一行套缩放和灰底，把系统的分组列表观感弄乱；
/// 这个样式原样返回 label，只借 isPressed 触发一下触感。
struct HapticStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { now in
                if now { Haptic.tap() }
            }
    }
}

/// 胶囊按钮：图标 + 文字，带底、带按压反馈。
///
/// 2026-11-01 用户：「把后台面板中的胶囊颜色和聊天页右上角的胶囊颜色一样，
/// 选中状态改为深灰色」。所以这里不再有"黑底主按钮"那一版 ——
/// 三个胶囊统一成**和聊天页右上角那颗一模一样的白底 + 同款淡阴影**，
/// 按下去整颗变深灰、字变白（这就是"选中状态"）。
struct PillButton: View {
    let title: String
    let icon: String
    /// 正在执行（刷新中）：图标换成转圈，按钮半透明且点不动。
    ///
    /// 2026-11-01 用户：「点在点击按钮都没有反应也不知道是不是在刷新」——
    /// 光有按下态只解决了"点到了"，还得让人知道"点完在干活"。
    /// 所以刷新期间按钮自己变成 loading，标题也换成「刷新中」。
    var loading: Bool = false
    /// 只是禁用（不改文字、不转圈）
    var disabled: Bool = false
    let action: () -> Void

    /// 手指是否按在上面。自己管而不是交给 ButtonStyle：
    /// ButtonStyle 的 isPressed 只在"按下"那一下为真，用户快速点按（60~90ms）
    /// 时深灰还没画出来就弹回去了 —— 这就是"点刷新没反应"。
    @State private var pressing = false
    /// 松手后的保底高亮。让快速点按也留得下 0.16s 的深灰，
    /// 再加 0.28s 淡出，一眼能确认"我确实点到了"。
    @State private var flashing = false
    /// 连点时让上一次的淡出任务作废，否则第二次点击的高亮会被第一次的回调提前掐掉。
    @State private var flashToken = 0

    private var active: Bool { pressing || flashing }
    private var inert: Bool { disabled || loading }

    var body: some View {
        HStack(spacing: 5) {
            if loading {
                ProgressView()
                    .scaleEffect(0.62)
                    .frame(width: 12, height: 12)
                    // 底是白的，转圈必须是深色，不然白转白等于没有
                    .tint(active ? Theme.card : Theme.press)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Theme.card : Color.primary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        // 别让宽度随标题在「刷新 / 刷新中」之间左右跳 —— 顶栏左右两个胶囊
        // 会跟着一起动，看起来像整行在抖。
        .frame(minWidth: 78)
        .background(active ? Theme.press : Theme.card)
        .clipShape(Capsule())
        // 和聊天页右上角那颗胶囊用的是同一组数值（0.05 / radius 3 / y 1）
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        .scaleEffect(pressing ? 0.95 : 1)
        .contentShape(Capsule())
        .opacity(inert ? 0.65 : 1)
        // 用 DragGesture 而不是 Button：Button 一旦被 disabled（刷新期间就是）
        // 就再也收不到触摸，按下态直接消失；手势由我们自己判断能不能点。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !inert, !pressing else { return }
                    Haptic.tap()
                    withAnimation(.easeOut(duration: 0.04)) { pressing = true }
                }
                .onEnded { v in
                    withAnimation(.easeOut(duration: 0.06)) { pressing = false }
                    guard !inert else { return }
                    // 手指滑出去太远就当作取消，别误触
                    if v.translation.width < -50 || v.translation.height < -50 { return }
                    fire()
                },
            including: inert ? .subviews : .all
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    /// 高亮 0.16s（足够看清）→ 0.28s 淡回白色。
    private func fire() {
        flashToken += 1
        let token = flashToken
        flashing = true
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard token == flashToken else { return }
            withAnimation(.easeOut(duration: 0.28)) { flashing = false }
        }
    }
}

// 注：原来这里还有一个 `PillStyle`（ButtonStyle 版的深灰按下态）。
// 2026-11-01 删掉了 —— ButtonStyle 的 isPressed 在快速点按时根本来不及画，
// 而且刷新期间按钮被 disabled 后连 isPressed 都不再更新。
// 现在深灰按下态由 `PillButton` 自己用 @State + DragGesture 控制，
// 能保底显示 0.16s，不依赖 Button 的生命周期。
