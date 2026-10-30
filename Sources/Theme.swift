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
}
