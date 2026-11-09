// updater — the app's own in-app updater (acu-030), Sparkle-style but small
// enough to read in one sitting, with no third-party framework.
//
// On launch the launcher asks it to look at a signed feed (a small JSON file
// published next to each release). If the feed names a newer version, the
// player is asked; on "Update Now" the archive is downloaded, checked, unpacked
// beside the installed app, and swapped in after the launcher has exited, then
// the new app is opened.
//
// What is checked before anything is replaced:
//   • the archive's SHA-256 and its Ed25519 signature against the public key
//     baked into this app at build time (CryptoKit, so nothing to vendor);
//   • the unpacked bundle has OUR bundle identifier and exactly the version
//     the feed promised;
//   • `codesign --verify --deep --strict` passes, and when this app is signed
//     with a Developer ID team, the new one is signed by the same team.
// The signing key, not the download host, is what the updater trusts: a feed
// or archive that does not verify is ignored and the old app keeps running.
//
// FAIL-OPEN: offline, feed missing, unparseable, not newer -> exit 0 and the
// launch carries on. An update is never forced.
//
// Usage:
//   updater check --feed <url|file://> --key-file <path> --app <Accurona.app>
//                 --current <version> --seen-file <path> [--wait-pid <pid>]
//                 [--timeout <sec>] [--yes] [--no-relaunch]
//       exit 0 = carry on launching, 3 = an update is being installed (quit now)
//   updater keygen --out <private-key-file>      (prints the public key)
//   updater sign --key <private-key-file> --archive <zip> --version <v>
//                --url <download url> [--notes <text>] [--min-system <v>]
//                --out <appcast.json>
// --yes accepts without any window (tests and scripted installs).
import AppKit
import CryptoKit
import Foundation

func arg(_ n: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }
    return nil
}
func has(_ n: String) -> Bool { CommandLine.arguments.contains(n) }
func log(_ s: String) { FileHandle.standardError.write(("updater: " + s + "\n").data(using: .utf8)!) }
func die(_ s: String) -> Never { log(s); exit(1) }

struct Feed: Codable {
    var schema: Int
    var version: String
    var url: String
    var length: Int
    var sha256: String
    var ed25519: String
    var notes: String?
    var minimumSystemVersion: String?
}

