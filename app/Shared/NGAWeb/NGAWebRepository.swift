import Foundation

// 预留给后续“API优先→失败降级WEB”的策略选择
public enum DataChannel {
    case apiOnly
    case webOnly
    case auto
}

// 简单内存缓存：按 (tid,page) 存储解析结果，带 TTL
actor _PageCache {
    private var map: [String: (Date, WebThreadPage)] = [:]

    func get(key: String, maxAge: TimeInterval) -> WebThreadPage? {
        guard let (ts, page) = map[key] else { return nil }
        if Date().timeIntervalSince(ts) <= maxAge { return page }
        return nil
    }

    func set(key: String, page: WebThreadPage) {
        map[key] = (Date(), page)
    }
}

// 飞行中请求去重：同一 (tid,page) 多处并发，只打一次源站
actor _Inflight {
    private var tasks: [String: Task<WebThreadPage, Error>] = [:]

    func run(key: String, op: @escaping () async throws -> WebThreadPage) async throws -> WebThreadPage {
        if let t = tasks[key] { return try await t.value }
        let t = Task { try await op() }
        tasks[key] = t
        defer { tasks[key] = nil }
        return try await t.value
    }
}

/// 统一的 WEB 仓库：对外只暴露一个方法，拿到“已清洗可渲染”的帖子页数据
final class NGAWebRepository {

    static let shared = NGAWebRepository()

    // 可在设置里切换；当前阶段我们只用 .webOnly
    var channel: DataChannel = .webOnly

    private let client = NGAWebClient.shared
    private let parser = NGAHTMLParser()
    private let cache  = _PageCache()
    private let inflight = _Inflight()

    // 指数退避参数
    private let minBackoff: TimeInterval = 0.5
    private let maxBackoff: TimeInterval = 16
    private let jitter: TimeInterval     = 0.2

    // 简易缓存 TTL
    private let ttl: TimeInterval = 60

    /// 拉取并解析帖子（WEB 路径）
    /// - Returns: WebThreadPage（包含若干 WebPost，内部 html 已清洗，可直接渲染）
    func loadThreadWeb(tid: String, page: Int) async throws -> WebThreadPage {
        let key = "\(tid)#\(page)"

        // 1) 先查缓存
        if let cached = await cache.get(key: key, maxAge: ttl) { return cached }

        // 2) 飞行中去重 + 指数退避
        return try await inflight.run(key: key) {
            var attempt = 0
            while true {
                do {
                    // 抓 HTML
                    let raw = try await self.client.fetchThreadHTML(tid: tid, page: page)
                    // 解析/清洗
                    let parsed = self.parser.parseThreadPage(tid: tid, page: page, html: raw.html)
                    // 落缓存
                    await self.cache.set(key: key, page: parsed)
                    return parsed
                } catch {
                    attempt += 1
                    if attempt >= 3 { throw error }
                    // 指数退避 + 抖动
                    let base = min(self.maxBackoff, self.minBackoff * pow(2, Double(attempt - 1)))
                    let sleep = max(0.1, base + Double.random(in: -self.jitter...self.jitter))
                    try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                }
            }
        }
    }
}
