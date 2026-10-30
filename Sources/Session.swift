import Foundation

// MARK: - 底部导航

/// 对齐 WorkBuddy 手机端的底部入口。
///
/// 2026-10-30 按用户要求改成三个：
///   「任务」聊天主界面
///   「后台面板」点一下直接进中转站网页后台（App 内嵌，免登录）
///   「我的」点进去直接就是设置页
/// 原来的「发现」删掉了（官方内容广场，咱们没有内容源）。
///
/// 2026-10-31 用户要求「后台面板和我的位置换一下」：
/// 底部顺序从「任务 / 后台面板 / 我的」改成「任务 / 我的 / 后台面板」。
/// 注意 **case 的声明顺序就是 Tab 的显示顺序**（靠 CaseIterable 遍历），
/// 所以这里必须真的把两个 case 调换位置，不是改个显示名就行。
enum MainTab: String, CaseIterable, Identifiable {
    case tasks = "任务"
    case mine = "我的"
    case admin = "后台面板"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tasks: return "bubble.left.and.bubble.right"
        case .admin: return "square.grid.2x2"
        case .mine: return "person"
        }
    }

    var iconFilled: String {
        switch self {
        case .tasks: return "bubble.left.and.bubble.right.fill"
        case .admin: return "square.grid.2x2.fill"
        case .mine: return "person.fill"
        }
    }
}

// MARK: - 会话（抽屉里的「任务」）

/// 落盘用的消息结构。
///
/// 为什么不直接把 ChatMessage 编成 Codable：
/// ChatMessage 带 UIImage / 视频 Data，一张图就几 MB，
/// 几十条历史就能把 JSON 撑到几百 MB，读写都卡。所以历史只存文字，
/// 附件本身不进历史（重看旧对话时图片位置会变成一行说明）。
struct StoredMessage: Codable, Hashable {
    var role: String
    var text: String
    var model: String
    var failed: Bool

    init(role: String, text: String, model: String = "", failed: Bool = false) {
        self.role = role
        self.text = text
        self.model = model
        self.failed = failed
    }

    init(_ m: ChatMessage) {
        role = m.role
        text = m.text
        model = m.model
        failed = m.failed
    }

    /// 还原成界面用的消息。附件不再保留，但给个可见的痕迹，
    /// 免得用户以为「我当时明明发了张图」。
    func toChatMessage() -> ChatMessage {
        var msg = ChatMessage(role: role, text: text, model: model)
        msg.failed = failed
        return msg
    }
}

struct Session: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var messages: [StoredMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// 归属的自定义分组。nil = 未分组（按时间归档）
    var groupId: String?

    var isEmpty: Bool { messages.isEmpty }

    /// 没有标题时用第一条用户消息凑一个
    var displayTitle: String {
        if !title.isEmpty { return title }
        return "新对话"
    }

    var previewText: String {
        if let last = messages.last(where: { !$0.text.isEmpty }) {
            let t = last.text.replacingOccurrences(of: "\n", with: " ")
            return String(t.prefix(60))
        }
        return "还没有消息"
    }
}

// MARK: - 自定义分组

/// 抽屉里用户自己建的分组。
///
/// 为什么要它：会话一多，按「今天/昨天」找太费劲。用户想把某几个对话
/// 长期留在一个分组里（比如「工作」「折腾路由器」），所以单独存一份。
struct TaskGroup: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date()
}

// MARK: - 会话存储

/// 存到 Application Support 下的一个 JSON 文件。
/// 用文件而不是 UserDefaults：历史会长，UserDefaults 是给少量偏好用的，
/// 塞大块数据进去会拖慢整个 App 的启动（它每次启动都要整份读进内存）。
enum SessionStore {
    private static let fileName = "sessions.json"
    private static let maxSessions = 200

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [Session] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        // 读的是解码策略（编码策略是 JSONEncoder 的属性，写到 JSONDecoder 上编译不过）
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Session].self, from: data)) ?? []
    }

    static func save(_ sessions: [Session]) {
        guard let url = fileURL else { return }
        // 只留最近的若干个，别让文件无限长
        let trimmed = Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxSessions))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 分组单独一个文件。和会话分开存的原因：分组数量少、改动频繁
/// （改名/新建），混在会话大文件里每次都要重写几十 KB。
enum GroupStore {
    private static let fileName = "groups.json"

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [TaskGroup] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([TaskGroup].self, from: data)) ?? []
    }

    static func save(_ groups: [TaskGroup]) {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(groups) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 按时间分组

enum SessionGroup: String, CaseIterable {
    case today = "今天"
    case yesterday = "昨天"
    case week = "近 7 天"
    case earlier = "更早"

    /// 一个会话属于哪一组
    static func group(of date: Date, now: Date = Date()) -> SessionGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: now)).day ?? 99
        return days <= 7 ? .week : .earlier
    }
}

/// 分组结果。用结构体而不是元组：Swift 的 KeyPath 不支持元组元素，
/// ForEach(_, id: \.group) 在元组上编译不过。
struct SessionBucket: Identifiable {
    var id: String { group.rawValue }
    let group: SessionGroup
    let items: [Session]
}
