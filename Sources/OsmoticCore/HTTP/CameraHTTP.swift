import Foundation

/// The camera never redirects; following one could send requests to any host.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

/// Thin async client for the camera's lighttpd `/v2` file API at `http://192.168.2.1`.
public final class CameraHTTP: Sendable {
    /// The largest file a camera card can plausibly hold. A bigger stated size is a bogus header, and
    /// summing it into a transfer total would overflow.
    public static let maxFileSize = 1 << 40  // 1 TiB

    /// A size the server stated, or nil when it's missing or implausible.
    public static func plausibleSize(_ text: some StringProtocol) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0, n <= maxFileSize else { return nil }
        return n
    }

    public let baseURL: URL
    let session: URLSession

    public init(ip: String = "192.168.2.1", port: Int = 80) {
        baseURL = URL(string: port == 80 ? "http://\(ip)" : "http://\(ip):\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func url(_ urlPath: String) -> URL {
        URL(string: baseURL.absoluteString + urlPath) ?? baseURL
    }

    func request(_ urlPath: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url(urlPath))
        r.httpMethod = method
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        return r
    }

    /// HTTP status for a HEAD, or nil when the request itself failed.
    public func headStatus(_ urlPath: String) async -> (status: Int, length: Int)? {
        do {
            let (_, resp) = try await session.data(for: request(urlPath, method: "HEAD"))
            guard let http = resp as? HTTPURLResponse else { return nil }
            return (http.statusCode, http.value(forHTTPHeaderField: "Content-Length").flatMap(Self.plausibleSize) ?? -1)
        } catch {
            return nil
        }
    }

    /// A whole small file (thumbnails, a photo for the preview). Nil on any non-2xx, error, or a body
    /// over `limit`: whatever answers at the camera's address can't make the app buffer without end.
    public func data(_ urlPath: String, limit: Int = 8 << 20) async -> Data? {
        await capped(request(urlPath), limit: limit) { (200...299).contains($0) }
    }

    /// An inclusive byte range, cut at its length. A 206 counts; so does a 200 from byte 0 (a server
    /// that ignores `Range` still starts at the right byte), never past it.
    public func range(_ urlPath: String, from start: Int, to end: Int) async -> Data? {
        var r = request(urlPath)
        r.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        return await capped(r, limit: end - start + 1, truncate: true) { $0 == 206 || (start == 0 && $0 == 200) }
    }

    /// Reads a response body up to `limit` bytes. Past the limit: nil, or the first `limit` bytes when
    /// `truncate` is set.
    private func capped(
        _ request: URLRequest, limit: Int, truncate: Bool = false, accept: (Int) -> Bool
    ) async -> Data? {
        do {
            let (bytes, resp) = try await session.bytes(for: request)
            guard let http = resp as? HTTPURLResponse, accept(http.statusCode) else { return nil }
            if !truncate, http.expectedContentLength > Int64(limit) { return nil }
            var data = Data()
            data.reserveCapacity(min(limit, max(0, Int(clamping: http.expectedContentLength))))
            for try await byte in bytes {
                if data.count == limit { return truncate ? data : nil }
                data.append(byte)
            }
            return data
        } catch {
            return nil
        }
    }

    /// Resolve every file's `/v2?storage=` mount. A Pocket 3 is pinned to 0; a record from a
    /// store-specific query already knows; otherwise the handle's store bit is the guess, confirmed by
    /// one HEAD per bit.
    public func resolveStorage(_ files: [CameraFile], singleSdStorage: Bool) async -> [CameraFile] {
        var byBit: [Int: Int] = [:]
        var out: [CameraFile] = []
        for var f in files {
            if singleSdStorage {
                f.storage = 0
            } else if !f.storageKnown {
                let h = f.handle != 0 ? f.handle : f.cmdHandle
                if h != 0 {
                    let bit = (h & 0x4000_0000) != 0 ? 1 : 0
                    if let known = byBit[bit] {
                        f.storage = known
                    } else {
                        let other = 1 - bit
                        var chosen = bit
                        if await headStatus(CameraFile.urlPath(storage: bit, path: f.path))?.status == 200 {
                            chosen = bit
                        } else if await headStatus(CameraFile.urlPath(storage: other, path: f.path))?.status == 200 {
                            chosen = other
                        }
                        byBit[bit] = chosen
                        f.storage = chosen
                    }
                } else {
                    f.storage = 0
                    for s in [1, 0] where await headStatus(CameraFile.urlPath(storage: s, path: f.path))?.status == 200 {
                        f.storage = s
                        break
                    }
                }
            }
            out.append(f)
        }
        return out.newestFirst()
    }
}
