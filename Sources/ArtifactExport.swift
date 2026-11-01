import SwiftUI
import UIKit
import WebKit

// MARK: - 产物导出（PDF / DOCX / Markdown）
//
// 2026-11-02 新建，对齐 WorkBuddy 手机端。
//
// 官方文档原文（两处都写了同一件事）：
//   · 「产物也支持导出到手机（PDF / DOCX / Markdown）或导出到腾讯文档」
//   · 「点击预览页面右上角的「分享」按钮 → 可以将产物导出为
//      PDF、DOCX、Markdown 或导出到腾讯文档」
//
// 我们之前只有"分享原始文件"（UIActivityViewController 扔出磁盘上那个文件），
// 用户拿到的是一个 .md/.py，手机上没法看、也没法发给别人。
// 这里补的是**格式转换**：任何产物都能转成一份排版好的 PDF 或 DOCX。
//
// 为什么 PDF 用 WKWebView 的 printFormatter 而不是 UIGraphicsImageRenderer：
//   · 渲染器只能出位图，文字不能选中、放大就糊，一份代码文件转出来没法用
//   · WKWebView 的 `viewPrintFormatter()` 出的是**矢量 PDF**，
//     文字可选中、可搜索，和系统「打印成 PDF」同一条路径
// 为什么 DOCX 用最小 OOXML 手拼而不是找库：
//   · CI 是无签名构建，不想为一个导出功能引 SPM 依赖（会拖慢每次打包）
//   · 我们只需要「一段文字 + 等宽段落」，OOXML 的 document.xml 结构很固定，
//     手拼一份 40 行的模板就够了，Word / WPS / iOS Pages 都能打开
// 腾讯文档导出需要授权和账号，没做（点了会提示不支持的，别假装有）

// MARK: - 入口

enum ArtifactExport {

    /// 导出格式。
    enum Format: String, CaseIterable, Identifiable {
        case pdf = "PDF"
        case docx = "Word"
        case markdown = "Markdown"

        var id: String { rawValue }

        var ext: String {
            switch self {
            case .pdf: return "pdf"
            case .docx: return "docx"
            case .markdown: return "md"
            }
        }

        var icon: String {
            switch self {
            case .pdf: return "doc.richtext"
            case .docx: return "doc.text"
            case .markdown: return "text.alignleft"
            }
        }

        var hint: String {
            switch self {
            case .pdf: return "排版好，谁都能看"
            case .docx: return "可以用 Word / WPS 继续改"
            case .markdown: return "纯文本，保留原文"
            }
        }
    }

    /// 把产物按指定格式导出到临时目录，返回可分享的 URL。
    ///
    /// 返回 nil 表示这一步做不了（比如源文件读不出来），
    /// 界面据此提示用户，而不是弹一个空的分享面板让他以为成功了。
    ///
    /// ⚠️ **只能在主线程调用**：PDF 那一路要建 WKWebView、要用
    /// `UIGraphicsBeginPDFContextToFile`，两者都是 UIKit/WebKit 的主线程要求。
    /// 调用方是按钮回调，本来就在主线程，这里用 `dispatchPrecondition` 把这个
    /// 前提写死 —— 将来谁想在后台线程调，会在开发期直接崩，而不是上线后偶发空白 PDF。
    static func render(_ file: AIFile, as format: Format) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        let text = readText(file)
        let stem = (file.fileName as NSString).deletingPathExtension
        let outName = "\(stem).\(format.ext)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(outName)
        try? FileManager.default.removeItem(at: out)

