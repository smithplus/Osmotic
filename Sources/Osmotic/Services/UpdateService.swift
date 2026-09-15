import AppKit
import OsmoticCore
import SwiftUI

/// Updates from GitHub Releases: check the latest release, download its zip and Ed25519 signature,
/// verify both against the key built into this app, check the bundle inside, then swap it in when
/// the app quits and reopen it. Without a valid signature nothing is installed — a compromised release
/// page can't push a binary. Never runs with a camera connected (it would cut the session).
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date

    /// The public half of the release-signing key (base64, Ed25519), from Info.plist. Empty: this build
    /// can say an update exists and open its page, but won't install it.
    let publicKey = (Bundle.main.object(forInfoDictionaryKey: "OsmoticUpdatePublicKey") as? String) ?? ""
    var canInstall: Bool { !publicKey.isEmpty }
    /// Set by the app model: installing quits the app, so it must not cut a camera session or download.
    @ObservationIgnored var isSafeToInstall: () -> Bool = { false }

    let currentVersion =
        SemVer(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        ?? SemVer("0.0.0")!

    var checkAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "updateCheckAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateCheckAutomatically") }
    }

    /// At launch (and when back on the cameras screen): at most once a day, if allowed.
    func checkIfDue() {
        guard checkAutomatically, state == .idle || state == .upToDate || isFailed else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        state = .checking
        var request = URLRequest(url: UpdateFeed.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GitHubOnly.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = userInitiated ? .failed(String(localized: "GitHub didn’t answer. Try again later.")) : .idle
                return
            }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
            if let release = UpdateFeed.newerRelease(in: data, than: currentVersion) {
                log("update: \(release.version) available (running \(currentVersion))")
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            // Offline, or on the camera's Wi-Fi: say so only when the user asked.
            state = userInitiated ? .failed(String(localized: "Couldn’t reach GitHub. Check your internet connection.")) : .idle
        }
    }

    /// Download, verify and stage the release, then quit; the swap script reopens the new version.
    func install(_ release: ReleaseInfo) async {
        guard canInstall else { NSWorkspace.shared.open(release.pageURL); return }
        guard isSafeToInstall() else {
            state = .failed(String(localized: "Disconnect from the camera to install."))
            return
        }
        state = .downloading(release)
        do {
            let staged = try await stage(release)
            let dest = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path),
                !dest.path.contains("/AppTranslocation/")
            else {
                // Can't replace in place (read-only folder, or macOS runs it from a translocated copy):
                // hand the verified app to the user.
                NSWorkspace.shared.activateFileViewerSelecting([staged])
                state = .failed(String(localized: "Move the new Osmotic from Finder into Applications to finish."))
                return
            }
            let script = staged.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("swap.sh")
            try UpdateInstaller.script.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, dest.path]
            // The download took a while: still no camera session or transfer?
            guard isSafeToInstall() else {
                state = .failed(String(localized: "Disconnect from the camera to install."))
                return
            }
            try p.run()
            log("update: \(release.version) staged — quitting to install")
            NSApp.terminate(nil)
        } catch {
            log("update: install failed — \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case download, signature, bundle
        var errorDescription: String? {
            switch self {
            case .download: String(localized: "The download didn’t complete.")
            case .signature: String(localized: "The update’s signature doesn’t match. Nothing was installed.")
            case .bundle: String(localized: "The update doesn’t contain a valid Osmotic. Nothing was installed.")
            }
        }
    }

    /// The verified new app, unpacked in a fresh temporary folder.
    @concurrent
    private func stage(_ release: ReleaseInfo) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (zipFile, zipResponse) = try await GitHubOnly.session.download(from: release.archiveURL)
        let (sigData, sigResponse) = try await GitHubOnly.session.data(from: release.signatureURL)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200, (sigResponse as? HTTPURLResponse)?.statusCode == 200,
            let size = try? FileManager.default.attributesOfItem(atPath: zipFile.path)[.size] as? Int,
            size == release.archiveSize, size <= UpdateFeed.maxArchiveBytes
        else { throw UpdateError.download }
        let archive = try Data(contentsOf: zipFile, options: .mappedIfSafe)
        guard
            UpdateFeed.verify(
                archive: archive, signature: String(decoding: sigData, as: UTF8.self),
                publicKey: publicKey)
        else { throw UpdateError.signature }
        let zip = work.appendingPathComponent("Osmotic.zip")
        try archive.write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw UpdateError.bundle }
        // Exactly one Osmotic.app, with our identity and the announced version, and an intact signature.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: unpacked.path)) ?? []
        let app = unpacked.appendingPathComponent("Osmotic.app")
        guard contents == ["Osmotic.app"], let bundle = Bundle(url: app),
            bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
            (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemVer.init)
                == release.version,
            Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
        else { throw UpdateError.bundle }
        return app
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// URLSession that only follows redirects between GitHub hosts (release downloads bounce to
/// objects.githubusercontent.com); anything else is refused.
private final class GitHubOnly: NSObject, URLSessionTaskDelegate, Sendable {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Osmotic-Updater"]
        return URLSession(configuration: config, delegate: GitHubOnly(), delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(UpdateFeed.isGitHubHTTPS) == true ? request : nil
    }
}
