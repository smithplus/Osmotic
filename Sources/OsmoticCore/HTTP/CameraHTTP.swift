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
            return (http.statusCode, Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1)
        } catch {
            return nil
        }
    }

    /// A whole small file (thumbnails). Nil on any non-2xx or error.
    public func data(_ urlPath: String) async -> Data? {
        do {
            let (data, resp) = try await session.data(for: request(urlPath))
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// An inclusive byte range.
    public func range(_ urlPath: String, from start: Int, to end: Int) async -> Data? {
        var r = request(urlPath)
        r.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
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
        return out.sorted { a, b in
            a.timestamp != b.timestamp ? a.timestamp > b.timestamp : a.seq > b.seq
        }
    }
}
