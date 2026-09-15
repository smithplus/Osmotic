import Foundation

/// How the library orders the card's files, and how a freshly listed page joins it.
extension Array where Element == CameraFile {
    /// Newest first: the name's capture stamp descending, then its sequence number descending. Files
    /// that tie on both (names without a stamp) keep the order they come in.
    public func newestFirst() -> [CameraFile] {
        sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq }
    }

    /// Oldest first (the download queue's order): stamp ascending, then sequence number ascending.
    /// Ties again keep the order they come in.
    public func oldestFirst() -> [CameraFile] {
        sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.seq < $1.seq }
    }

    /// Fold a freshly listed `page` into this library. `added`: the page's files whose `id` isn't in
    /// the library yet, in page order. `files`: the library plus `added`, newest first; always
    /// re-sorted, even when nothing was added. Among files that tie, `added` goes before the
    /// library's own, or after them when `pageIsOlder` (a page from further back on the card).
    public func merging(_ page: [CameraFile], pageIsOlder: Bool = false) -> (files: [CameraFile], added: [CameraFile]) {
        let known = Set(map(\.id))
        let added = page.filter { !known.contains($0.id) }
        return ((pageIsOlder ? self + added : added + self).newestFirst(), added)
    }
}
