import Foundation
import SwiftUI
import UIKit
import QuickLook

// MARK: - 我的文件（AI 产物，存在手机本地）

/// 一条本地文件记录。
///
/// 为什么单独存一份 meta 而不是每次现扫目录：
///   - 列表要显示「来自哪个会话」，而文件名里塞会话名会被非法字符限制住；
///   - 排序要按生成时间，不能依赖文件系统 mtime（同步/备份会改它）。
/// 真身是 Documents/AIFiles/ 下的文件，meta 只是索引。
struct AIFile: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    /// 磁盘上的文件名（含扩展名），不带目录
    var fileName: String
    /// 展示用的标题（一般就是会话名）
    var title: String
    /// 归属会话 id，用来在聊天页过滤「这条回复的产物」
    var sessionId: String
    /// 归属的那条消息下标，-1 表示整段会话导出
    var messageIndex: Int = -1
    var kind: Kind = .markdown
    var size: Int = 0
    var createdAt: Date = Date()
    /// 归属的会话文件夹名。空 = 老版本数据，落在根目录。
    ///
    /// 为什么要单独存"文件夹名"而不是每次从 sessionId 现算：
    /// 会话改名后文件夹也要跟着改名，而改文件夹是「移动文件」的重操作。
    /// 存下来的好处是：能快速判断「这个文件的目录还在不在原位」，
    /// 也方便做迁移（老数据没有这个字段，解码时默认为空）。
    var folder: String = ""

    enum Kind: String, Codable {
        case markdown
        case text
        case code
        case image
        case other

        var icon: String {
            switch self {
            case .markdown: return "doc.text.fill"
            case .text: return "text.alignleft"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .image: return "photo.fill"
            case .other: return "questionmark.square.dashed"
            }
        }

        var label: String {
            switch self {
            case .markdown: return "MD"
            case .text: return "TXT"
            case .code: return "CODE"
            case .image: return "图片"
            case .other: return "文件"
            }
        }

        /// 图标颜色。一色一类，扫一眼就知道这堆里有什么。
        ///
        /// 用固定 RGB 而不是 .tint：整页如果都是同一个强调色，
        /// 一下就退化成「一排一样的方块」，分类信息等于没有。
        /// 这几个色号在浅色/深色下都压得住白底和 #1C1C1E。
        var tint: Color {
            switch self {
            case .markdown: return Color(red: 0.06, green: 0.60, blue: 0.46)   // 青
            case .text:     return Color(red: 0.42, green: 0.45, blue: 0.50)   // 灰
            case .code:     return Color(red: 0.49, green: 0.36, blue: 0.84)   // 紫
            case .image:    return Color(red: 0.17, green: 0.48, blue: 0.90)   // 蓝
            case .other:    return Color(red: 0.29, green: 0.50, blue: 0.84)   // 蓝
            }
        }
    }

    /// 给人看的文件名：去掉时间戳那一段。
    ///
    /// 磁盘上必须留时间戳（同一秒生成两个同名文件会互相覆盖），
    /// 但列表里显示「刷机指南-20261031-001030.md」纯属噪音 ——
    /// 用户认的是「刷机指南.md」，时间戳他根本不看。
    var displayName: String {
        let ext = (fileName as NSString).pathExtension
        var stem = (fileName as NSString).deletingPathExtension
        // 尾部形如 -20261031-001030 或 -20261031-001030-2
        if let r = stem.range(of: #"-\d{8}-\d{6}(-\d+)?$"#, options: .regularExpression) {
            stem = String(stem[stem.startIndex..<r.lowerBound])
        }
        if stem.isEmpty { stem = title.isEmpty ? "未命名" : title }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// 「841.5 KB」这种人话
    var sizeText: String {
        if size <= 0 { return "-" }
        if size < 1024 { return "\(size) B" }
        let kb = Double(size) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    var url: URL {
        if folder.isEmpty {
            return FileStore.dir.appendingPathComponent(fileName)
        }
        return FileStore.dir.appendingPathComponent(folder).appendingPathComponent(fileName)
    }
}

// MARK: - 存储

/// 文件落盘的地方：App 沙盒的 Documents/AIFiles/。
///
/// 为什么选 Documents 而不是 Caches：
///   - Caches 会被系统在空间紧张时**直接删掉**，用户存的东西不该这样消失；
///   - Documents 会进 iCloud 备份（如果用户开了），换手机能带走。
/// 代价是占用户 iCloud 空间，但这些是我们自己生成的几 KB 文本，可以接受。
enum FileStore {
    static let dirName = "AIFiles"
    private static let metaName = "index.json"
    /// 总量上限。超过就删最旧的 —— 手机空间是用户的，不能无限吃。
    private static let maxBytes = 80 * 1024 * 1024

    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(dirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private static var metaURL: URL { dir.appendingPathComponent(metaName) }

    static func load() -> [AIFile] {
        guard let data = try? Data(contentsOf: metaURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([AIFile].self, from: data)) ?? []
    }

    static func save(_ files: [AIFile]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(files) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    /// 文件名里的非法字符换成下划线。
    /// iOS 文件名允许很多字符，但「/」和「:」一定不行；
    /// 另外把换行、Tab 也换掉，否则列表里会出现诡异断行。
    static func sanitize(_ s: String) -> String {
        var t = s
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"] {
            t = t.replacingOccurrences(of: ch, with: "_")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = "未命名" }
        // 太长会被某些文件系统拒，压到 60 字
        if t.count > 60 { t = String(t.prefix(60)) }
        return t
    }

    // MARK: 会话文件夹

    /// 每个会话一个独立文件夹，名字就是会话名。
    ///
    /// 用户原话：「二个会话，就要二个文件夹储存，自己储存自己的」。
    /// 这样在「文件」App 里连上手机也能一眼看出哪堆是哪个对话的产物。
    ///
    /// 防重名：两个会话可能同名（都叫「新对话」），所以文件夹名后面
    /// 挂一小段会话 id。用户看到的是「中转站搭建-a3f2」，
    /// 虽然多几个字符，但绝不会出现「两个文件夹同名互相覆盖」。
    static func folderName(title: String, sessionId: String) -> String {
        let base = sanitize(title)
        let tail = String(sessionId.suffix(4)).lowercased()
        return "\(base)-\(tail)"
    }

    /// 拿到（必要时创建）某个会话的文件夹 URL
    static func folder(for title: String, sessionId: String) -> URL {
        let name = folderName(title: title, sessionId: sessionId)
        let d = dir.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 会话改名时，把文件夹跟着改名。
    ///
    /// 为什么用「建新目录 + 移动文件」而不是只改记录里的 folder 字段：
    /// 只改字段的话磁盘上还是老名字，用户去「文件」App 里看到的
    /// 和 App 里显示的对不上 —— 那就失去了"按会话命名"的意义。
    ///
    /// 返回受影响的新记录（folder 已更新）。失败时原样返回。
    static func renameFolder(oldFiles: [AIFile],
                             newTitle: String,
                             sessionId: String) -> [AIFile] {
        let mine = oldFiles.filter { $0.sessionId == sessionId }
        guard !mine.isEmpty else { return oldFiles }

        let oldFolder = mine.first?.folder ?? ""
        let newFolder = folderName(title: newTitle, sessionId: sessionId)
        // 老数据可能没有 folder（空），这种情况直接把它归到新文件夹里
        if oldFolder == newFolder, !oldFolder.isEmpty {
            return oldFiles
        }

        let oldDir = oldFolder.isEmpty
            ? dir
            : dir.appendingPathComponent(oldFolder, isDirectory: true)
        let newDir = dir.appendingPathComponent(newFolder, isDirectory: true)

        if !FileManager.default.fileExists(atPath: newDir.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        }

        var out = oldFiles
        for i in out.indices where out[i].sessionId == sessionId {
            let src = oldDir.appendingPathComponent(out[i].fileName)
            var dstName = out[i].fileName
            var dst = newDir.appendingPathComponent(dstName)
            // 目标已存在就加序号，别覆盖
            var n = 1
            while FileManager.default.fileExists(atPath: dst.path) {
                n += 1
                let ext = (dstName as NSString).pathExtension
                let stem = (dstName as NSString).deletingPathExtension
                dstName = "\(stem)-\(n).\(ext)"
                dst = newDir.appendingPathComponent(dstName)
            }
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.moveItem(at: src, to: dst)
            }
            out[i].fileName = dstName
            out[i].folder = newFolder
        }

        // 老目录空了就删掉（只删我们自己的子目录，绝不动根目录）
        if !oldFolder.isEmpty, oldFolder != newFolder {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path)) ?? []
            // index.json 是根目录的，不是子目录的，这里不用担心它
            if left.isEmpty {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
        return out
    }

    /// 写一个文本文件，返回记录。
    ///
    /// `sessionTitle` 决定放哪个文件夹（每个会话一个）。
    /// 文件名形如「问题前 30 字-20261031-0010.md」。
    @discardableResult
    static func writeText(title: String,
                          body: String,
                          ext: String = "md",
                          sessionId: String,
                          sessionTitle: String = "",
                          messageIndex: Int = -1) -> AIFile? {
        let fdir = folder(for: sessionTitle.isEmpty ? title : sessionTitle,
                          sessionId: sessionId)
        let folder = fdir.lastPathComponent

        let base = sanitize(title)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: Date())
        var name = "\(base)-\(stamp).\(ext)"
        // 同秒重复（极少数）加个后缀，别覆盖
        var n = 1
        while FileManager.default.fileExists(atPath: fdir.appendingPathComponent(name).path) {
            n += 1
            name = "\(base)-\(stamp)-\(n).\(ext)"
        }
        let url = fdir.appendingPathComponent(name)
        guard let data = body.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let rec = AIFile(fileName: name,
                         title: base,
                         sessionId: sessionId,
                         messageIndex: messageIndex,
                         kind: ext.lowercased() == "md" ? .markdown : .text,
                         size: data.count,
                         folder: folder)
        return rec
    }

    /// 复制一个外部文件进库（比如用户从相册/文件选进来的）
    @discardableResult
    static func adopt(url src: URL, title: String, sessionId: String,
                      sessionTitle: String = "") -> AIFile? {
        let ext = src.pathExtension.isEmpty ? "dat" : src.pathExtension
        let fdir = folder(for: sessionTitle.isEmpty ? title : sessionTitle,
                          sessionId: sessionId)
        let folder = fdir.lastPathComponent

        let base = sanitize(title)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        var name = "\(base)-\(df.string(from: Date())).\(ext)"
        var n = 1
        var dst = fdir.appendingPathComponent(name)
        while FileManager.default.fileExists(atPath: dst.path) {
            n += 1
            name = "\(base)-\(df.string(from: Date()))-\(n).\(ext)"
            dst = fdir.appendingPathComponent(name)
        }
        do {
            // 安全作用域：从「文件」App 拿到的 URL 必须先申请
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            return nil
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: dst.path))?[.size] as? Int) ?? 0
        let kind: AIFile.Kind
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": kind = .image
        case "md": kind = .markdown
        case "txt": kind = .text
        case "swift", "py", "js", "ts", "json", "sh", "c", "h", "cpp", "html", "css", "yaml", "yml":
            kind = .code
        default: kind = .other
        }
        return AIFile(fileName: name, title: base, sessionId: sessionId,
                      kind: kind, size: size, folder: folder)
    }

    static func delete(_ f: AIFile) {
        try? FileManager.default.removeItem(at: f.url)
        // 会话文件夹空了就顺手删，别在磁盘上留一堆空目录
        if !f.folder.isEmpty {
            let d = dir.appendingPathComponent(f.folder, isDirectory: true)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            if left.isEmpty { try? FileManager.default.removeItem(at: d) }
        }
    }

    /// 超量清理：按创建时间从旧到新删，直到总量回到上限以下。
    /// 保留最新的那一个，避免用户刚生成就被自己清掉。
    static func trim(_ files: [AIFile]) -> [AIFile] {
        var list = files.sorted { $0.createdAt > $1.createdAt }
        var total = list.reduce(0) { $0 + $1.size }
        while total > maxBytes, list.count > 1 {
            if let last = list.popLast() {
                total -= last.size
                delete(last)
            }
        }
        return list
    }

    /// 这个已有文件是不是「旧版误存的聊天记录」。
    ///
    /// 判据就一条：**里面没有代码块**。
    ///
    /// 为什么敢这么判：2026-10-31 之后产物只收代码块/文件内容块
    /// （见 ChatStore.archiveReply），所以库里纯文字的 md 全都是
    /// 老逻辑把整段聊天正文存下来的残渣 —— 用户原话
    /// 「我不需要的是把 ai 的聊天记录都当成产物」。
    ///
    /// 只看 md / txt：图片、代码文件这些一律不动，那不是聊天能存出来的。
    /// 大文件也不读整段，直接看头部 32KB 就够判断有没有 ```。
    static func isChatArchive(_ f: AIFile) -> Bool {
        guard f.kind == .markdown || f.kind == .text else { return false }
        guard let h = try? FileHandle(forReadingFrom: f.url) else { return false }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 32768)) ?? Data()
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return !s.contains("```")
    }
}

