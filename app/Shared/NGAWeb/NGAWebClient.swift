import Foundation

enum WebFetchError: Error {
    case invalidURL
    case empty
    case http(Int)
    case network(Error)
}

struct WebThreadHTML {
    let tid: String
    let page: Int
    let html: String
}

final class NGAWebClient {

    static let shared = NGAWebClient()

    private let session: URLSession
    private let base = URL(string: "https://nga.178.com")!

    /// 固定一个“像手机浏览器”的 UA，稳定不要频繁变化
    private let ua = "Mozilla/5.0 (Linux; Android 11; WebView) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    private init() {
        let cfg = URLSessionConfiguration.default
        // 帖子详情/翻页：并发=1，降低触发风控的概率
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: cfg)
    }

    /// 拉取帖子 HTML（read.php?tid=&page=）
    /// - 参数 referer: 可选，指向对应板块页，更像真人浏览
    func fetchThreadHTML(tid: String, page: Int, referer: URL? = nil) async throws -> WebThreadHTML {
        var comps = URLComponents(url: base.appendingPathComponent("read.php"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "tid", value: tid),
            .init(name: "page", value: String(page))
        ]
        guard let url = comps?.url else { throw WebFetchError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }

        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WebFetchError.http(http.statusCode)
            }
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                throw WebFetchError.empty
            }
            return WebThreadHTML(tid: tid, page: page, html: html)
        } catch {
            throw WebFetchError.network(error)
        }
    }
}
