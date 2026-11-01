import SwiftUI
import UIKit

// MARK: - 把一条 AI 回复切成「正文 / 代码块」

/// 回复被切出来的一段。
///
/// ⚠️ 2026-11-02 用户两条要求（截图为准）：
///   1.「他要是给我发终端指令类的，连接类的，需要单独有一键复制那个图标啊，
///      就像二本书叠加那种的小图标，我能快速点击去复制」
///   2.「像这种的直接就有明显的颜色区分后面还有一个小图标让我一键复制」
///
/// 之前整条回复是**一整块 UITextView**：代码和正文混在同一段里，
/// 既没法在代码右上角放按钮，也没法给代码单独上色（那块控件只认一种字体一个颜色）。
/// 所以现在按 ``` 切成多段：正文一段、代码一段，各自用合适的控件渲染。
struct RichBlock: Identifiable {
    enum Kind {
        /// 普通叙述文字
        case prose(String)
        /// 一个代码块（语言标记可能为空）
        case code(lang: String, code: String)
    }

    let id: Int
    let kind: Kind
}

enum RichSplit {

    /// 按 ``` 切段。**没闭合的代码块也算代码** —— 流式输出到一半时
    /// 后面那截还没写完的代码必须已经开始按代码渲染，否则等 ``` 收尾的
    /// 那一刻整块会突然换样式、高度一跳。
    static func blocks(_ s: String) -> [RichBlock] {
        var out: [RichBlock] = []
        var prose = ""
        var code = ""
        var lang = ""
        var inBlock = false
        var n = 0

        func flushProse() {
            // 只去首尾空行，段内的空行要留着（正文里的空行是分段）
            let p = prose.trimmingCharacters(in: .newlines)
            if !p.isEmpty {
                out.append(RichBlock(id: n, kind: .prose(p)))
                n += 1
            }
            prose = ""
        }

        func flushCode() {
            let c = code.trimmingCharacters(in: .newlines)
            if !c.isEmpty {
                out.append(RichBlock(id: n, kind: .code(lang: lang, code: c)))
                n += 1
            }
            code = ""
            lang = ""
        }

        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inBlock {
                    flushCode()
                    inBlock = false
                } else {
                    flushProse()
                    inBlock = true
                    // 只取第一段：```swift title="x.swift" 这种附加信息不要
                    let raw = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    lang = raw.components(separatedBy: .whitespaces).first ?? ""
                }
                continue
            }
            if inBlock { code += line + "\n" } else { prose += line + "\n" }
        }
        if inBlock { flushCode() }
        flushProse()
        return out
    }
}

/// 切段结果 + 语法着色结果的缓存。
///
/// 为什么必须缓存：`body` 每刷新一次就会重新算一遍，一屏十几条消息、
/// 每条几千字，每次都重新做字符串扫描和分词，主线程直接卡住 ——
/// 那又会变成"文字在抖"。这跟前面几版抖动的教训是同一件事：
/// **渲染路径上不能有每次都重算的东西**。
///
/// `@MainActor`：里面是可变的静态字典，只有主线程会读写（全部调用都来自
/// SwiftUI 的 body）。加上它既是事实描述，也顺手把并发检查的告警消掉。
@MainActor
enum RichCache {
    private static var blocks: [String: [RichBlock]] = [:]
    private static var blockOrder: [String] = []

    private static var codes: [String: AttributedString] = [:]
    private static var codeOrder: [String] = []

    /// 上限别开太大：一条长回复的正文就有几十 KB，留 40 条足够覆盖当前会话。
    private static let cap = 40

    static func blocks(_ s: String) -> [RichBlock] {
        if let v = blocks[s] { return v }
        let v = RichSplit.blocks(s)
        blocks[s] = v
        blockOrder.append(s)
        if blockOrder.count > cap {
            let k = blockOrder.removeFirst()
            blocks.removeValue(forKey: k)
        }
        return v
    }

    static func code(_ code: String, lang: String) -> AttributedString {
        let key = lang + "\u{0}" + code
        if let v = codes[key] { return v }
        let v = SyntaxHighlight.attributed(code, lang: lang)
        codes[key] = v
        codeOrder.append(key)
        if codeOrder.count > cap {
            let k = codeOrder.removeFirst()
            codes.removeValue(forKey: k)
        }
        return v
    }
}

// MARK: - 一个代码块

/// 代码卡片：左上角语言名 + 右上角一键复制。
///
/// 配色照用户给的截图：浅灰底、无重描边、语言名用次要色小字、
/// 复制图标就在语言名同一行的最右边（两本书叠起来那个 `doc.on.doc`）。
struct CodeBlockView: View {
    let lang: String
    let code: String

