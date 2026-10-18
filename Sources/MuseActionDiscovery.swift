import Foundation

// Discover only the named subscription READ action in first-party public code.
// No cookies, account data, or authentication headers leave the WebKit session.
final class MuseActionDiscovery {
    private let queue = DispatchQueue(label: "local.widget.muse.discovery")
    private let actionPattern = try! NSRegularExpression(pattern: #"createServerReference\)\(["']([a-f0-9]{20,100})["'][^;]{0,300}["']fetchSubscriptionAction["']\)"#)
    private let chunkPattern = try! NSRegularExpression(pattern: #"(?:/_next/)?static/chunks/[A-Za-z0-9._~/-]+\.js"#)
    private var session: URLSession?
    private var pending: [URL] = []
    private var seen = Set<String>()
    private var running = 0
    private var bytes = 0
    private var generation = 0
    private var completion: ((Result<String, Error>) -> Void)?

    static func allowedURL(_ value: String) -> URL? {
        guard let input = URL(string: value), input.scheme == "https", input.host == "muse.ai", input.port == nil,
              input.user == nil, input.password == nil,
              input.path.hasPrefix("/_next/static/chunks/"), input.path.hasSuffix(".js"),
              !input.path.contains("..") else { return nil }
        var parts = URLComponents(url: input, resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.fragment = nil
        return parts.url
    }

    func discover(sources: [String], completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            self.cancelOnQueue()
            self.completion = completion
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 7
            config.httpMaximumConnectionsPerHost = 12
            self.session = URLSession(configuration: config)
            for source in sources { if let url = Self.allowedURL(source) { self.enqueue(url) } }
            self.pump()
        }
    }
    private func enqueue(_ url: URL) {
        guard seen.count < 320, seen.insert(url.absoluteString).inserted else { return }
        pending.append(url)
    }
    private func pump() {
        guard completion != nil else { return }
        while running < 12 && !pending.isEmpty && bytes < 32_000_000 {
            let url = pending.removeFirst(), epoch = generation
            running += 1
            session?.dataTask(with: url) { [weak self] data, response, _ in
                guard let self else { return }
                self.queue.async {
                    guard epoch == self.generation, self.completion != nil else { return }
                    self.running -= 1
                    if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 8_000_000, let source = String(data: data, encoding: .utf8) {
                        self.bytes += data.count
                        let full = NSRange(source.startIndex..., in: source)
                        if let match = self.actionPattern.firstMatch(in: source, range: full), let range = Range(match.range(at: 1), in: source) {
                            self.finish(.success(String(source[range]))); return
                        }
                        for match in self.chunkPattern.matches(in: source, range: full) {
                            guard let range = Range(match.range, in: source) else { continue }
                            let path = String(source[range])
                            if let dependency = Self.allowedURL("https://muse.ai" + (path.hasPrefix("/_next/") ? path : "/_next/" + path)) { self.enqueue(dependency) }
                        }
                    }
                    self.pump()
                }
            }.resume()
        }
        if running == 0 {
            finish(.failure(WidgetError.message("Muse 网页已变化，暂未识别到额度查询；稍后将重试")))
        }
    }
    private func finish(_ result: Result<String, Error>) {
        let callback = completion
        cancelOnQueue()
        DispatchQueue.main.async { callback?(result) }
    }
    private func cancelOnQueue() {
        generation += 1
        session?.invalidateAndCancel(); session = nil
        completion = nil; pending = []; seen = []; running = 0; bytes = 0
    }
    func cancel() { queue.async { self.cancelOnQueue() } }
}
