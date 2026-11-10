// updater: the app's own in-app updater, Sparkle-style but small
// enough to read in one sitting, with no third-party framework.
//
// On launch the launcher asks it to look at a signed feed (a small JSON file
// published next to each release). If the feed names a newer version, the
// player is asked; on "Update Now" the archive is downloaded, checked, unpacked
// beside the installed app, and swapped in after the launcher has exited, then
// the new app is opened.
//
// What is checked before the player is asked anything:
//   - the feed's Ed25519 signature against the public key baked into this app
//     at build time (CryptoKit, so nothing to vendor). The signature covers
//     the version, the download address, the archive's length and SHA-256,
//     the date, the minimum system and the notes, so none of them can be
//     edited, and an old signed archive cannot be offered as a new version;
//   - the download address is https under the release download base (a feed
//     read from a local file may also name a local archive).
// What is checked before anything is replaced:
//   - the download stops at the length the feed promised, and the archive has
//     exactly that length and SHA-256;
//   - the unpacked bundle has OUR bundle identifier and exactly the version
//     the feed promised;
//   - `codesign --verify --deep --strict` passes, and when this app is signed
//     with a Developer ID team, the new one is signed by the same team (an
//     ad-hoc signed bundle is then refused).
// The signing key, not the download host, is what the updater trusts: a feed
// or archive that does not verify is ignored and the old app keeps running.
//
// FAIL-OPEN: offline, feed missing, unparseable, not newer -> exit 0 and the
// launch carries on. An update is never forced.
//
// Usage:
//   updater check --feed <url|file://> --key-file <path> --app <Accurona.app>
//                 --current <version> --seen-file <path> [--wait-pid <pid>]
//                 [--timeout <sec>] [--download-base <https url>]
//                 [--yes] [--no-relaunch]
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

// Schema 2: the signature covers the feed's fields. Schema 1 signed only the
// archive, which left every field open to editing, so it is no longer read.
let feedSchema = 2
struct Feed: Codable {
    var schema: Int
    var version: String
    var url: String
    var length: Int
    var sha256: String
    var date: String
    var signature: String
    var notes: String?
    var minimumSystemVersion: String?
}

// The bytes the release key signs: every field the updater acts on or shows,
// each written as "name:<byte count>:<value>" so no value can run into the
// next. The archive itself is covered through its SHA-256.
func signedBytes(_ f: Feed) -> Data {
    var s = "accurona-update-feed-\(f.schema)\n"
    for (name, value) in [("version", f.version), ("url", f.url), ("length", String(f.length)),
                          ("sha256", f.sha256.lowercased()), ("date", f.date),
                          ("minimumSystemVersion", f.minimumSystemVersion ?? ""), ("notes", f.notes ?? "")] {
        s += "\(name):\(value.utf8.count):\(value)\n"
    }
    return Data(s.utf8)
}

// Releases are published as GitHub release assets; --download-base names
// another place for a build that publishes elsewhere.
let defaultDownloadBase = "https://github.com/qant-au/RecoilEngine-AppleSilicon/releases/download"

// An archive is fetched only over https from under the download base. A feed
// that was itself read from a local file (a test, or a build pointed at one)
// may also name a local archive; a feed from the network never may.
func archiveURLAllowed(_ u: URL, base: String, feedIsLocal: Bool) -> Bool {
    if u.isFileURL { return feedIsLocal }
    guard let b = URLComponents(string: base), let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
          b.scheme?.lowercased() == "https", c.scheme?.lowercased() == "https",
          let host = c.host?.lowercased(), !host.isEmpty, host == b.host?.lowercased(),
          c.port == b.port, c.user == nil, c.password == nil else { return false }
    // compared after percent-decoding, and with no "." or ".." step that could
    // climb out from under the base once the address is resolved
    let basePath = b.path.hasSuffix("/") ? b.path : b.path + "/"
    return c.path.hasPrefix(basePath) && !c.path.split(separator: "/").contains { $0 == "." || $0 == ".." }
}

// The whole download may take this long; a stalled one ends after a minute.
let downloadTimeLimit: TimeInterval = 30 * 60