    /// 刚复制完，图标临时变成对勾。
    ///
    /// 不给反馈的话用户点完不知道有没有成功 —— 剪贴板是看不见的，
    /// 唯一能确认的就是图标变一下 + 震一下。
    @State private var copied = false
    @State private var token = 0

    private var title: String {
        let l = lang.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return "代码" }
        let map: [String: String] = [
            "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
            "py": "python", "js": "javascript", "ts": "typescript",
            "yml": "yaml", "md": "markdown", "rb": "ruby",
        ]
        return map[l] ?? l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // 一键复制：用户要的就是这个图标，别做成文字按钮
                Button {
                    copyIt()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(copied ? Theme.selection : Color.secondary)
                        // 图标本身只有 13pt，点击区域必须撑大，
                        // 否则手指基本点不准（这也是"点了没反应"的常见原因）
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.9, tint: 0.06, tintRadius: 8))
                .accessibilityLabel(copied ? "已复制" : "复制代码")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.top, 6)
            .padding(.bottom, 2)

            // 代码本身横向可滚：命令行很长，硬换行会看成一坨，
            // 而且缩进换行后根本没法照着敲。
            ScrollView(.horizontal, showsIndicators: false) {
                Text(RichCache.code(code, lang: lang))
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
                    .padding(.top, 1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeColors.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CodeColors.border, lineWidth: 0.7)
        )
        // 长按整块也能复制：手机上有时候就是想长按，不想点小图标。
        // 这是补救通道，不是主路径 —— 主路径是右上角那个图标。
        .contextMenu {
            Button {
                copyIt()
            } label: {
                Label("复制代码", systemImage: "doc.on.doc")
            }
        }
    }

    private func copyIt() {
        UIPasteboard.general.string = code
        Haptic.press()
        token += 1
        let mine = token
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        // 1.2 秒后变回去。用 token 防止连点时被上一次的回调提前复位。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard mine == token else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

/// 代码块的底色 / 描边。
///
/// 页面底色是 #F8F8F8，所以代码块必须**比页面更亮一点** + 一道极淡描边，
/// 才能像截图那样"浮"起来。反过来做成深灰会变成另一个 App 的样子。
enum CodeColors {
    static let bg = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.145, green: 0.145, blue: 0.155, alpha: 1)
            : UIColor(red: 0.980, green: 0.980, blue: 0.984, alpha: 1)
    })

    static let border = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.08)
            : UIColor(white: 0.0, alpha: 0.06)
    })
}

// MARK: - 语法着色

/// 一个够用的分词器。
///
/// 为什么自己写而不是引第三方库：这个工程是"零依赖 + GitHub Actions 无签名编译"，
/// 多一个 SPM 依赖就多一处构建风险和下载等待，而代码块着色只需要
/// 「关键字 / 字符串 / 注释 / 数字 / 类型名 / 函数名」这六类就够看。
enum SyntaxHighlight {

    enum Kind {
        case plain, keyword, str, comment, num, type, fn, attr
    }

    struct Tok {
        let s: String
        let k: Kind
    }

    /// 用 # 当行注释的语言
    private static let hashLangs: Set<String> = [
        "sh", "bash", "zsh", "shell", "console", "py", "python",
        "yaml", "yml", "toml", "rb", "ruby", "pl", "perl", "r",
        "conf", "ini", "service", "dockerfile", "makefile", "ps1", "powershell",
        "gitignore", "env",
    ]

