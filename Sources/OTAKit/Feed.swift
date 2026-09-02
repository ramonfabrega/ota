import Foundation

/// Verify what Sparkle will actually fetch — never trust the upload.
public enum Feed {
    public struct Enclosure: Equatable, Sendable {
        public var url: String
        public var length: Int
        public var version: String?
    }

    /// The single enclosure of a single-item feed.
    public static func enclosure(xml: String) -> Enclosure? {
        func attr(_ name: String, in s: String) -> String? {
            guard let r = s.range(of: name + "=\"") else { return nil }
            let rest = s[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let start = xml.range(of: "<enclosure") else { return nil }
        let tag = String(xml[start.lowerBound...].prefix(while: { $0 != ">" }))
        guard let url = attr("url", in: tag), let length = attr("length", in: tag).flatMap(Int.init) else { return nil }
        return Enclosure(url: url, length: length, version: attr("sparkle:version", in: tag))
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
}
