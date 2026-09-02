import Foundation

/// Verify what Sparkle will actually fetch — never trust the upload.
public enum Feed {
    public struct Enclosure: Equatable, Sendable {
        public var url: String
        public var length: Int
        public var version: String?

        public init(url: String, length: Int, version: String?) {
            self.url = url
            self.length = length
            self.version = version
        }
    }

    /// The single enclosure of a single-item feed.
    ///
    /// `sparkle:version` is read from BOTH places it can live: Sparkle 1 and
    /// some generators put it on the enclosure tag, and Sparkle 2's
    /// `generate_appcast` — what the fleet runs — emits it as a child
    /// `<sparkle:version>` element of the item. Reading only the attribute
    /// returned nil against every feed this tool will ever see.
    public static func enclosure(xml: String) -> Enclosure? {
        guard let start = xml.range(of: "<enclosure") else { return nil }
        let tag = String(xml[start.lowerBound...].prefix(while: { $0 != ">" }))
        guard let url = attribute("url", in: tag),
              let length = attribute("length", in: tag).flatMap(Int.init) else { return nil }
        let version = attribute("sparkle:version", in: tag) ?? element("sparkle:version", in: xml)
        return Enclosure(url: url, length: length, version: version)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + "=\"") else { return nil }
        let rest = tag[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<" + name + ">") else { return nil }
        let rest = xml[open.upperBound...]
        guard let close = rest.range(of: "</" + name + ">") else { return nil }
        return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Verdict: Equatable, Sendable {
        case ok(Enclosure)
        case lengthMismatch(feed: Int, live: Int)
        case noEnclosure
    }

    /// The appcast's `length=` must equal the zip's live `content-length`
    /// exactly — the length is part of what Sparkle validates, so a stale
    /// key or a half-purged edge cache fails every installed copy.
    public static func check(appcastXML: String, liveContentLength: Int) -> Verdict {
        guard let e = enclosure(xml: appcastXML) else { return .noEnclosure }
        return e.length == liveContentLength ? .ok(e) : .lengthMismatch(feed: e.length, live: liveContentLength)
    }

    // MARK: the live feed

    /// Fetches what Sparkle would fetch. A protocol so the check is testable
    /// without the network; `URLSessionFetcher` is the real one.
    public protocol Fetcher: Sendable {
        func text(at url: String) throws -> String
        func contentLength(at url: String) throws -> Int
    }

    public struct FetchError: Error, CustomStringConvertible {
        public var description: String
    }

    public struct URLSessionFetcher: Fetcher {
        public init() {}

        public func text(at url: String) throws -> String {
            guard let u = URL(string: url) else { throw FetchError(description: "not a URL: \(url)") }
            do { return try String(contentsOf: u, encoding: .utf8) }
            catch { throw FetchError(description: "GET \(url) failed: \(error.localizedDescription)") }
        }

        public func contentLength(at url: String) throws -> Int {
            guard let u = URL(string: url) else { throw FetchError(description: "not a URL: \(url)") }
            var head = URLRequest(url: u)
            head.httpMethod = "HEAD"
            head.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var length = -1
            nonisolated(unsafe) var failure: String?
            URLSession.shared.dataTask(with: head) { _, response, error in
                if let error { failure = error.localizedDescription }
                let http = response as? HTTPURLResponse
                if let http, http.statusCode != 200 { failure = "HTTP \(http.statusCode)" }
                length = Int(http?.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if let failure { throw FetchError(description: "HEAD \(url) failed: \(failure)") }
            guard length >= 0 else { throw FetchError(description: "HEAD \(url): no Content-Length") }
            return length
        }
    }

    /// Fetch `<prefixURL>appcast.xml`, then HEAD the zip it points at, and
    /// compare. This is the last step of a release and the one that catches
    /// a half-published pair: the feed live and the zip stale, or the other
    /// way round.
    public static func checkLive(prefixURL: String, fetcher: Fetcher = URLSessionFetcher()) throws -> Verdict {
        let base = prefixURL.hasSuffix("/") ? prefixURL : prefixURL + "/"
        let xml = try fetcher.text(at: base + "appcast.xml")
        guard let enclosure = enclosure(xml: xml) else { return .noEnclosure }
        return check(appcastXML: xml, liveContentLength: try fetcher.contentLength(at: enclosure.url))
    }
}