// Receives the archive and stops at the length the signed feed promised.
final class Download: NSObject, URLSessionDataDelegate {
    let limit: Int
    var buf = Data(), done = false, ok = false, tooLong = false, cancelled = false
    var bar: NSProgressIndicator?
    var task: URLSessionDataTask?
    init(limit: Int) { self.limit = limit }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        ok = (r as? HTTPURLResponse)?.statusCode == 200
        // a server that announces more than the feed promised is not read at all
        if r.expectedContentLength > Int64(limit) { ok = false; tooLong = true }
        completionHandler(ok ? .allow : .cancel)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        // whatever comes after the promised length is not the archive
        if buf.count + d.count > limit { ok = false; tooLong = true; dataTask.cancel(); return }
        buf.append(d)
        let frac = Double(buf.count) / Double(max(limit, 1))
        DispatchQueue.main.async { self.bar?.doubleValue = frac * 100 }
    }
    // GitHub answers a release download with a redirect to its file store; a
    // redirect is followed only while it stays on https.
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(newRequest.url?.scheme?.lowercased() == "https" ? newRequest : nil)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if e != nil { ok = false }
        DispatchQueue.main.async { self.done = true; NSApp?.stopModal() }
    }
    @objc func cancel(_ sender: Any?) { cancelled = true; task?.cancel() }
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
    var feed = Feed(schema: feedSchema, version: ver, url: url, length: data.count, sha256: hex(SHA256.hash(data: data)),
                    date: ISO8601DateFormatter().string(from: Date()), signature: "",
                    notes: arg("--notes"), minimumSystemVersion: arg("--min-system"))
    feed.signature = try! key.signature(for: signedBytes(feed)).base64EncodedString()
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
guard let feedData = fetch(feedURL, timeout: timeout) else {
    exit(0)  // offline or no feed published yet: carry on quietly
}
guard let feed = try? JSONDecoder().decode(Feed.self, from: feedData), feed.schema == feedSchema else {
    log("the update feed is not in a format this version reads; ignored"); exit(0)
}
// Nothing in the feed is believed, shown or acted on before this passes.
guard let feedSig = Data(base64Encoded: feed.signature), pub.isValidSignature(feedSig, for: signedBytes(feed)) else {
    log("the update feed is not signed by the release key; ignored"); exit(0)
}
guard feed.length > 0, ISO8601DateFormatter().date(from: feed.date) != nil else {
    log("the update feed has an unusable length or date; ignored"); exit(0)
}
guard let zipURL = URL(string: feed.url),
      archiveURLAllowed(zipURL, base: arg("--download-base") ?? defaultDownloadBase, feedIsLocal: feedURL.isFileURL) else {
    log("the update feed names a download address outside the release site; ignored"); exit(0)
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
// Moving the bundle aside also needs write access to the bundle itself (an app
// put in place by another account has none): do not offer what cannot be done.
guard FileManager.default.isWritableFile(atPath: appURL.path) else {
    log("\(appURL.path) cannot be moved by this user; not offering an in-app update"); exit(0)
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
var stagingDir: URL?   // set once the update is unpacked; removed on every refusal
func failNotice(_ why: String) -> Never {
    log(why)
    if let s = stagingDir { try? FileManager.default.removeItem(at: s) }
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
var zipData: Data?
var tooLong = false
if zipURL.isFileURL {
    // a local archive: one byte past the promised length is enough to see
    // that the file is longer, without reading the rest of it
    if let h = try? FileHandle(forReadingFrom: zipURL) {
        let d = try? h.read(upToCount: feed.length + 1)
        try? h.close()
        if let d = d, d.count > feed.length { tooLong = true } else { zipData = d }
    }
} else {
    // A small progress panel while the archive downloads; the modal loop keeps
    // the window live, the delegate stops it when the download ends.
    let dl = Download(limit: feed.length)
    var panel: NSPanel?
    if ui {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 128), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Updating Accurona"
        let label = NSTextField(labelWithString: "Downloading Accurona \(feed.version)…")
        label.frame = NSRect(x: 20, y: 90, width: 320, height: 18)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 62, width: 320, height: 20))
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100
        let cancel = NSButton(title: "Cancel", target: dl, action: #selector(Download.cancel(_:)))
        cancel.frame = NSRect(x: 254, y: 14, width: 92, height: 32)
        cancel.keyEquivalent = "\u{1b}"   // Escape
        p.contentView?.addSubview(label); p.contentView?.addSubview(bar); p.contentView?.addSubview(cancel)
        dl.bar = bar
        p.level = .floating
        centerOnActiveScreen(p)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForResource = downloadTimeLimit
    let session = URLSession(configuration: cfg, delegate: dl, delegateQueue: nil)
    let task = session.dataTask(with: URLRequest(url: zipURL, timeoutInterval: 60))
    dl.task = task
    task.resume()
    if let p = panel {
        if !dl.done { NSApp.runModal(for: p) }
        p.orderOut(nil)
    } else {
        while !dl.done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    if dl.cancelled { log("update cancelled by the player"); exit(0) }
    tooLong = dl.tooLong
    zipData = dl.ok ? dl.buf : nil
}
if tooLong { failNotice("The download is larger than the update feed promised, so it was not installed.") }
guard let data = zipData else { failNotice("The download did not finish. Check the connection and try again next time.") }

// ---------------------------------------------------------------------- verify
// The feed's signature covers this length and SHA-256, so a match here means
// the release key vouches for exactly these bytes.
guard data.count == feed.length, hex(SHA256.hash(data: data)) == feed.sha256.lowercased() else {
    failNotice("The downloaded file does not match the update feed.")
}

// Unpack on the app's own volume so the final swap is a rename.
let fm = FileManager.default
guard let stage = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true) else {
    failNotice("There was nowhere to unpack the update.")
}
stagingDir = stage
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
// An app signed with a Developer ID team takes updates only from that team.
// The new bundle must name the same team and satisfy a requirement that its
// certificate chains to Apple and carries that team, which an ad-hoc signed
// bundle (no team) or another developer's cannot. An ad-hoc signed app, as a
// local test build is, has no team to hold an update to.
if let team = teamID(appURL.path) {
    guard team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), teamID(newApp) == team,
          run("/usr/bin/codesign", ["--verify", "--deep", "--strict",
                                    "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"", newApp]).0 == 0 else {
        failNotice("The update is signed by a different developer.")
    }
}

// ---------------------------------------------------------------------- swap
// A detached shell waits for the launcher to exit, renames the old app aside,
// moves the new one into place (putting the old one back if that fails), then
// opens it. It outlives this process and the launcher.
let backup = stage.appendingPathComponent("previous.app").path
// If the swap cannot be done the installed app is left as it was, the staging
// folder is removed, this version is not offered again on the next launch (it
// would fail the same way and quit the app each time), and the app is reopened.
let script = """
pid="$1"; old="$2"; new="$3"; backup="$4"; relaunch="$5"; stage="$6"; seen="$7"; version="$8"
if [ -n "$pid" ]; then n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt 600 ]; do sleep 0.2; n=$((n+1)); done; fi
if mv "$old" "$backup"; then
  if mv "$new" "$old"; then rm -rf "$stage"; [ "$relaunch" = "1" ] && open "$old"; exit 0; fi
  mv "$backup" "$old"
fi
rm -rf "$stage"
[ -n "$seen" ] && printf '%s' "$version" > "$seen"
[ "$relaunch" = "1" ] && open "$old"
exit 1
"""
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/sh")
p.arguments = ["-c", script, "accurona-swap", arg("--wait-pid") ?? "", appURL.path, newApp, backup,
               has("--no-relaunch") ? "0" : "1", stage.path, seenFile ?? "", feed.version]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
do { try p.run() } catch { failNotice("The update could not be started (\(error)).") }
if has("--wait-swap") { p.waitUntilExit(); exit(p.terminationStatus == 0 ? 3 : 1) }
print("updating to \(feed.version)")
exit(3)
