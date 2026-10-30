import Foundation

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
