import Foundation
import UIKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - 附件

/// 一条消息可以带的东西。图片/视频走 base64 直发，
/// 文本类文件读成文字拼进 prompt，二进制文件只报文件名。
struct Attachment: Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case video
        case text      // txt/md/json/代码等，能读成文字
        case document  // pdf 等，抽出文字
        case binary    // 其它，只报名字
    }

    let id = UUID()
    var kind: Kind
    var name: String
    var byteSize: Int
    /// 图片/视频：base64；文本类：文件内容
    var payload: String
    /// 图片/视频的 MIME
    var mime: String
    /// 图片缩略图
    var thumb: UIImage?
    /// 视频封面
    var videoThumb: UIImage?
    /// 视频时长（秒）
    var duration: Double

    var isMedia: Bool { kind == .image || kind == .video }

    /// 气泡里用哪张图当预览
    var preview: UIImage? { thumb ?? videoThumb }

    var sizeText: String {
        if byteSize < 1024 { return "\(byteSize) B" }
        if byteSize < 1024 * 1024 { return String(format: "%.0f KB", Double(byteSize) / 1024) }
        return String(format: "%.1f MB", Double(byteSize) / 1024 / 1024)
    }

    var durationText: String? {
        guard kind == .video, duration > 0 else { return nil }
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 在 prompt 里怎么描述这个附件（给模型看的）
    var promptNote: String {
        switch kind {
        case .image: return "【图片：\(name)】"
        case .video: return "【视频：\(name)\(durationText.map { "，时长 \($0)" } ?? "")】"
        case .text, .document: return "【文件：\(name)】\n\(payload)"
        case .binary: return "【文件：\(name)（\(sizeText)，该格式无法预览，仅告知存在）】"
        }
    }

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 附件加工

enum AttachmentMaker {

    /// 图片压到这个长边就够了。太大只会让请求变慢、还可能被上游拒绝。
    static let maxImageEdge: CGFloat = 1400
    static let jpegQuality: CGFloat = 0.82

    /// 视频上限：超过就别发了，手机流量和上游都受不了
    static let maxVideoBytes = 18 * 1024 * 1024

    /// 一次最多带几个附件，太多会让请求体爆掉
    static let maxAttachments = 6

    /// 文本文件最多读这么多字符，避免把整本书塞进上下文
    static let maxTextChars = 120_000

    // MARK: 图片

    static func image(from data: Data, name: String) -> Attachment? {
        guard let img = UIImage(data: data) else { return nil }
        return image(from: img, name: name)
    }

    static func image(from img: UIImage, name: String = "照片.jpg") -> Attachment? {
        let resized = downscale(img, maxEdge: maxImageEdge)
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality) else { return nil }
        return Attachment(kind: .image, name: name, byteSize: jpeg.count,
                          payload: jpeg.base64EncodedString(), mime: "image/jpeg",
                          thumb: resized, videoThumb: nil, duration: 0)
    }

    /// 等比缩到长边不超过 maxEdge。已经够小就原样返回，不重采样（省内存，防 OOM）。
    static func downscale(_ img: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return img }
        let longest = max(w, h)
        guard longest > maxEdge else { return img }
        let scale = maxEdge / longest
        let target = CGSize(width: floor(w * scale), height: floor(h * scale))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: 视频

    /// 视频不做转码（手机上做不到像样的实现），只做大小检查，
    /// 超限就明确告诉用户，而不是让请求卡死半天才失败。
    static func video(from url: URL, name: String) -> (Attachment?, String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { return (nil, "读不到视频文件") }
        guard size <= maxVideoBytes else {
            return (nil, String(format: "视频 %.1f MB 太大了（上限 18 MB），请先剪短一些",
                                Double(size) / 1024 / 1024))
        }
        guard let data = try? Data(contentsOf: url) else { return (nil, "读取视频失败") }

        let asset = AVURLAsset(url: url)
        let dur = CMTimeGetSeconds(asset.duration)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "video/mp4"

        return (Attachment(kind: .video, name: name, byteSize: size,
                           payload: data.base64EncodedString(), mime: mime,
                           thumb: nil, videoThumb: videoThumbnail(asset),
                           duration: dur.isFinite ? dur : 0), nil)
    }

    static func videoThumbnail(_ asset: AVAsset) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        // 取第 0.6 秒：太靠前常是黑帧
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.6, preferredTimescale: 600),
                                            actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: 普通文件

    /// 按类型分派：文本读内容、PDF 抽文字、其它只记名字。
    /// 认不出的格式也照样能发 —— 用户至少能问「这个文件是什么」。
    static func file(from url: URL) -> Attachment? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // 从「文件」里选到的图片也当图片处理
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"].contains(ext),
           let d = try? Data(contentsOf: url), let a = image(from: d, name: name) {
            return a
        }
        if ["mp4", "mov", "m4v"].contains(ext) {
            return video(from: url, name: name).0
        }

        let textExts: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "xml",
                                     "yaml", "yml", "log", "ini", "conf", "toml", "swift",
                                     "py", "js", "ts", "jsx", "tsx", "java", "kt", "c", "h",
                                     "cpp", "hpp", "cs", "go", "rs", "rb", "php", "sh",
                                     "bash", "zsh", "sql", "html", "htm", "css", "scss", "vue"]
        if textExts.contains(ext), var s = readText(url) {
            if s.count > maxTextChars {
                s = String(s.prefix(maxTextChars)) + "\n\n…（文件太长，已截断）"
            }
            return Attachment(kind: .text, name: name, byteSize: size,
                              payload: s, mime: "text/plain",
                              thumb: nil, videoThumb: nil, duration: 0)
        }

        if ext == "pdf", var s = pdfText(url) {
            if s.count > maxTextChars {
                s = String(s.prefix(maxTextChars)) + "\n\n…（文件太长，已截断）"
            }
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Attachment(kind: .document, name: name, byteSize: size,
                                  payload: s, mime: "application/pdf",
                                  thumb: nil, videoThumb: nil, duration: 0)
            }
        }

        return Attachment(kind: .binary, name: name, byteSize: size,
                          payload: "", mime: "application/octet-stream",
                          thumb: nil, videoThumb: nil, duration: 0)
    }

    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        // 国标编码的中文文本很常见，UTF-8 读失败再试 GB18030
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = try? String(contentsOf: url, encoding: String.Encoding(rawValue: gb)) {
            return s
        }
        if let d = try? Data(contentsOf: url) {
            return String(data: d, encoding: .isoLatin1)
        }
        return nil
    }

    /// PDF 抽文字。扫描件抽不出来（没有文字层），返回 nil 让调用方按二进制处理。
    static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let n = min(doc.pageCount, 200)   // 超大 PDF 只看前 200 页，防卡死
        guard n > 0 else { return nil }
        var out: [String] = []
        for i in 0..<n {
            if let s = doc.page(at: i)?.string, !s.isEmpty { out.append(s) }
        }
        let joined = out.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - 附件 -> 请求体