    private static func keywords(_ l: String) -> Set<String> {
        switch l {
        case "swift":
            return ["func", "let", "var", "if", "else", "guard", "return", "for", "while",
                    "repeat", "switch", "case", "default", "struct", "class", "enum",
                    "protocol", "extension", "import", "init", "deinit", "self", "super",
                    "true", "false", "nil", "try", "catch", "throw", "throws", "async",
                    "await", "public", "private", "fileprivate", "internal", "open",
                    "static", "final", "override", "mutating", "in", "where", "as", "is",
                    "some", "any", "typealias", "associatedtype", "do", "defer", "break",
                    "continue", "fallthrough", "indirect", "lazy", "weak", "unowned",
                    "convenience", "required", "subscript", "operator", "inout"]
        case "py", "python":
            return ["def", "class", "return", "if", "elif", "else", "for", "while",
                    "import", "from", "as", "with", "try", "except", "finally", "raise",
                    "pass", "lambda", "None", "True", "False", "and", "or", "not", "in",
                    "is", "global", "nonlocal", "yield", "assert", "del", "async", "await"]
        case "js", "javascript", "ts", "typescript", "json", "jsx", "tsx":
            return ["function", "const", "let", "var", "return", "if", "else", "for",
                    "while", "do", "switch", "case", "break", "continue", "new", "class",
                    "extends", "super", "this", "import", "export", "from", "default",
                    "async", "await", "try", "catch", "finally", "throw", "typeof",
                    "instanceof", "in", "of", "delete", "void", "yield", "null",
                    "undefined", "true", "false", "interface", "type", "enum",
                    "implements", "public", "private", "protected", "readonly", "static",
                    "as", "satisfies"]
        case "sh", "bash", "zsh", "shell", "console":
            return ["if", "then", "else", "elif", "fi", "for", "in", "do", "done",
                    "while", "case", "esac", "function", "return", "export", "local",
                    "echo", "cd", "sudo", "apt", "dpkg", "systemctl", "service",
                    "curl", "wget", "git", "mkdir", "rm", "cp", "mv", "chmod", "chown",
                    "ssh", "scp", "nginx", "docker", "pip", "python3", "brew",
                    "launchctl", "ldid", "codesign", "make", "tar", "unzip", "grep",
                    "sed", "awk", "cat", "ls", "which", "kill", "killall", "export",
                    "source", "nohup", "crontab", "mount", "umount", "find", "xargs"]
        case "yaml", "yml", "toml", "ini", "conf":
            return ["true", "false", "null", "yes", "no", "on", "off"]
        case "go", "golang":
            return ["func", "var", "const", "if", "else", "for", "range", "return",
                    "switch", "case", "default", "struct", "interface", "type", "map",
                    "chan", "go", "defer", "select", "package", "import", "nil",
                    "true", "false", "break", "continue", "fallthrough"]
        case "c", "cpp", "c++", "objc", "objective-c", "m", "h":
            return ["int", "char", "float", "double", "void", "long", "short", "signed",
                    "unsigned", "struct", "union", "enum", "typedef", "static", "const",
                    "return", "if", "else", "for", "while", "do", "switch", "case",
                    "default", "break", "continue", "goto", "sizeof", "NULL", "true",
                    "false", "class", "public", "private", "protected", "namespace",
                    "template", "using", "new", "delete", "virtual", "override"]
        case "java", "kt", "kotlin":
            return ["public", "private", "protected", "class", "interface", "enum",
                    "extends", "implements", "static", "final", "void", "int", "long",
                    "double", "float", "boolean", "char", "String", "new", "return",
                    "if", "else", "for", "while", "do", "switch", "case", "default",
                    "break", "continue", "try", "catch", "finally", "throw", "throws",
                    "import", "package", "this", "super", "null", "true", "false",
                    "val", "var", "fun", "when", "object", "data"]
        default:
            // 语言没标 / 不认识：用一组跨语言最常见的关键字兜底。
            // 宁可少着色几个词，也不要把普通单词染成关键字。
            return ["if", "else", "for", "while", "return", "function", "func", "def",
                    "class", "struct", "import", "export", "const", "let", "var",
                    "true", "false", "null", "nil", "None", "new", "try", "catch",
                    "finally", "throw", "async", "await", "switch", "case", "break",
                    "continue", "public", "private", "static", "void", "int", "self"]
        }
    }

    static func attributed(_ code: String, lang: String) -> AttributedString {
        var out = AttributedString()
        for t in tokens(code, lang: lang) {
            var piece = AttributedString(t.s)
            piece.foregroundColor = color(t.k)
            out += piece
        }
        return out
    }

