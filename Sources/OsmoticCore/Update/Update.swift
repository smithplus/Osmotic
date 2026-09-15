import CryptoKit
import Foundation

/// A release version, `MAJOR.MINOR.PATCH` (a leading `v` is accepted, as in git tags).
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let ma = Int(parts[0]), ma >= 0 else { return nil }
        let mi = parts.count > 1 ? Int(parts[1]) : 0
        let pa = parts.count > 2 ? Int(parts[2]) : 0
        guard let mi, let pa, mi >= 0, pa >= 0 else { return nil }
        major = ma; minor = mi; patch = pa
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A newer release on GitHub and where its signed archive is.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: SemVer
    public let notes: String
    public let pageURL: URL
    public let archiveURL: URL
    public let signatureURL: URL
    public let archiveSize: Int

    public static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.archiveURL == b.archiveURL }
}

/// Reading GitHub's "latest release" answer (untrusted JSON) and checking update signatures.
public enum UpdateFeed {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/smithplus/Osmotic/releases/latest")!

    /// Largest archive the app will download (the universal app zips to ~10 MB).
    public static let maxArchiveBytes = 300 << 20

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int
        let browserDownloadUrl: URL
    }

    /// The release if it is newer than `current` and carries `Osmotic-<version>.zip` plus its
    /// `.zip.sig`, both served from GitHub over HTTPS; nil otherwise (older, draft, pre-release,
    /// missing assets, oversized, or not what we expect).
    public static func newerRelease(in json: Data, than current: SemVer) -> ReleaseInfo? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase  // tag_name, html_url, browser_download_url
        guard let r = try? decoder.decode(Release.self, from: json),
            r.draft != true, r.prerelease != true,
            let version = SemVer(r.tagName), version > current
        else { return nil }
        let base = "Osmotic-\(version).zip"
        guard let zip = r.assets.first(where: { $0.name == base }),
            let sig = r.assets.first(where: { $0.name == base + ".sig" }),
            zip.size > 0, zip.size <= maxArchiveBytes,
            [zip.browserDownloadUrl, sig.browserDownloadUrl, r.htmlUrl].allSatisfy(isGitHubHTTPS)
        else { return nil }
        return ReleaseInfo(
            version: version, notes: String((r.body ?? "").prefix(4000)), pageURL: r.htmlUrl,
            archiveURL: zip.browserDownloadUrl, signatureURL: sig.browserDownloadUrl, archiveSize: zip.size)
    }

    public static func isGitHubHTTPS(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Whether `signature` (base64, Ed25519) signs `archive` under `publicKey` (base64, raw 32 bytes).
    public static func verify(archive: Data, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            let sigData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(sigData, for: archive)
    }
}

/// Swapping the running app for the new one. The swap has to happen after the app quits, so it is a
/// small shell script that waits for our process to exit, moves the new bundle into place (keeping the
/// old one until the move succeeded), and reopens it.
public enum UpdateInstaller {
    public static let script = """
        #!/bin/sh
        # Osmotic updater: $1 = pid to wait for, $2 = new app bundle, $3 = installed app bundle.
        trap '' HUP
        PID="$1"; NEW="$2"; DEST="$3"
        n=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2; n=$((n + 1)); [ "$n" -gt 3000 ] && exit 1   # 10 min: quitting may restore Wi-Fi first
        done
        BACKUP="$DEST.previous"
        rm -rf "$BACKUP"
        if mv "$DEST" "$BACKUP"; then
          if mv "$NEW" "$DEST"; then
            rm -rf "$BACKUP"
          else
            mv "$BACKUP" "$DEST"
            exit 1
          fi
        else
          exit 1
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        [ -n "$OSMOTIC_UPDATER_NO_RELAUNCH" ] || open "$DEST"
        """
}
