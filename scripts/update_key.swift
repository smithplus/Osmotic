// Release-signing key for Osmotic's updater (Ed25519). The private key lives in the login Keychain
// (service io.github.smithplus.osmotic.update-signing); CI can pass it as OSMOTIC_UPDATE_KEY (base64).
//   swift scripts/update_key.swift generate        create the key (once), print the public key for Info.plist
//   swift scripts/update_key.swift public          print the public key
//   swift scripts/update_key.swift sign <file>     print the base64 signature of <file>
//   swift scripts/update_key.swift verify <file> <sigfile> <publicKey>
import CryptoKit
import Foundation

let service = "io.github.smithplus.osmotic.update-signing"
let account = "osmotic"

func security(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func privateKey() -> Curve25519.Signing.PrivateKey? {
    let b64 = ProcessInfo.processInfo.environment["OSMOTIC_UPDATE_KEY"]
        ?? { let r = security(["find-generic-password", "-a", account, "-s", service, "-w"]); return r.0 == 0 ? r.1 : nil }()
    guard let b64, let raw = Data(base64Encoded: b64) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if privateKey() != nil { fail("A signing key already exists in the Keychain (\(service)). Not replacing it.") }
    let key = Curve25519.Signing.PrivateKey()
    let r = security(["add-generic-password", "-a", account, "-s", service, "-w",
                      key.rawRepresentation.base64EncodedString(), "-T", "/usr/bin/security"])
    guard r.0 == 0 else { fail("Couldn't store the key in the Keychain.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = privateKey() else { fail("No signing key. Run: swift scripts/update_key.swift generate") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("usage: sign <file>") }
    guard let key = privateKey() else { fail("No signing key. Run: swift scripts/update_key.swift generate") }
    print(try! key.signature(for: data).base64EncodedString())
case "verify":
    let rest = Array(args.dropFirst())
    guard rest.count == 3, let data = FileManager.default.contents(atPath: rest[0]),
          let sig = FileManager.default.contents(atPath: rest[1]).flatMap({ Data(base64Encoded: String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }),
          let pubRaw = Data(base64Encoded: rest[2]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw)
    else { fail("usage: verify <file> <sigfile> <publicKey>") }
    guard pub.isValidSignature(sig, for: data) else { fail("signature does NOT verify") }
    print("signature OK")
default:
    fail("usage: swift scripts/update_key.swift generate | public | sign <file> | verify <file> <sig> <pubkey>")
}
