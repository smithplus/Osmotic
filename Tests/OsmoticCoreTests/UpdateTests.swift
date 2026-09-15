import CryptoKit
import Foundation
import Testing

@testable import OsmoticCore

@Suite struct UpdateTests {
    @Test func `versions parse and compare`() {
        #expect(SemVer("v1.2.3")! > SemVer("1.2.2")!)
        #expect(SemVer("0.10.0")! > SemVer("0.9.9")!)
        #expect(SemVer("2")! == SemVer("2.0.0")!)
        #expect(SemVer("v1.2.x") == nil && SemVer("") == nil && SemVer("1.-2.0") == nil)
    }

    func releaseJSON(tag: String, assets: [(String, Int, String)], prerelease: Bool = false) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","size":\#($0.1),"browser_download_url":"\#($0.2)"}"# }
        return Data(
            #"{"tag_name":"\#(tag)","html_url":"https://github.com/smithplus/Osmotic/releases/tag/\#(tag)","body":"Notes","prerelease":\#(prerelease),"assets":[\#(list.joined(separator: ","))]}"#
                .utf8)
    }

    @Test func `only a newer, signed, GitHub-hosted release is offered`() {
        let base = "https://github.com/smithplus/Osmotic/releases/download/v0.2.0/"
        let good = releaseJSON(
            tag: "v0.2.0",
            assets: [
                ("Osmotic-0.2.0.zip", 10_000_000, base + "Osmotic-0.2.0.zip"),
                ("Osmotic-0.2.0.zip.sig", 88, base + "Osmotic-0.2.0.zip.sig"),
            ])
        let r = UpdateFeed.newerRelease(in: good, than: SemVer("0.1.0")!)
        #expect(r?.version == SemVer("0.2.0"))
        #expect(UpdateFeed.newerRelease(in: good, than: SemVer("0.2.0")!) == nil, "not newer")
        #expect(UpdateFeed.newerRelease(in: good, than: SemVer("0.3.0")!) == nil, "never a downgrade")

        let unsigned = releaseJSON(tag: "v0.2.0", assets: [("Osmotic-0.2.0.zip", 10, base + "Osmotic-0.2.0.zip")])
        #expect(UpdateFeed.newerRelease(in: unsigned, than: SemVer("0.1.0")!) == nil)
        let elsewhere = releaseJSON(
            tag: "v0.2.0",
            assets: [
                ("Osmotic-0.2.0.zip", 10, "http://evil.example/Osmotic-0.2.0.zip"),
                ("Osmotic-0.2.0.zip.sig", 88, base + "Osmotic-0.2.0.zip.sig"),
            ])
        #expect(UpdateFeed.newerRelease(in: elsewhere, than: SemVer("0.1.0")!) == nil)
        let pre = releaseJSON(
            tag: "v0.2.0",
            assets: [
                ("Osmotic-0.2.0.zip", 10, base + "Osmotic-0.2.0.zip"),
                ("Osmotic-0.2.0.zip.sig", 88, base + "Osmotic-0.2.0.zip.sig"),
            ], prerelease: true)
        #expect(UpdateFeed.newerRelease(in: pre, than: SemVer("0.1.0")!) == nil)
        #expect(UpdateFeed.newerRelease(in: Data("garbage".utf8), than: SemVer("0.1.0")!) == nil)
    }

    @Test func `signatures verify only for the exact archive and key`() {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("the app".utf8)
        let sig = try! key.signature(for: archive).base64EncodedString()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(UpdateFeed.verify(archive: archive, signature: sig, publicKey: pub))
        #expect(!UpdateFeed.verify(archive: Data("the app!".utf8), signature: sig, publicKey: pub))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateFeed.verify(archive: archive, signature: sig, publicKey: other))
        #expect(!UpdateFeed.verify(archive: archive, signature: "not base64", publicKey: pub))
    }

    @Test func `the swap script replaces the bundle and keeps nothing behind`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-upd-\(UUID().uuidString)")
        let fm = FileManager.default
        let dest = dir.appendingPathComponent("Osmotic.app"), new = dir.appendingPathComponent("new/Osmotic.app")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("v"))
        try Data("new".utf8).write(to: new.appendingPathComponent("v"))
        defer { try? fm.removeItem(at: dir) }
        let script = dir.appendingPathComponent("swap.sh")
        try UpdateInstaller.script.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, "999999", new.path, dest.path]  // a pid that isn't running
        p.environment = ["OSMOTIC_UPDATER_NO_RELAUNCH": "1", "PATH": "/usr/bin:/bin"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(try String(contentsOf: dest.appendingPathComponent("v"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: dest.path + ".previous"))
        #expect(!fm.fileExists(atPath: new.path))
    }
}
