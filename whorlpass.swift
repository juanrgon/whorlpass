// whorlpass: store secrets on this Mac only, unlocked with Touch ID.
//
// Each secret is encrypted to a Secure Enclave key that requires a fingerprint
// to use and cannot leave this Mac. The encrypted files are useless elsewhere.
//
//   whorlpass set [name]    store a secret (prompts, or reads stdin)
//   whorlpass get [name]    print a secret (Touch ID)
//   whorlpass copy [name]   copy a secret to the clipboard for 30s (Touch ID)
//   whorlpass list          list stored names
//   whorlpass rm <name>     delete a secret
//   whorlpass agent         run the ctrl+option+cmd+P hotkey listener
//
// The name defaults to "default". The hotkey copies "default".

import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import LocalAuthentication
import Security

let dataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/whorlpass", isDirectory: true)
let secretsDir = dataDir.appendingPathComponent("secrets", isDirectory: true)
let keyFile = dataDir.appendingPathComponent("se-key")
let defaultName = "default"
let clearSeconds = 30
let formatTag = Data("whorlpass v1".utf8)

struct WhorlpassError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("whorlpass: " + message + "\n").utf8))
    exit(1)
}

func validName(_ name: String) throws -> String {
    guard !name.isEmpty, name.count <= 100,
          name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
          !name.hasPrefix(".")
    else { throw WhorlpassError("invalid name \"\(name)\" (use letters, numbers, . _ -)") }
    return name
}

func secretFile(_ name: String) -> URL { secretsDir.appendingPathComponent(name + ".enc") }

func makePrivateDir(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

func writePrivateFile(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
    guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw WhorlpassError("could not write \(tmp.path)") }
    guard rename(tmp.path, url.path) == 0 else { throw WhorlpassError("could not write \(url.path)") }
}

// MARK: Secure Enclave key

func loadKey(context: LAContext?) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    guard let data = try? Data(contentsOf: keyFile) else {
        throw WhorlpassError("no key yet; run `whorlpass set` first")
    }
    return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
}

func loadOrCreateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    if FileManager.default.fileExists(atPath: keyFile.path) { return try loadKey(context: nil) }
    guard SecureEnclave.isAvailable else { throw WhorlpassError("this Mac has no Secure Enclave") }
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryAny], &error)
    else { throw WhorlpassError("access control: \(error!.takeRetainedValue())") }
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    try makePrivateDir(dataDir)
    try writePrivateFile(key.dataRepresentation, to: keyFile)
    return key
}

// MARK: Encryption (ECIES: ephemeral P-256 + HKDF-SHA256 + AES-GCM)

func symmetricKey(_ shared: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: ephemeral + recipient, sharedInfo: formatTag, outputByteCount: 32)
}

func encrypt(_ secret: Data, name: String) throws -> Data {
    let recipient = try loadOrCreateKey().publicKey
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
    let ephemeralData = ephemeral.publicKey.x963Representation
    let key = symmetricKey(shared, ephemeral: ephemeralData, recipient: recipient.x963Representation)
    let box = try AES.GCM.seal(secret, using: key, authenticating: formatTag + Data(name.utf8))
    return ephemeralData + box.combined!
}

func decrypt(name: String) throws -> Data {
    guard let blob = try? Data(contentsOf: secretFile(name)) else {
        throw WhorlpassError("no secret named \"\(name)\"")
    }
    guard blob.count > 65 + 28 else { throw WhorlpassError("\"\(name)\" is corrupted") }
    let context = LAContext()
    context.localizedReason = "unlock \"\(name)\""
    let key = try loadKey(context: context)
    let ephemeralData = blob.prefix(65)
    let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
    let shared: SharedSecret
    do {
        shared = try key.sharedSecretFromKeyAgreement(with: ephemeral) // Touch ID prompt
    } catch {
        throw WhorlpassError("Touch ID failed or was cancelled")
    }
    let symmetric = symmetricKey(shared, ephemeral: ephemeralData, recipient: key.publicKey.x963Representation)
    let box = try AES.GCM.SealedBox(combined: blob.dropFirst(65))
    return try AES.GCM.open(box, using: symmetric, authenticating: formatTag + Data(name.utf8))
}

// MARK: Clipboard

let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

/// Copies the secret, marked so clipboard managers skip it. Returns the change count.
func copyToClipboard(_ secret: String) throws -> Int {
    let pasteboard = NSPasteboard.general
    // currentHostOnly keeps the secret off Universal Clipboard, so it never
    // reaches other devices signed in to the same Apple Account.
    _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
    let item = NSPasteboardItem()
    item.setString(secret, forType: .string)
    item.setData(Data(), forType: concealedType)
    item.setData(Data(), forType: transientType)
    guard pasteboard.writeObjects([item]) else { throw WhorlpassError("could not write to the clipboard") }
    return pasteboard.changeCount
}