        switch format {
        case .markdown:
            // 原样导出：文字类直接把读到的内容写出去，
            // 非文字类（图片等）退回复制原文件，否则会导出一个空 md
            guard let text = text else {
                let dst = dir.appendingPathComponent(file.fileName)
                try? FileManager.default.removeItem(at: dst)
                guard (try? FileManager.default.copyItem(at: file.url, to: dst)) != nil else {
                    return nil
                }
                return dst
            }
            return (try? text.write(to: out, atomically: true, encoding: .utf8)) != nil ? out : nil

        case .pdf:
            guard let text = text else { return nil }
            let html = htmlPage(title: stem, body: text)
            // WKWebView 的 PDF 生成是异步的，而这里要同步返回。
            // 用一个小的 runloop 泵等它完成 —— 导出是用户主动点的、
            // 有明确的"正在生成"预期，阻塞几百毫秒可以接受（有超时兜底）。
            return renderPDF(html: html, to: out)

        case .docx:
            guard let text = text else { return nil }
            return writeDOCX(text: text, title: stem, to: out)
        }
    }

    // MARK: 读源文件

    /// 把产物读成纯文字。图片 / 二进制返回 nil。
    static func readText(_ file: AIFile) -> String? {
        let ext = file.url.pathExtension.lowercased()
        let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic",
                                   "mp4", "mov", "m4a", "mp3", "zip", "deb",
                                   "pdf", "docx", "xlsx", "pptx", "bin", "dat"]
        guard !binary.contains(ext) else { return nil }
        // 先按 UTF-8 读，失败再试 GB18030（有些老脚本是 GBK 写的）
        if let s = try? String(contentsOf: file.url, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return try? String(contentsOf: file.url, encoding: String.Encoding(rawValue: gb))
    }

    // MARK: PDF

    /// 同步把 HTML 渲染成 PDF。
    private static func renderPDF(html: String, to out: URL) -> URL? {
        final class Box {
            var ready = false
            var tried = false
        }
        let box = Box()
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: cfg)
        // A4 = 595 × 842 pt。按 A4 宽排版，打印出来正好。
        web.loadHTMLString(html, baseURL: nil)

        // 等它真的排版完。
        //
        // ⚠️ 不能用 `web.isLoading` 判断：`loadHTMLString` 是**异步启动**的，
        // 返回那一刻 isLoading 还是 false，直接判会得到"已经加载完"的假信号，
        // 于是拿到一个空白页 —— 导出的 PDF 一个字都没有。
        // 这里改成拿 JS 回调当作"确实可以排版了"的信号：
        // 能在页面里执行 JS，说明 DOM 已就绪。
        //
        // 为什么要自己泵 RunLoop 而不是 async/await：
        // `render()` 是从按钮回调里同步调用的（几百毫秒，用户有"正在生成"的预期）。
        // 回调都在主线程，用信号量阻塞主线程会死锁，只能泵 runloop。
        // 6 秒是兜底：字体加载失败之类的情况也要能返回，不能让界面卡死。
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !box.tried {
                box.tried = true
                web.evaluateJavaScript("document.readyState") { _, _ in
                    // readyState 是 interactive 或 complete 都算可以排版了
                    box.ready = true
                }
            }
            if box.ready { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        guard box.ready else { return nil }

        // 用 printFormatter 出 PDF（矢量、可选中）
        let fmt = web.viewPrintFormatter()
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(fmt, startingAtPageAt: 0)

        let paper = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 36
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: margin, dy: margin)),
                          forKey: "printableRect")

        // 先让渲染器排版，再按页数出图
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))

        UIGraphicsBeginPDFContextToFile(out.path, paper, nil)
        defer { UIGraphicsEndPDFContext() }
        let pages = max(1, renderer.numberOfPages)
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }

    /// 生成一份适合打印的 HTML。
    private static func htmlPage(title: String, body: String) -> String {
        let esc = escapeHTML(body)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font-family: -apple-system, "PingFang SC", sans-serif;
                 font-size: 12pt; line-height: 1.6; color: #111; margin: 0; }
          h1 { font-size: 18pt; margin: 0 0 4pt 0; }
          .meta { color: #888; font-size: 9pt; margin-bottom: 16pt; }
          pre { font-family: ui-monospace, Menlo, monospace; font-size: 10pt;
                line-height: 1.45; background: #f5f5f7; padding: 10pt;
                border-radius: 6pt; white-space: pre-wrap; word-break: break-word; }
          code { font-family: ui-monospace, Menlo, monospace; }
        </style></head><body>
        <h1>\(escapeHTML(title))</h1>
        <div class="meta">导出时间 \(dateText())</div>
        <pre>\(esc)</pre>
        </body></html>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func dateText() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    // MARK: DOCX

    /// 写一份最小可用的 .docx。
    ///
    /// 结构就是 OOXML 的最小集合：
    ///   [Content_Types].xml
    ///   _rels/.rels
    ///   word/document.xml
    /// 三个文件打成一个 zip、扩展名改成 .docx 就是合法文档。
    ///
    /// 为什么不带 styles.xml：等宽字体和字号都直接写在 rPr 里，
    /// 少一个部件少一处出错的地方。Word / WPS / Pages 都能正常打开。
    private static func writeDOCX(text: String, title: String, to out: URL) -> URL? {
        // zip 是 UTI 的 public.zip-archive；用 NSMutableData + 手写 central directory
        // 太重了。这里退回一个更省事的办法：让系统帮我们压缩一个目录。
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try contentTypes.write(to: tmpDir.appendingPathComponent("[Content_Types].xml"),
                                   atomically: true, encoding: .utf8)
            let relsDir = tmpDir.appendingPathComponent("_rels", isDirectory: true)
            try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
            try rootRels.write(to: relsDir.appendingPathComponent(".rels"),
                               atomically: true, encoding: .utf8)
            let wordDir = tmpDir.appendingPathComponent("word", isDirectory: true)
            try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
            try documentXML(title: title, text: text)
                .write(to: wordDir.appendingPathComponent("document.xml"),
                       atomically: true, encoding: .utf8)

            // 用 FileManager 的 zip 能力（iOS 16+ 的 Archive API 不够稳，走 /usr/bin/zip 不存在）。
            // 这里用 CoordinatedZip：见下方 ZipWriter。
            guard let zip = ZipWriter.zip(directory: tmpDir) else { return nil }
            return (try? zip.write(to: out)) != nil ? out : nil
        } catch {
            return nil
        }
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func documentXML(title: String, text: String) -> String {
        // 每一行一个 <w:p>，保留空行（空行也是一个段落）。
        // 这样做的好处是代码的缩进和分行原样保留 —— 用一整段 +
        // 换行符的方式，Word 会把它当软回车，代码就糊成一团了。
        let lines = text.components(separatedBy: "\n")
        var paras = ""
        // 标题段：加粗、大一号
        paras += """
        <w:p><w:r><w:rPr><w:b/><w:sz w:val="32"/></w:rPr>\
        <w:t xml:space="preserve">\(xmlEsc(title))</w:t></w:r></w:p>
        """
        for line in lines {
            paras += """
            <w:p><w:r><w:rPr>\
            <w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="PingFang SC"/>\
            <w:sz w:val="20"/></w:rPr>\
            <w:t xml:space="preserve">\(xmlEsc(line))</w:t></w:r></w:p>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(paras)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>\
        </w:body></w:document>
        """
    }

    private static func xmlEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            // XML 1.0 不允许这些控制字符，原样写进去整份文档会打不开
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\u{8}", with: "")
            .replacingOccurrences(of: "\u{B}", with: "")
            .replacingOccurrences(of: "\u{C}", with: "")
            .replacingOccurrences(of: "\u{1B}", with: "")
    }
}

// MARK: - 极简 ZIP

/// 只够用来打包 docx 的最小 zip 写入器（store 压缩，不压缩数据）。
///
/// 为什么不用 Compression 框架自己拼 deflate：
///   · docx 里都是小 XML，不压缩体积也就几十 KB，完全没必要
///   · store 模式（method 0）的 zip 结构最简单，出错面最小
/// 为什么不用第三方库：CI 是无签名构建，不为导出功能引 SPM 依赖。
enum ZipWriter {

    /// 把目录下所有文件（递归）打成一个 zip 的 Data。
    static func zip(directory: URL) -> Data? {
        var entries: [(path: String, data: Data)] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for case let url as URL in en {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            guard let data = try? Data(contentsOf: url) else { return nil }
            var rel = url.path.replacingOccurrences(of: directory.path, with: "")
            if rel.hasPrefix("/") { rel.removeFirst() }
            entries.append((rel, data))
        }
        guard !entries.isEmpty else { return nil }
        // OOXML 要求 [Content_Types].xml 是第一个条目（部分解析器会检查）
        entries.sort { a, b in
            if a.path.hasPrefix("[Content_Types]") { return true }
            if b.path.hasPrefix("[Content_Types]") { return false }
            return a.path < b.path
        }
        return build(entries)
    }

    private static func build(_ entries: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offset: UInt32 = 0
        let now = Date()
        let cal = Calendar.current
        let dosTime = UInt16((cal.component(.hour, from: now) << 11)
                             | (cal.component(.minute, from: now) << 5)
                             | (cal.component(.second, from: now) / 2))
        let y = max(1980, cal.component(.year, from: now) - 1980)
        let dosDate = UInt16((y << 9) | (cal.component(.month, from: now) << 5)
                             | cal.component(.day, from: now))

        for e in entries {
            let nameData = Data(e.path.utf8)
            let crc = crc32(e.data)
            let size = UInt32(e.data.count)

            // local file header
            var local = Data()
            local.append(uint32: 0x04034b50)
            local.append(uint16: 20)          // version needed
            local.append(uint16: 0)           // flags
            local.append(uint16: 0)           // method 0 = store
            local.append(uint16: dosTime)
            local.append(uint16: dosDate)
            local.append(uint32: crc)
            local.append(uint32: size)        // compressed size
            local.append(uint32: size)        // uncompressed size
            local.append(uint16: UInt16(nameData.count))
            local.append(uint16: 0)           // extra len
            local.append(nameData)
            local.append(e.data)

            out.append(local)

            // central directory entry
            central.append(uint32: 0x02014b50)
            central.append(uint16: 20)        // version made by
            central.append(uint16: 20)        // version needed
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: dosTime)
            central.append(uint16: dosDate)
            central.append(uint32: crc)
            central.append(uint32: size)
            central.append(uint32: size)
            central.append(uint16: UInt16(nameData.count))
            central.append(uint16: 0)         // extra
            central.append(uint16: 0)         // comment
            central.append(uint16: 0)         // disk
            central.append(uint16: 0)         // internal attrs
            central.append(uint32: 0)         // external attrs
            central.append(uint32: offset)    // local header offset
            central.append(nameData)

            offset += UInt32(local.count)
        }

        let cdOffset = UInt32(out.count)
        out.append(central)

        // end of central directory
        out.append(uint32: 0x06054b50)
        out.append(uint16: 0)                 // disk
        out.append(uint16: 0)                 // cd start disk
        out.append(uint16: UInt16(entries.count))
        out.append(uint16: UInt16(entries.count))
        out.append(uint32: UInt32(central.count))
        out.append(uint32: cdOffset)
        out.append(uint16: 0)                 // comment len
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func append(uint32 v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}

// MARK: - 导出选择弹窗

/// 点产物 → 选导出格式的底部弹窗。
///
/// 对齐官方：点预览页右上角「分享」→ 选 PDF / DOCX / Markdown。
/// 这里做成一个独立的 sheet，选完格式直接弹系统分享面板，
/// 用户可以存到"文件"、发微信、发邮件。
struct ExportFormatSheet: View {
    let file: AIFile
    /// 选完格式后回调（拿到转换后的文件 URL）
    let onPicked: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 正在转换的那个格式（转换要几百毫秒，得让用户看到在动）
    @State private var working: ArtifactExport.Format?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部一条小横杠：告诉用户这个卡片可以往下拉关掉
            Capsule()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 3) {
                Text("导出为")
                    .font(.system(size: 17, weight: .semibold))
                Text(file.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)

            VStack(spacing: 8) {
                ForEach(ArtifactExport.Format.allCases) { f in
                    row(f)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Button("取消") { dismiss() }
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 6)
        .background(Theme.page)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ f: ArtifactExport.Format) -> some View {
        Button {
            guard working == nil else { return }
            working = f
            Haptic.press()
            // 转换放到下一轮 runloop：给按钮一个"按下去"的反馈帧，
            // 不然同步转换会卡住这一帧，用户以为没点着。
            DispatchQueue.main.async {
                let url = ArtifactExport.render(file, as: f)
                working = nil
                if let url = url {
                    dismiss()
                    // 等 sheet 关完再弹分享，两个 sheet 同帧会互相吞
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        onPicked(url)
                    }
                } else {
                    // 转换失败（源文件读不出来 / 渲染超时）：震一下，别静默什么都不发生
                    Haptic.hard()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: f.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint(f))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(f.rawValue)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    Text(f.hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if working == f {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97, fills: true))
        .disabled(working != nil)
    }

    private func tint(_ f: ArtifactExport.Format) -> Color {
        switch f {
        case .pdf: return Color(red: 0.85, green: 0.26, blue: 0.24)
        case .docx: return Color(red: 0.16, green: 0.42, blue: 0.78)
        case .markdown: return Color(red: 0.32, green: 0.34, blue: 0.40)
        }
    }
}