// MARK: - 全局文件库

/// 给界面用的可观察包装。
///
/// 为什么单独一个单例而不是塞进 ChatStore：
/// 抽屉、我的文件页、聊天页都要读它，但它们的生命周期不同
/// （抽屉每次滑出都重建）。用 @StateObject 各建一份会各自加载、
/// 互不同步；单例 + @ObservedObject 才能保证「存完立刻到处可见」。
@MainActor
final class FileLibrary: ObservableObject {
    static let shared = FileLibrary()

    @Published var files: [AIFile] = []

    private init() {
        files = FileStore.load()
        // 启动时清一次孤儿记录（文件被系统清掉、但 index 还在）
        let alive = files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if alive.count != files.count {
            files = alive
            FileStore.save(files)
        }
    }

    /// 加一条。会顺手做超量清理。
    func add(_ f: AIFile) {
        files.insert(f, at: 0)
        files = FileStore.trim(files)
        FileStore.save(files)
    }

    /// 整体替换（会话改名后，folder 字段全变了）。
    func replaceAll(_ list: [AIFile]) {
        files = list
        FileStore.save(files)
    }

    /// 某个会话的文件夹在磁盘上叫什么（给「我的文件」页显示路径用）
    func folderName(sessionTitle: String, sessionId: String) -> String {
        if let f = files.first(where: { $0.sessionId == sessionId && !$0.folder.isEmpty }) {
            return f.folder
        }
        return FileStore.folderName(title: sessionTitle, sessionId: sessionId)
    }