enum PayloadBuilder {

    /// 把附件和文字拼成 OpenAI 多模态 content
    static func content(text: String, attachments: [Attachment]) -> Any {
        guard !attachments.isEmpty else { return text }

        // 文字类附件拼成一段放最前面，模型读起来更顺
        let notes = attachments
            .filter { $0.kind == .text || $0.kind == .document || $0.kind == .binary }
            .map { $0.promptNote }

        var userText = text
        if !notes.isEmpty {
            let joined = notes.joined(separator: "\n\n")
            userText = userText.isEmpty ? joined : userText + "\n\n" + joined
        }

        let medias = attachments.filter { $0.isMedia }

        // 没有媒体就别发数组了，纯字符串兼容性最好（老上游都认）
        if medias.isEmpty { return userText }

        var parts: [[String: Any]] = []
        if !userText.isEmpty {
            parts.append(["type": "text", "text": userText])
        }
        for a in medias {
            if a.kind == .image {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(a.mime);base64,\(a.payload)"]
                ])
            } else {
                // 视频沿用社区的 video_url 扩展；不支持的上游会忽略这一项
                parts.append([
                    "type": "video_url",
                    "video_url": ["url": "data:\(a.mime);base64,\(a.payload)"]
                ])
            }
        }
        return parts
    }
}