// Dotted numeric compare: "0.13.1" < "0.14". Non-numeric parts count as 0.
func versionLess(_ a: String, _ b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

func readKey(_ path: String) -> Data? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func fetch(_ url: URL, timeout: Double) -> Data? {
    if url.isFileURL { return try? Data(contentsOf: url) }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    req.setValue("Accurona-updater", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    URLSession.shared.dataTask(with: req) { d, r, _ in
        if let h = r as? HTTPURLResponse, h.statusCode == 200 { out = d }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return out
}

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func teamID(_ app: String) -> String? {
    let (_, out) = run("/usr/bin/codesign", ["-dv", "--verbose=2", app])
    for line in out.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
        let t = String(line.dropFirst("TeamIdentifier=".count))
        return t == "not set" ? nil : t
    }
    return nil
}

func plist(_ app: String, _ key: String) -> String? {
    (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?[key]) as? String
}

// ---------------------------------------------------------------- keygen / sign
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "keygen" {
    guard let out = arg("--out") else { die("keygen needs --out") }
    if FileManager.default.fileExists(atPath: out) { die("\(out) exists; refusing to overwrite a signing key") }
    let k = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: out, contents: (k.rawRepresentation.base64EncodedString() + "\n").data(using: .utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(k.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "sign" {
    guard let keyPath = arg("--key"), let zip = arg("--archive"), let ver = arg("--version"),
          let url = arg("--url"), let out = arg("--out") else { die("sign needs --key --archive --version --url --out") }
    guard let raw = readKey(keyPath), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("bad key \(keyPath)") }
    guard let data = FileManager.default.contents(atPath: zip) else { die("cannot read \(zip)") }
    let sig = try! key.signature(for: data)
    let feed = Feed(schema: 1, version: ver, url: url, length: data.count, sha256: hex(SHA256.hash(data: data)),
                    ed25519: sig.base64EncodedString(), notes: arg("--notes"), minimumSystemVersion: arg("--min-system"))
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try! enc.encode(feed).write(to: URL(fileURLWithPath: out))
    print("signed \(zip) as \(ver): \(out)")
    exit(0)
}

// ---------------------------------------------------------------------- check
guard CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "check" else {
    die("usage: updater check|keygen|sign ... (see the header of updater.swift)")
}
guard let feedArg = arg("--feed"), let feedURL = URL(string: feedArg),
      let keyPath = arg("--key-file"), let appPath = arg("--app"), let current = arg("--current") else {
    log("check needs --feed --key-file --app --current"); exit(0)
}
let timeout = Double(arg("--timeout") ?? "4") ?? 4
let auto = has("--yes")
let seenFile = arg("--seen-file")

guard let pubRaw = readKey(keyPath), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else {
    log("no usable public key at \(keyPath); updates are off in this build"); exit(0)
}
guard let feedData = fetch(feedURL, timeout: timeout),
      let feed = try? JSONDecoder().decode(Feed.self, from: feedData), feed.schema == 1 else {
    exit(0)  // offline, no feed published yet, or not ours: carry on quietly
}
guard versionLess(current, feed.version) else { exit(0) }
if let min = feed.minimumSystemVersion {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    if versionLess("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", min) {
        log("\(feed.version) needs macOS \(min); staying on \(current)"); exit(0)
    }
}
if let sf = seenFile, (try? String(contentsOfFile: sf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == feed.version, !auto {
    exit(0)  // the player asked not to be reminded about this version
}

// The swap happens in the folder holding the app; if we cannot write there,
// the player has to update by hand (the nudge's download page still works).
let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
let parent = appURL.deletingLastPathComponent()
guard FileManager.default.isWritableFile(atPath: parent.path) else {
    log("\(parent.path) is not writable; not offering an in-app update"); exit(0)
}

let ui = !auto
var app: NSApplication?
func icon() -> NSImage? { NSImage(contentsOf: appURL.appendingPathComponent("Contents/Resources/AppIcon.icns")) }
func centerOnActiveScreen(_ w: NSWindow) {
    guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { w.center(); return }
    let f = w.frame
    w.setFrameOrigin(NSPoint(x: max(vis.minX, vis.minX + (vis.width - f.width) / 2),
                             y: max(vis.minY, vis.minY + (vis.height - f.height) * 0.75)))
}
func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
    if let i = icon() { alert.icon = i }
    alert.layout()
    let w = alert.window
    w.level = .floating
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    centerOnActiveScreen(w)
    w.makeKeyAndOrderFront(nil)
    w.orderFrontRegardless()
    app?.activate(ignoringOtherApps: true)
    return alert.runModal()
}
func failNotice(_ why: String) -> Never {
    log(why)
    if ui {
        let a = NSAlert()
        a.messageText = "The update could not be installed"
        a.informativeText = "\(why)\n\nAccurona \(current) will start as normal."
        a.addButton(withTitle: "Continue")
        _ = present(a)
    }
    exit(0)
}

if ui {
    app = NSApplication.shared
    app!.setActivationPolicy(.regular)
    app!.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Accurona \(feed.version) is available"
    var body = "You have \(current). The update downloads \(ByteCountFormatter.string(fromByteCount: Int64(feed.length), countStyle: .file)), then Accurona restarts."
    if let n = feed.notes, !n.isEmpty { body += "\n\n" + n }
    a.informativeText = body
    a.addButton(withTitle: "Update Now")
    a.addButton(withTitle: "Later")
    a.showsSuppressionButton = true
    a.suppressionButton?.title = "Don't remind me about this version"
    let r = present(a)
    if a.suppressionButton?.state == .on, let sf = seenFile { try? feed.version.write(toFile: sf, atomically: true, encoding: .utf8) }
    if r != .alertFirstButtonReturn { exit(0) }
}

// ------------------------------------------------------------------- download
guard let zipURL = URL(string: feed.url) else { failNotice("The update feed gave an unusable address.") }
var zipData: Data?
if zipURL.isFileURL {
    zipData = try? Data(contentsOf: zipURL)
} else {
    // A small progress panel while the archive downloads; the modal loop keeps
    // the window live, the delegate stops it when the download ends.
    final class DL: NSObject, URLSessionDataDelegate {
        var buf = Data(), expected: Int64 = 0, done = false, ok = false
        var bar: NSProgressIndicator?
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            ok = (r as? HTTPURLResponse)?.statusCode == 200
            expected = r.expectedContentLength
            completionHandler(ok ? .allow : .cancel)
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            buf.append(d)
            let frac = expected > 0 ? Double(buf.count) / Double(expected) : 0
            DispatchQueue.main.async { self.bar?.doubleValue = frac * 100 }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if e != nil { ok = false }
            DispatchQueue.main.async { self.done = true; NSApp?.stopModal() }
        }
    }
    let dl = DL()
    var panel: NSPanel?
    if ui {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Updating Accurona"
        let label = NSTextField(labelWithString: "Downloading Accurona \(feed.version)…")
        label.frame = NSRect(x: 20, y: 52, width: 320, height: 18)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 320, height: 20))
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100
        p.contentView?.addSubview(label); p.contentView?.addSubview(bar)
        dl.bar = bar
        p.level = .floating
        centerOnActiveScreen(p)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
    let session = URLSession(configuration: .ephemeral, delegate: dl, delegateQueue: nil)
    session.dataTask(with: URLRequest(url: zipURL, timeoutInterval: 60)).resume()
    if let p = panel {
        if !dl.done { NSApp.runModal(for: p) }
        p.orderOut(nil)
    } else {
        while !dl.done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    zipData = dl.ok ? dl.buf : nil
}
guard let data = zipData else { failNotice("The download did not finish. Check the connection and try again next time.") }

// ---------------------------------------------------------------------- verify
guard data.count == feed.length, hex(SHA256.hash(data: data)) == feed.sha256.lowercased() else {
    failNotice("The downloaded file does not match the update feed.")
}
guard let sig = Data(base64Encoded: feed.ed25519), pub.isValidSignature(sig, for: data) else {
    failNotice("The download is not signed by Accurona's release key, so it was not installed.")
}

// Unpack on the app's own volume so the final swap is a rename.
let fm = FileManager.default
guard let stage = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true) else {
    failNotice("There was nowhere to unpack the update.")
}
let zipFile = stage.appendingPathComponent("update.zip")
let unpacked = stage.appendingPathComponent("unpacked")
do { try data.write(to: zipFile) } catch { failNotice("The update could not be saved to disk.") }
let (dz, dout) = run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path])
guard dz == 0 else { failNotice("The update archive could not be unpacked (\(dout.trimmingCharacters(in: .whitespacesAndNewlines))).") }
let apps = ((try? fm.contentsOfDirectory(atPath: unpacked.path)) ?? []).filter { $0.hasSuffix(".app") }
guard apps.count == 1 else { failNotice("The update archive does not hold exactly one app.") }
let newApp = unpacked.appendingPathComponent(apps[0]).path

guard let ourID = plist(appURL.path, "CFBundleIdentifier"), plist(newApp, "CFBundleIdentifier") == ourID else {
    failNotice("The update is a different app.")
}
guard plist(newApp, "CFBundleShortVersionString") == feed.version else {
    failNotice("The update's version does not match the feed.")
}
let (cv, cout) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp])
guard cv == 0 else { failNotice("The update's code signature is broken (\(cout.trimmingCharacters(in: .whitespacesAndNewlines))).") }
if let team = teamID(appURL.path), teamID(newApp) != team {
    failNotice("The update is signed by a different developer.")
}

// ---------------------------------------------------------------------- swap
// A detached shell waits for the launcher to exit, renames the old app aside,
// moves the new one into place (putting the old one back if that fails), then
// opens it. It outlives this process and the launcher.
let backup = stage.appendingPathComponent("previous.app").path
let script = """
pid="$1"; old="$2"; new="$3"; backup="$4"; relaunch="$5"; stage="$6"
if [ -n "$pid" ]; then n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt 600 ]; do sleep 0.2; n=$((n+1)); done; fi
mv "$old" "$backup" || exit 1
if mv "$new" "$old"; then rm -rf "$stage"; else mv "$backup" "$old"; exit 1; fi
[ "$relaunch" = "1" ] && open "$old"
exit 0
"""
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/sh")
p.arguments = ["-c", script, "accurona-swap", arg("--wait-pid") ?? "", appURL.path, newApp, backup,
               has("--no-relaunch") ? "0" : "1", stage.path]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
do { try p.run() } catch { failNotice("The update could not be started (\(error)).") }
if has("--wait-swap") { p.waitUntilExit(); exit(p.terminationStatus == 0 ? 3 : 1) }
print("updating to \(feed.version)")
exit(3)