    func remove(_ f: AIFile) {
        FileStore.delete(f)
        files.removeAll { $0.id == f.id }
        FileStore.save(files)
    }

    func remove(ids: Set<String>) {
        for f in files where ids.contains(f.id) { FileStore.delete(f) }
        files.removeAll { ids.contains($0.id) }
        FileStore.save(files)
    }

    /// 某个会话产生的文件（聊天页尾端「全部产物」用）
    func files(sessionId: String) -> [AIFile] {
        files.filter { $0.sessionId == sessionId }
    }

    /// 重新从磁盘读一遍索引，顺手清掉「记录还在、文件没了」的孤儿。
    /// 面板下拉刷新走这里：别的时候 App 不会主动重读，
    /// 但用户下拉就是在说「我不信这是最新的」。
    func reload() {
        var list = FileStore.load()
        list = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        files = list.sorted { $0.createdAt > $1.createdAt }
        FileStore.save(files)
    }

    /// 按关键词搜（标题 + 文件名）
    func search(_ q: String) -> [AIFile] {
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return files }
        return files.filter {
            $0.title.lowercased().contains(key) || $0.fileName.lowercased().contains(key)
        }
    }

    var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    var totalSizeText: String {
        let b = Double(totalSize)
        if b < 1024 { return "\(totalSize) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1024 / 1024)
    }
}

// MARK: - 分享 / 预览

/// 系统分享面板。用来把文件发给微信、存到「文件」App、隔空投送。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// 快速预览（QuickLook）。PDF、图片、文本都能直接看，不用自己写渲染。
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// 「保存」：把产物另存到「文件」App（iCloud 云盘 / 我的 iPhone / 其它位置）。
///
/// 为什么不用 SwiftUI 的 `fileExporter`：那套要包一个 FileDocument，
/// 每种类型都得单独实现一遍；UIDocumentPicker 支持任意类型、支持一次多个，
/// 弹出来的还是系统标准的「存到哪里」界面，用户一看就懂。
///
/// `asCopy: true` 是关键：库里那份必须留着，否则「保存」等于搬家。
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
}
