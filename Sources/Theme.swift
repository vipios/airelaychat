import SwiftUI

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

/// 通用按压反馈：按下去缩一点、淡一点。
///
/// 2026-10-31 用户反馈「按键有明显的视觉感，不要和没反应一样」。
/// iOS 默认的 `.plain` 样式在自定义视图上完全不显示按下态 ——
/// 点下去屏幕上一动不动，人就会以为卡了、再点第二下。
/// 这层缩放（0.94）+ 变淡（0.72）足够让人确认"收到了"，
/// 又不至于像系统高亮那样闪一片灰。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.90
    /// 按下时的不透明度。小图标按钮可以用很低（要"啪"一下的感觉），
    /// 整行列表项要留多一点（半片灰闪一下会像卡顿）。
    var dim: CGFloat = 0.52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 2026-11-01 用户：「后台面板点击刷新没有反应，你要让点击效果出来啊」。
            // 原来 0.94 / 0.72 这组在 #F8F8F8 上几乎看不出来，
            // 现在压到 0.90 + 0.52，按下去整颗按钮明显缩一圈、暗一档。
            // 只做缩放和透明度、不加灰色叠层：这个样式的宿主有胶囊也有圆角方块，
            // 硬叠一个 Capsule 会在方角按钮上露出圆角，反而更花。
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.62)
                        .frame(width: 12, height: 12)
                        // 底是白的，转圈必须是深色，不然白转白等于没有
                        .tint(Theme.press)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            // 内边距由 PillStyle 统一加（它在画底色，padding 必须在同一层）
            .contentShape(Capsule())
        }
        .buttonStyle(PillStyle())
        .disabled(disabled || loading)
        .opacity(disabled || loading ? 0.65 : 1)
        // 别让宽度随标题在「刷新 / 刷新中」之间左右跳 —— 顶栏左右两个胶囊
        // 会跟着一起动，看起来像整行在抖。
        .frame(minWidth: 78)
    }
}

/// 胶囊自己的按压样式。
///
/// 为什么不用通用的 `PressableStyle`：只有这里**自己画底色**，
/// 才能真正做到"按下去整颗变深灰、文字反白"，而通用样式只能缩放 + 变淡。
/// 底和内边距都在 ButtonStyle 里画，颜色才能跟着 `isPressed` 一起换。
private struct PillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(pressed ? Theme.card : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(pressed ? Theme.press : Theme.card)
            .clipShape(Capsule())
            // 和聊天页右上角那颗胶囊用的是同一组数值（0.05 / radius 3 / y 1）
            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