    private static func color(_ k: Kind) -> Color {
        switch k {
        case .plain:
            return Color(uiColor: .label)
        case .keyword:
            // 截图里 keyword 是偏砖红的那一支
            return adaptive(light: 0xB0362C, dark: 0xFF7B72)
        case .str:
            return adaptive(light: 0x1F7A3D, dark: 0x7EE787)
        case .comment:
            return adaptive(light: 0x8A8F98, dark: 0x8B949E)
        case .num:
            return adaptive(light: 0x1A5FB4, dark: 0x79C0FF)
        case .type:
            return adaptive(light: 0x6B3FA0, dark: 0xD2A8FF)
        case .fn:
            return adaptive(light: 0x0B5FA5, dark: 0x79C0FF)
        case .attr:
            return adaptive(light: 0x9A6700, dark: 0xD29922)
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: 分词

    static func tokens(_ code: String, lang: String) -> [Tok] {
        let l = lang.trimmingCharacters(in: .whitespaces).lowercased()
        let hashComment = hashLangs.contains(l)
        let kw = keywords(l)
        let cs = Array(code)
        let n = cs.count

        var out: [Tok] = []
        var buf = ""
        var i = 0

        func flush() {
            if !buf.isEmpty {
                out.append(Tok(s: buf, k: .plain))
                buf = ""
            }
        }
        func push(_ s: String, _ k: Kind) {
            flush()
            if !s.isEmpty { out.append(Tok(s: s, k: k)) }
        }

        func isIdentStart(_ c: Character) -> Bool {
            c.isLetter || c == "_" || c == "$"
        }
        func isIdentBody(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$"
        }
        func isDigit(_ c: Character) -> Bool { c.isNumber }

        while i < n {
            let c = cs[i]

            // 行注释 // 或 #
            if c == "/", i + 1 < n, cs[i + 1] == "/", !hashComment {
                var j = i
                while j < n, cs[j] != "\n" { j += 1 }
                push(String(cs[i..<j]), .comment)
                i = j
                continue
            }
            if c == "#", hashComment {
                var j = i
                while j < n, cs[j] != "\n" { j += 1 }
                push(String(cs[i..<j]), .comment)
                i = j
                continue
            }
            // 块注释 /* */
            if c == "/", i + 1 < n, cs[i + 1] == "*", !hashComment {
                var j = i + 2
                while j + 1 < n, !(cs[j] == "*" && cs[j + 1] == "/") { j += 1 }
                j = min(n, j + 2)
                push(String(cs[i..<j]), .comment)
                i = j
                continue
            }
            // 字符串
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                var j = i + 1
                while j < n {
                    if cs[j] == "\\", j + 1 < n { j += 2; continue }
                    if cs[j] == quote { j += 1; break }
                    if cs[j] == "\n", quote != "`" { break }   // 没闭合，别吞掉整段
                    j += 1
                }
                push(String(cs[i..<min(j, n)]), .str)
                i = min(j, n)
                continue
            }
            // 数字
            if isDigit(c) {
                var j = i
                while j < n, isDigit(cs[j]) || cs[j] == "." || cs[j] == "x"
                        || cs[j] == "X" || cs[j] == "_" { j += 1 }
                // 让 0x1F 这种十六进制后缀也算进来
                while j < n, cs[j].isHexDigit { j += 1 }
                push(String(cs[i..<j]), .num)
                i = j
                continue
            }
            // @属性 / #指令
            if c == "@" || c == "#" {
                var j = i + 1
                while j < n, isIdentBody(cs[j]) { j += 1 }
                if j > i + 1 {
                    push(String(cs[i..<j]), .attr)
                    i = j
                    continue
                }
            }
            // 标识符 / 关键字 / 类型 / 函数名
            if isIdentStart(c) {
                var j = i
                while j < n, isIdentBody(cs[j]) { j += 1 }
                let word = String(cs[i..<j])
                var kind: Kind = .plain
                if kw.contains(word) {
                    kind = .keyword
                } else if j < n, cs[j] == "(" {
                    kind = .fn
                } else if let f = word.first, f.isUppercase {
                    kind = .type
                }
                push(word, kind)
                i = j
                continue
            }

            buf.append(c)
            i += 1
        }
        flush()
        return out
    }
}

// MARK: - 正文

/// 普通叙述段落：可以选词、长按复制，和原来一模一样。
///
/// 单独包一层只是为了让 `AssistantBody` 里两种段落写法对称，
/// 行为完全沿用 `SelectableText`（选词/长按菜单都还是那套）。
///
/// 注意：**没有**把正文里的裸网址做成可点链接。`SelectableText` 里
/// `dataDetectorTypes` 是空的，因为开了会和选词手势抢（老坑，见那边的注释）。
/// 网址在正文里仍然是普通文字，要打开就复制出去。别以为这里已经支持点按。
struct ProseText: View {
    let text: String
    /// 长按菜单里的「重新生成」（只给 AI 回复）。
    ///
    /// 2026-11-02 加：官方把「重新生成」放在长按菜单里。
    /// 传 nil 就不显示该项（用户消息走这个分支时不用管）。
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        SelectableText(
            text: text,
            allowRecall: false,
            fillsWidth: true,
            onRecall: {},
            onRecallAndEdit: {},
            onRegenerate: onRegenerate
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 整条 AI 回复

/// AI 回复的完整渲染：正文段照旧可选可复制，代码块单独成卡片带复制按钮。
///
/// ⚠️ 只在**流式结束后**用这个。流式期间仍然是那颗轻量 `Text`
/// （见 ChatView 里的 streaming 分支）—— 每来一个字就重建一堆子视图
/// 会重新引入卡顿和抖动，那是前面费了三版才压下去的东西。
struct AssistantBody: View {
    let text: String
    /// 长按正文时的「重新生成」（透传给 ProseText）。
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        let parts = RichCache.blocks(text)
        return VStack(alignment: .leading, spacing: parts.count > 1 ? 10 : 0) {
            ForEach(parts) { b in
                switch b.kind {
                case .prose(let p):
                    ProseText(text: p, onRegenerate: onRegenerate)
                case .code(let lang, let code):
                    CodeBlockView(lang: lang, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 颜色工具

extension UIColor {
    /// 0xRRGGBB 形式建色。着色表里一堆十六进制，写成十进制没法核对。
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1)
    }
}
