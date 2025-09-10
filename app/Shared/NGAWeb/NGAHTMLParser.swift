import Foundation

public struct WebThreadPage {
    public let tid: String
    public let page: Int
    public let posts: [WebPost]
    public let hasNext: Bool
}

public struct WebPost {
    public let pid: String?        // 先占位，后续细化
    public let floorNo: Int?       // 先占位，后续细化
    public let author: String      // 简易提取，容错为“匿名”
    public let timeText: String?   // 简易提取，找不到就 nil
    public let html: String        // 清洗后的 HTML（直接给现有渲染层）
}

/// 一个“零依赖”的基础解析/清洗器：
/// - 先把整页粗分为多段（根据常见 post 标记），每段做图片/链接绝对化、懒加载修正；
/// - 作者/时间做最简单的提取；
/// - 后续我们可以替换为更强的 DOM 解析（如 SwiftSoup）。
final class NGAHTMLParser {

    // 对外主入口：把 HTML → WebThreadPage
    func parseThreadPage(tid: String, page: Int, html: String) -> WebThreadPage {
        let segments = splitIntoPosts(html: html)
        var posts: [WebPost] = []

        for (idx, raw) in segments.enumerated() {
            let clean = cleanContent(raw)

            let author = extractAuthor(from: raw) ?? "匿名"
            let time   = extractTime(from: raw)
            let pid    = extractPid(from: raw)
            let floor  = extractFloorNo(from: raw)

            posts.append(WebPost(pid: pid, floorNo: floor, author: author, timeText: time, html: clean))
        }

        let hasNext = html.contains("下一页") || html.contains("下一頁") || html.contains("&gt;") || html.contains("›")
        return WebThreadPage(tid: tid, page: page, posts: posts, hasNext: hasNext)
    }

    // MARK: - 基础分段：按常见 post 容器切分，找不到就整页当一段
    private func splitIntoPosts(html: String) -> [String] {
        let markers = [
            "<div id=\"post_",           // 常见：div#post_xxx
            "<div class=\"postrow",      // 变体：div.postrow
            "<table class=\"postrow"     // 旧皮肤：table.postrow
        ]
        if let m = markers.first(where: { html.contains($0) }) {
            // 以第一个标记切分，保留标记
            let parts = html.components(separatedBy: m)
            if parts.count <= 1 { return [html] }
            var result: [String] = []
            // parts[0] 是分割前缀，通常是头部；从 1 开始拼回标记
            for i in 1..<parts.count {
                result.append(m + parts[i])
            }
            return result
        }
        return [html]
    }

    // MARK: - 作者/时间/楼层/锚点的简易提取（够用就好，后续可升级）
    private func extractAuthor(from raw: String) -> String? {
        // 寻找带 uid 的 a 标签文本
        return firstCapture(in: raw, pattern: #"<a[^>]*href="[^"]*uid=[^"]*"[^>]*>(.*?)</a>"#)
    }

    private func extractTime(from raw: String) -> String? {
        // 常见：span.posttime / .postdate / em[title]
        if let t = firstCapture(in: raw, pattern: #"<span[^>]*(posttime|postdate)[^>]*>(.*?)</span>"#, group: 2) {
            return stripHTML(t)
        }
        if let t = firstCapture(in: raw, pattern: #"<em[^>]*title="([^"]+)""#, group: 1) {
            return t
        }
        return nil
    }

    private func extractPid(from raw: String) -> String? {
        // 从 div id="post_123456" 里拿 pid
        if let pid = firstCapture(in: raw, pattern: #"<div\s+id="post_(\d+)""#, group: 1) {
            return pid
        }
        return nil
    }

    private func extractFloorNo(from raw: String) -> Int? {
        // 在“#12 / 1