/// Clears the clipboard only if nothing new was copied since.
func clearClipboard(ifChangeCount count: Int) {
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount == count { pasteboard.clearContents() }
}

/// Clears the clipboard after `clearSeconds` from a separate process, so the clear
/// still happens if this process exits first. If that cannot be set up, clears now.
func scheduleClear(changeCount: Int) throws {
    guard spawnDetachedClear(changeCount: changeCount) else {
        clearClipboard(ifChangeCount: changeCount)
        throw WhorlpassError("could not schedule the clipboard clear, so it was cleared now")
    }
}

/// Runs `whorlpass __clear <count>` in its own session so it outlives this process.
func spawnDetachedClear(changeCount: Int) -> Bool {
    guard let exe = Bundle.main.executablePath else { return false }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    let args = [exe, "__clear", String(changeCount)].map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let status = posix_spawn(&pid, exe, &actions, &attr, args, environ)
    args.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return status == 0
}

// MARK: Reading a new secret

func readSecret() throws -> Data {
    if isatty(STDIN_FILENO) == 0 {
        var data = FileHandle.standardInput.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { throw WhorlpassError("stdin was empty") }
        return data
    }
    func prompt(_ text: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let result = readpassphrase(text, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            throw WhorlpassError("could not read password")
        }
        return String(cString: result)
    }
    let first = try prompt("Password: ")
    guard !first.isEmpty else { throw WhorlpassError("password was empty") }
    guard try prompt("Again: ") == first else { throw WhorlpassError("passwords did not match") }
    return Data(first.utf8)
}

// MARK: Hotkey agent (ctrl+option+cmd+P)

final class Agent {
    private var hotKey: EventHotKeyRef?
    private var busy = false

    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<Agent>.fromOpaque(userData!).takeUnretainedValue().pressed()
            return noErr
        }, 1, &spec, me, nil)

        let id = EventHotKeyID(signature: OSType(0x7768_726C), id: 1) // "whrl"
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { fail("could not register ctrl+option+cmd+P (status \(status)); is another app using it?") }

        app.run()
        exit(0)
    }

    private func pressed() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try decrypt(name: defaultName) }
            DispatchQueue.main.async {
                self.busy = false
                do {
                    let data = try result.get()
                    let count = try copyToClipboard(String(decoding: data, as: UTF8.self))
                    try scheduleClear(changeCount: count)
                    NSSound(named: "Tink")?.play()
                } catch {
                    NSSound(named: "Basso")?.play()
                    FileHandle.standardError.write(Data("whorlpass: \(error)\n".utf8))
                }
            }
        }
    }
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let nameArg = args.count > 1 ? args[1] : defaultName

do {
    switch command {
    case "set":
        let name = try validName(nameArg)
        let blob = try encrypt(try readSecret(), name: name)
        try makePrivateDir(secretsDir)
        try writePrivateFile(blob, to: secretFile(name))
        print("Saved \"\(name)\".")
    case "get":
        let data = try decrypt(name: try validName(nameArg))
        FileHandle.standardOutput.write(data)
        if isatty(STDOUT_FILENO) != 0 { print() }
    case "copy":
        let data = try decrypt(name: try validName(nameArg))
        let count = try copyToClipboard(String(decoding: data, as: UTF8.self))
        try scheduleClear(changeCount: count)
        print("Copied. Clipboard clears in \(clearSeconds)s.")
    case "list":
        let files = (try? FileManager.default.contentsOfDirectory(atPath: secretsDir.path)) ?? []
        files.filter { $0.hasSuffix(".enc") }.map { String($0.dropLast(4)) }.sorted().forEach { print($0) }
    case "rm":
        guard args.count > 1 else { throw WhorlpassError("usage: whorlpass rm <name>") }
        let name = try validName(args[1])
        try FileManager.default.removeItem(at: secretFile(name))
        print("Deleted \"\(name)\".")
    case "agent":
        Agent().run()
    case "__clear":
        sleep(UInt32(clearSeconds))
        clearClipboard(ifChangeCount: Int(args.count > 1 ? args[1] : "") ?? -1)
    default:
        print("""
        usage:
          whorlpass set [name]    store a secret (default name: \(defaultName))
          whorlpass get [name]    print a secret (Touch ID)
          whorlpass copy [name]   copy to clipboard for \(clearSeconds)s (Touch ID)
          whorlpass list          list names
          whorlpass rm <name>     delete a secret
          whorlpass agent         ctrl+option+cmd+P copies "\(defaultName)"
        """)
    }
} catch {
    fail("\(error)")
}
