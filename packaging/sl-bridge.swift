// sl-bridge: the spring-launcher wrapper protocol BAR's lobby (BYAR-Chobby)
// expects from its launcher, implemented natively for the macOS app.
//
// Without it the lobby's WG.WrapperLoopback is nil: the replay list crashes on
// ReadReplayInfo (replays "hang on the loading screen") and lobby downloads
// (widget hub, OpenSkill) fail. Issue #1 on this repository.
//
// Protocol (BYAR-Chobby libs/spring-launcher/luaui/widgets/api_spring_launcher.lua
// and LuaMenu/widgets/sl_loopback.lua; reference launcher:
// https://github.com/beyond-all-reason/spring-launcher): the launcher listens on
// a local TCP port and writes <writedir>/sl-connection.json with _sl_address,
// _sl_port and _sl_write_path; messages both ways are newline-delimited JSON
// {"name": ..., "command": {...}}.
//
// Handled:
//   ReadReplayInfo {relativePath}   -> ReplayInfo (parsed from the .sdfz, cached
//                                      beside it as <demo>.cache, as upstream does)
//   Download {name,type,resource}   -> DownloadProgress / DownloadFinished; game and
//                                      map via the bundled pr-downloader against BAR's
//                                      content network; resource = https file fetch
//                                      (zip extracted with ditto) inside the write dir
//   AbortDownload {name}            -> stops the running download
//   OpenFile {path}                 -> OpenFileFinished / OpenFileFailed; http(s)
//                                      URLs, or file:// paths inside the write dir
//   StartNewSpring {Engine,StartDemoName} -> launches the bundled engine on the demo
//                                      only when Engine matches it (another engine
//                                      version cannot run on this Mac); same-engine
//                                      replays never come here (the lobby restarts
//                                      the running engine itself)
//   ParseMiniMap {mapPath,destination} -> ParseMiniMapFinished; the map's own
//                                      1024x1024 minimap (DXT1 in the .smf), read with
//                                      the system bsdtar (7z and zip) and written as a
//                                      JPEG/PNG inside the write dir, as spring-launcher's
//                                      spring-map-parser does
//   UploadLog                       -> UploadLogFinished {url} / UploadLogFailed; the
//                                      logs zipped and PUT to BAR's log_upload_url, only
//                                      when online play is enabled in this build (--online 1);
//                                      otherwise it fails with where the logs are
//   DiscordSetActivity              -> Discord Rich Presence over Discord's local IPC
//                                      socket with BAR's application id (dist_cfg); nothing
//                                      if Discord is not running
//
// Usage: sl-bridge --writedir DIR --prd PATH --engine PATH --engine-version V
//                  [--config launcher_extras.json] [--online 0|1]
//                  [--parent-pid PID] [--log FILE]
// Exits when --parent-pid (the launcher, which execs into the engine) is gone,
// removing sl-connection.json. Listens on 127.0.0.1 only.

import Foundation
import Network
import CoreGraphics
import ImageIO

// ---- arguments ---------------------------------------------------------------
var opts: [String: String] = [:]
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() { if k.hasPrefix("--"), let v = it.next() { opts[String(k.dropFirst(2))] = v } }
}
guard let writeDirArg = opts["writedir"] else {
    FileHandle.standardError.write("usage: sl-bridge --writedir DIR --prd PATH --engine PATH --engine-version V [--parent-pid PID] [--log FILE]\n".data(using: .utf8)!)
    exit(2)
}
let writeDir = URL(fileURLWithPath: writeDirArg).standardizedFileURL
let prdPath = opts["prd"] ?? ""
let enginePath = opts["engine"] ?? ""
let engineVersion = opts["engine-version"] ?? ""
let parentPid = Int32(opts["parent-pid"] ?? "") ?? 0
let logURL = opts["log"].map { URL(fileURLWithPath: $0) }
let connFile = writeDir.appendingPathComponent("sl-connection.json")
// log_upload_url + discord_rich_presence from BAR's dist_cfg (extract-launcher-config.py)
let extras: [String: Any] = opts["config"]
    .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
let onlineEnabled = opts["online"] == "1"

func log(_ s: String) {
    let line = "[sl-bridge \(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    if let u = logURL, let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else if let u = logURL { try? line.data(using: .utf8)!.write(to: u) }
    else { FileHandle.standardError.write(line.data(using: .utf8)!) }
}

// A path the lobby names must stay inside the write dir, also once symlinks are
// followed: a link inside the write dir must not lead out of it. The leaf may
// not exist yet, so the deepest existing ancestor is what gets resolved.
let writeDirResolved = writeDir.resolvingSymlinksInPath()
func staysInsideWriteDir(_ url: URL) -> Bool {
    let fm = FileManager.default
    func exists(_ p: String) -> Bool { (try? fm.attributesOfItem(atPath: p)) != nil }   // lstat: sees a dangling link
    var probe = url.standardizedFileURL
    var tail: [String] = []
    while !exists(probe.path) && probe.path != "/" {
        tail.insert(probe.lastPathComponent, at: 0)
        probe.deleteLastPathComponent()
    }
    // a link whose target does not exist cannot be resolved: refuse it
    if let t = (try? fm.attributesOfItem(atPath: probe.path))?[.type] as? FileAttributeType, t == .typeSymbolicLink,
       !fm.fileExists(atPath: probe.path) { return false }
    var resolved = probe.resolvingSymlinksInPath()
    for c in tail { resolved.appendPathComponent(c) }
    let p = resolved.path, root = writeDirResolved.path
    return p == root || p.hasPrefix(root + "/")
}
func insideWriteDir(_ rel: String) -> URL? {
    let u = writeDir.appendingPathComponent(rel).standardizedFileURL
    return (u.path.hasPrefix(writeDir.path + "/") && staysInsideWriteDir(u)) ? u : nil
}

// ---- connection --------------------------------------------------------------
final class Client {
    let conn: NWConnection
    var buffer = Data()
    init(_ c: NWConnection) { conn = c }
    func send(_ name: String, _ command: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: ["name": name, "command": command]) else { return }
        conn.send(content: d + Data([0x0A]), completion: .contentProcessed { _ in })
    }
}
var clients: [ObjectIdentifier: Client] = [:]
func broadcast(_ name: String, _ command: [String: Any]) { for c in clients.values { c.send(name, command) } }

// ---- demo (.sdfz) parsing ----------------------------------------------------
func gunzip(_ url: URL) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = ["-dc", url.path]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? d : nil
}

func i32(_ d: Data, _ o: Int) -> Int {
    guard o + 4 <= d.count else { return 0 }
    return Int(Int32(littleEndian: d.subdata(in: o..<o+4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
}

/// Start script "[section]{ key=value; [sub]{...} }" -> flat sections by lowercased name.
func parseScript(_ s: String) -> [String: [String: String]] {
    var out: [String: [String: String]] = [:]
    var stack: [String] = []
    var pending = ""
    for raw in s.components(separatedBy: CharacterSet(charactersIn: "\n\r")) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while !line.isEmpty {
            if line.hasPrefix("["), let e = line.firstIndex(of: "]") {
                pending = String(line[line.index(after: line.startIndex)..<e]).lowercased()
                line = String(line[line.index(after: e)...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("{") {
                stack.append(pending); out[pending] = out[pending] ?? [:]
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("}") {
                _ = stack.popLast()
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if let eq = line.firstIndex(of: "="), let cur = stack.last {
                let semi = line[eq...].firstIndex(of: ";") ?? line.endIndex
                let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: eq)..<semi].trimmingCharacters(in: .whitespaces)
                out[cur, default: [:]][k] = v
                line = semi < line.endIndex ? String(line[line.index(after: semi)...]).trimmingCharacters(in: .whitespaces) : ""
            } else { break }
        }
    }
    return out
}

func replayInfo(relativePath: String) -> [String: Any]? {
    guard let url = insideWriteDir(relativePath) else { log("ReadReplayInfo: path outside write dir: \(relativePath)"); return nil }
    let cacheURL = URL(fileURLWithPath: url.path + ".cache")
    if let cd = try? Data(contentsOf: cacheURL),
       let c = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
       (c["replayCacheVersion"] as? Int) == 2, (c["relativePath"] as? String) == relativePath {
        return c
    }
    guard let d = gunzip(url), d.count > 360,
          String(decoding: d.prefix(15), as: UTF8.self) == "spring demofile" else {
        log("ReadReplayInfo: not a demo: \(relativePath)"); return nil
    }
    // DemoFileHeader (rts/System/LoadSave/demofile.h), little endian.
    let headerSize = i32(d, 20)
    let versionString = String(decoding: d.subdata(in: 24..<280).prefix { $0 != 0 }, as: UTF8.self)
    let scriptSize = i32(d, 304), streamSize = i32(d, 308), gameTime = i32(d, 312)
    // offsets: magic 0, version 16, headerSize 20, versionString 24..280, gameID 280,
    // unixTime 296 (u64), scriptSize 304, demoStreamSize 308, gameTime 312, ...,
    // winningAllyTeamsSize 348 (header is 352 bytes)
    let winSize = i32(d, 348)
    // every size comes from the file: a negative one would put the slices below
    // out of range, so such a file is simply not a demo
    guard headerSize > 0, scriptSize >= 0, streamSize >= 0, winSize >= 0,
          headerSize + scriptSize <= d.count else {
        log("ReadReplayInfo: bad demo header: \(relativePath)"); return nil
    }
    let script = String(decoding: d.subdata(in: headerSize..<headerSize+scriptSize), as: UTF8.self)
    var winners: [Int] = []
    let wOff = headerSize + scriptSize + streamSize
    if winSize > 0, wOff + winSize <= d.count { winners = d.subdata(in: wOff..<wOff+winSize).map { Int($0) } }

    let s = parseScript(script)
    let game = s["game"] ?? [:]
    func allyTeam(ofTeam t: String?) -> Int? { t.flatMap { s["team\($0)"]?["allyteam"] }.flatMap { Int($0) } }
    func side(ofTeam t: String?) -> String? { t.flatMap { s["team\($0)"]?["side"] } }
    var players: [[String: Any]] = []
    for (k, v) in s.sorted(by: { $0.key < $1.key }) where k.hasPrefix("player") {
        if v["spectator"] == "1" { continue }
        guard let at = allyTeam(ofTeam: v["team"]) else { continue }
        var p: [String: Any] = ["name": v["name"] ?? "?", "allyTeamId": at, "isSpectator": false, "isBot": false]
        if let n = Int(k.dropFirst("player".count)) { p["playerId"] = n }
        if let t = v["team"].flatMap({ Int($0) }) { p["teamId"] = t }
        if let x = v["countrycode"] { p["countryCode"] = x }
        if let x = v["rank"].flatMap({ Int($0) }) { p["rank"] = x }
        if let x = v["skill"] { p["skill"] = x }
        if let x = v["skilluncertainty"] { p["skillUncertainty"] = x }
        if let x = side(ofTeam: v["team"]) { p["faction"] = x }
        players.append(p)
    }
    for (k, v) in s.sorted(by: { $0.key < $1.key }) where k.hasPrefix("ai") {
        guard let at = allyTeam(ofTeam: v["team"]) else { continue }
        var p: [String: Any] = ["name": v["name"] ?? v["shortname"] ?? "AI", "allyTeamId": at, "isSpectator": false, "isBot": true]
        if let t = v["team"].flatMap({ Int($0) }) { p["teamId"] = t }
        if let x = v["shortname"] { p["aiId"] = x }
        if let x = side(ofTeam: v["team"]) { p["faction"] = x }
        players.append(p)
    }
    let info: [String: Any] = [
        "replayCacheVersion": 2, "relativePath": relativePath, "engine": versionString,
        "game": game["gametype"] ?? "", "map": game["mapname"] ?? "",
        "players": players, "gameTime": gameTime, "winningAllyTeamIds": winners,
    ]
    if let cd = try? JSONSerialization.data(withJSONObject: info) { try? cd.write(to: cacheURL) }
    return info
}

// ---- downloads ---------------------------------------------------------------
var downloadQueue: [[String: Any]] = []
var current: (name: String, process: Process?, task: URLSessionDownloadTask?)? = nil
let queue = DispatchQueue(label: "sl-bridge")

func finishDownload(_ name: String, success: Bool, aborted: Bool) {
    queue.async {
        log("Download \(name): \(success ? "ok" : aborted ? "aborted" : "failed")")
        broadcast("DownloadFinished", ["name": name, "isSuccess": success, "isAborted": aborted])
        current = nil
        downloadQueue.removeAll { ($0["name"] as? String) == name }
        startNextDownload()
    }
}

func startNextDownload() {
    guard current == nil, let dl = downloadQueue.last, let name = dl["name"] as? String else { return }
    let type = (dl["type"] as? String ?? "").lowercased()
    broadcast("DownloadProgress", ["name": name, "progress": 0.0, "total": 0])
    switch type {
    case "game", "map":
        let p = Process()
        p.executableURL = URL(fileURLWithPath: prdPath)
        p.arguments = ["--filesystem-writepath", writeDir.path, type == "map" ? "--download-map" : "--download-game", name]
        var env = ProcessInfo.processInfo.environment
        env["PRD_RAPID_REPO_MASTER"] = "https://repos-cdn.beyondallreason.dev/repos.gz"
        env["PRD_HTTP_SEARCH_URL"] = "https://files-cdn.beyondallreason.dev/find"
        env.removeValue(forKey: "SPRING_DATADIR")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { pr in finishDownload(name, success: pr.terminationStatus == 0, aborted: pr.terminationReason == .uncaughtSignal) }
        current = (name, p, nil)
        do { try p.run(); log("Download \(type) \(name) via pr-downloader") }
        catch { log("pr-downloader failed to start: \(error)"); finishDownload(name, success: false, aborted: false) }
    case "resource":
        guard let r = dl["resource"] as? [String: Any], let urlS = r["url"] as? String,
              let src = URL(string: urlS), src.scheme == "https",
              let dest = (r["destination"] as? String).flatMap(insideWriteDir) else {
            log("Download resource \(name): needs an https url and a destination inside the write dir")
            current = (name, nil, nil); finishDownload(name, success: false, aborted: false); return
        }
        let extract = (r["extract"] as? Bool) ?? false
        let task = URLSession.shared.downloadTask(with: src) { tmp, resp, err in
            guard let tmp = tmp, err == nil, ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200 else {
                finishDownload(name, success: false, aborted: (err as? URLError)?.code == .cancelled); return
            }
            let fm = FileManager.default
            var ok = true
            if extract {
                if src.pathExtension.lowercased() == "zip" {
                    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-x", "-k", tmp.path, dest.path]
                    do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 } catch { ok = false }
                } else {
                    log("Download resource \(name): cannot extract .\(src.pathExtension) (zip only)"); ok = false
                }
            } else {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                do { try fm.moveItem(at: tmp, to: dest) } catch { ok = false }
            }
            finishDownload(name, success: ok, aborted: false)
        }
        current = (name, nil, task)
        task.resume()
        log("Download resource \(name) from \(src.host ?? "?")")
    default:
        log("Download \(name): unsupported type '\(type)' (engines cannot be downloaded on macOS)")
        current = (name, nil, nil); finishDownload(name, success: false, aborted: false)
    }
}

// ---- minimaps (ParseMiniMap) -------------------------------------------------
// A map archive (.sd7 = 7z, .sdz = zip) holds maps/<name>.smf, whose header
// points at a 1024x1024 DXT1 minimap (rts/Map/SMF/SMFFormat.h: minimapPtr is the
// 14th int32, byte 64). bsdtar (libarchive, part of macOS) reads both formats;
// only the start of the .smf is streamed, up to the end of the minimap.
let minimapQueue = DispatchQueue(label: "sl-bridge.minimap")
let MINIMAP_SIDE = 1024
let MINIMAP_BYTES = MINIMAP_SIDE * MINIMAP_SIDE / 2

func smfEntry(in archive: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
    p.arguments = ["-tf", archive]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
        .first { $0.lowercased().hasPrefix("maps/") && $0.lowercased().hasSuffix(".smf") }
}

/// The first `upTo` bytes of one archive entry (or fewer at end of entry).
func entryPrefix(archive: String, entry: String, upTo: Int) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
    p.arguments = ["-xOf", archive, entry]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    var d = Data()
    let h = out.fileHandleForReading
    while d.count < upTo {
        let chunk = h.availableData
        if chunk.isEmpty { break }
        d.append(chunk)
    }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    return d
}

func decodeDXT1(_ src: Data, side: Int) -> [UInt8] {
    var rgba = [UInt8](repeating: 255, count: side * side * 4)
    func c565(_ v: UInt16) -> (Int, Int, Int) {
        let r = Int((v >> 11) & 31), g = Int((v >> 5) & 63), b = Int(v & 31)
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }
    src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let blocks = side / 4
        for by in 0..<blocks {
            for bx in 0..<blocks {
                let o = (by * blocks + bx) * 8
                let c0 = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian
                let c1 = raw.loadUnaligned(fromByteOffset: o + 2, as: UInt16.self).littleEndian
                let bits = raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self).littleEndian
                let a = c565(c0), b = c565(c1)
                var pal: [(Int, Int, Int)] = [a, b, (0, 0, 0), (0, 0, 0)]
                if c0 > c1 {
                    pal[2] = ((2 * a.0 + b.0) / 3, (2 * a.1 + b.1) / 3, (2 * a.2 + b.2) / 3)
                    pal[3] = ((a.0 + 2 * b.0) / 3, (a.1 + 2 * b.1) / 3, (a.2 + 2 * b.2) / 3)
                } else {
                    pal[2] = ((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let c = pal[Int((bits >> UInt32(2 * (py * 4 + px))) & 3)]
                        let i = ((by * 4 + py) * side + bx * 4 + px) * 4
                        rgba[i] = UInt8(c.0); rgba[i + 1] = UInt8(c.1); rgba[i + 2] = UInt8(c.2)
                    }
                }
            }
        }
    }
    return rgba
}

func writeImage(_ rgba: [UInt8], side: Int, to url: URL) -> Bool {
    let type = url.pathExtension.lowercased() == "png" ? "public.png" : "public.jpeg"
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let img = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    return CGImageDestinationFinalize(dst)
}

func parseMiniMap(mapPath: String, dest: URL) -> Bool {
    let ext = (mapPath as NSString).pathExtension.lowercased()
    guard ext == "sd7" || ext == "sdz", FileManager.default.isReadableFile(atPath: mapPath) else {
        log("ParseMiniMap: not a map archive: \(mapPath)"); return false
    }
    guard let entry = smfEntry(in: mapPath) else { log("ParseMiniMap: no maps/*.smf in \(mapPath)"); return false }
    guard let head = entryPrefix(archive: mapPath, entry: entry, upTo: 80), head.count >= 68,
          String(decoding: head.prefix(15), as: UTF8.self) == "spring map file" else {
        log("ParseMiniMap: not an SMF: \(entry)"); return false
    }
    let ptr = i32(head, 64)
    guard ptr > 0, let d = entryPrefix(archive: mapPath, entry: entry, upTo: ptr + MINIMAP_BYTES),
          d.count >= ptr + MINIMAP_BYTES else {
        log("ParseMiniMap: minimap missing in \(entry)"); return false
    }
    let rgba = decodeDXT1(d.subdata(in: ptr..<ptr + MINIMAP_BYTES), side: MINIMAP_SIDE)
    return writeImage(rgba, side: MINIMAP_SIDE, to: dest)
}

// ---- log upload (UploadLog) --------------------------------------------------
// As spring-launcher's log_uploader: zip the recent logs plus last week's
// ClientGameState files and PUT them to <log_upload_url>/<name>.zip; the server
// answers {"downloadUrl": ...}. Only when online play is enabled in this build:
// the BAR team has not approved this port using their servers yet, and their
// public notice asks players not to report port problems to them.
func uploadLog(reply: @escaping (String, [String: Any]) -> Void) {
    guard onlineEnabled else {
        reply("UploadLogFailed", ["msg": "Log upload is switched off in this build. Your logs are in \(writeDir.path) (infolog.txt). Please report problems at https://github.com/qant-au/RecoilEngine-AppleSilicon/issues"])
        return
    }
    guard let base = extras["log_upload_url"] as? String, let baseURL = URL(string: base), baseURL.scheme == "https" else {
        reply("UploadLogFailed", ["msg": "No log upload address is configured."]); return
    }
    let fm = FileManager.default
    let weekAgo = Date().addingTimeInterval(-7 * 86400)
    let names = (try? fm.contentsOfDirectory(atPath: writeDir.path)) ?? []
    var files = names.filter { $0.hasPrefix("infolog") || $0.hasSuffix(".log") }
    files += names.filter { n in
        n.hasPrefix("ClientGameState-") &&
        ((try? fm.attributesOfItem(atPath: writeDir.appendingPathComponent(n).path)[.modificationDate] as? Date) ?? .distantPast) > weekAgo
    }
    guard !files.isEmpty else { reply("UploadLogFailed", ["msg": "No logs found in \(writeDir.path)"]); return }
    let stamp = ISO8601DateFormatter().string(from: Date()).filter { $0.isNumber || $0 == "T" }.prefix(13)
    let zipName = "logs-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).zip"
    let zipURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(zipName)
    let z = Process()
    z.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    z.currentDirectoryURL = writeDir
    z.arguments = ["-q", zipURL.path] + files
    do { try z.run(); z.waitUntilExit() } catch {}
    guard z.terminationStatus == 0, let body = try? Data(contentsOf: zipURL) else {
        reply("UploadLogFailed", ["msg": "Could not pack the logs."]); return
    }
    try? fm.removeItem(at: zipURL)
    var req = URLRequest(url: baseURL.appendingPathComponent(zipName))
    req.httpMethod = "PUT"
    req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
    URLSession.shared.uploadTask(with: req, from: body) { data, resp, err in
        if err == nil, ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2,
           let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = j["downloadUrl"] as? String {
            log("UploadLog: \(url)"); reply("UploadLogFinished", ["url": url])
        } else {
            log("UploadLog failed: \(err.map { "\($0)" } ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")")
            reply("UploadLogFailed", ["msg": "The log server did not accept the upload."])
        }
    }.resume()
}

// ---- Discord Rich Presence (DiscordSetActivity) ------------------------------
// Discord's local IPC: a Unix socket $TMPDIR/discord-ipc-<0..9>; frames are
// <op u32 LE><length u32 LE><JSON>. op 0 = handshake {v:1, client_id}, op 1 =
// command. Same fields as spring-launcher's discord_integration.js (discord-rpc).
let discordQueue = DispatchQueue(label: "sl-bridge.discord")
var discordFD: Int32 = -1

func discordFrame(_ op: UInt32, _ obj: [String: Any]) -> Data? {
    guard let json = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    var d = Data()
    withUnsafeBytes(of: op.littleEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(json.count).littleEndian) { d.append(contentsOf: $0) }
    return d + json
}

func discordWrite(_ d: Data) -> Bool {
    d.withUnsafeBytes { p in write(discordFD, p.baseAddress, d.count) == d.count }
}

func discordRead() -> [String: Any]? {
    var hdr = [UInt8](repeating: 0, count: 8)
    guard read(discordFD, &hdr, 8) == 8 else { return nil }
    let len = Int(UInt32(hdr[4]) | UInt32(hdr[5]) << 8 | UInt32(hdr[6]) << 16 | UInt32(hdr[7]) << 24)
    guard len > 0, len < 1 << 20 else { return nil }
    var buf = [UInt8](repeating: 0, count: len)
    var got = 0
    while got < len {
        let n = buf.withUnsafeMutableBytes { read(discordFD, $0.baseAddress! + got, len - got) }
        if n <= 0 { return nil }
        got += n
    }
    return try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any]
}

func discordClose() { if discordFD >= 0 { close(discordFD); discordFD = -1 } }

func discordConnect(clientId: String) -> Bool {
    if discordFD >= 0 { return true }
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    for i in 0..<10 {
        let path = (tmp as NSString).appendingPathComponent("discord-ipc-\(i)")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { continue }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); continue }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (j, b) in bytes.enumerated() { p[j] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        if !ok { close(fd); continue }
        discordFD = fd
        if let hs = discordFrame(0, ["v": 1, "client_id": clientId]), discordWrite(hs),
           let r = discordRead(), (r["evt"] as? String) == "READY" {
            log("Discord: connected (\(path))"); return true
        }
        discordClose()
    }
    return false
}

func discordSetActivity(_ cmd: [String: Any]) {
    guard let cfg = extras["discord_rich_presence"] as? [String: Any],
          let appId = cfg["application_id"] as? String else { return }
    discordQueue.async {
        guard discordConnect(clientId: appId) else { return }
        var activity: [String: Any] = ["instance": false]
        if let s = cmd["state"] as? String { activity["state"] = s }
        if let m = cmd["mapName"] as? String { activity["details"] = m }
        if let t = cmd["startTimestamp"] as? NSNumber { activity["timestamps"] = ["start": t] }
        var assets: [String: Any] = [:]
        if let m = cmd["mapName"] as? String, let u = cfg["minimap_url"] as? String,
           let enc = m.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            assets["large_image"] = u.replacingOccurrences(of: "<map>", with: enc)
        } else if let k = cfg["large_image_key_default"] { assets["large_image"] = k }
        assets["large_text"] = cmd["largeImageText"] ?? cfg["large_image_text_default"]
        assets["small_image"] = cmd["smallImageKey"] ?? cfg["small_image_key_default"]
        assets["small_text"] = cmd["smallImageText"] ?? cfg["small_image_text_default"]
        activity["assets"] = assets.compactMapValues { $0 }
        var party: [String: Any] = [:]
        if let n = (cmd["playerCount"] as? NSNumber)?.intValue, let mx = (cmd["maxPlayerCount"] as? NSNumber)?.intValue, n > 0, mx > 0 {
            party["size"] = [n, mx]
        }
        if let pid = cmd["partyId"] { party["id"] = "\(pid)" }
        if !party.isEmpty { activity["party"] = party }
        if let l = cfg["button_label"] as? String, let u = cfg["button_url"] as? String {
            activity["buttons"] = [["label": l, "url": u]]
        }
        let frame = discordFrame(1, ["cmd": "SET_ACTIVITY", "nonce": UUID().uuidString,
                                     "args": ["pid": Int(getpid()), "activity": activity]])
        if frame == nil || !discordWrite(frame!) || discordRead() == nil {
            log("Discord: connection lost"); discordClose()
        }
    }
}

// ---- command dispatch --------------------------------------------------------
func handle(_ name: String, _ cmd: [String: Any], from client: Client) {
    switch name {
    case "ReadReplayInfo":
        guard let rel = cmd["relativePath"] as? String else { return }
        DispatchQueue.global().async {
            if let info = replayInfo(relativePath: rel) { queue.async { client.send("ReplayInfo", info) } }
        }
    case "Download":
        guard let n = cmd["name"] as? String else { return }
        if downloadQueue.contains(where: { ($0["name"] as? String) == n }) { return }
        downloadQueue.append(cmd)
        startNextDownload()
    case "AbortDownload":
        guard let n = cmd["name"] as? String else { return }
        if let c = current, c.name == n { c.process?.terminate(); c.task?.cancel() }
        else if downloadQueue.contains(where: { ($0["name"] as? String) == n }) {
            downloadQueue.removeAll { ($0["name"] as? String) == n }
            client.send("DownloadFinished", ["name": n, "isSuccess": false, "isAborted": true])
        }
    case "OpenFile":
        guard let path = cmd["path"] as? String, let u = URL(string: path) else { return }
        var allowed = false
        var openArgs = [u.absoluteString]
        if u.scheme == "https" || u.scheme == "http" { allowed = true }
        else if u.scheme == "file" {
            let f = URL(fileURLWithPath: u.path).standardizedFileURL
            allowed = (f.path == writeDir.path || f.path.hasPrefix(writeDir.path + "/")) && staysInsideWriteDir(f)
            if allowed {
                // the lobby asks for <writedir>/demos/ before any replay exists: create a
                // folder inside the write dir rather than failing to open it (from
                // Vandomas/RecoilEngine-AppleSilicon 80e42afbcd)
                if u.path.hasSuffix("/") {
                    try? FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: true)
                }
                // Only a plain folder or a text/image file is opened. Anything else
                // (an app bundle, a script, an unknown type) is shown in Finder
                // instead, so nothing downloaded into the write dir gets launched.
                var isDir: ObjCBool = false
                let present = FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir)
                let ext = f.pathExtension.lowercased()
                let viewable: Set<String> = ["txt", "log", "json", "cfg", "lua", "md", "png", "jpg", "jpeg"]
                let opensDirectly = present && (isDir.boolValue ? ext.isEmpty : viewable.contains(ext))
                openArgs = opensDirectly ? [f.path] : ["-R", f.path]
            }
        }
        if allowed {
            // report open's real result, not just that it started
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = openArgs
            var ok = false
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            client.send(ok ? "OpenFileFinished" : "OpenFileFailed", ["path": path])
        } else {
            log("OpenFile refused: \(path)")
            client.send("OpenFileFailed", ["path": path])
        }
    case "StartNewSpring":
        let eng = (cmd["Engine"] as? String) ?? ""
        guard let demo = (cmd["StartDemoName"] as? String).flatMap(insideWriteDir) else { return }
        if !engineVersion.isEmpty && eng.lowercased().hasPrefix(engineVersion.lowercased()) == false {
            log("StartNewSpring refused: demo engine \(eng) != bundled \(engineVersion)")
            // say why, instead of the replay silently doing nothing (Vandomas issue #21)
            let msg = "This replay was recorded on engine \(eng.isEmpty ? "(unknown)" : eng). Accurona can only play replays recorded on engine \(engineVersion)."
            // passed as an argv item, not spliced into the script: no quoting issues
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on run argv",
                           "-e", "display dialog (item 1 of argv) buttons {\"OK\"} default button 1 with title \"Accurona\" with icon note",
                           "-e", "end run", msg]
            try? p.run()
            return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: enginePath)
        p.arguments = ["--write-dir", writeDir.path, demo.path]
        do { try p.run(); log("StartNewSpring: \(demo.lastPathComponent)") } catch { log("StartNewSpring failed: \(error)") }
    case "ParseMiniMap":
        // one at a time, off the connection queue (as spring-launcher serialises them)
        let mapPath = cmd["mapPath"] as? String ?? ""
        guard let dest = (cmd["destination"] as? String).flatMap(insideWriteDir) else {
            log("ParseMiniMap: destination outside write dir"); return
        }
        minimapQueue.async {
            let ok = parseMiniMap(mapPath: mapPath, dest: dest)
            log("ParseMiniMap \((mapPath as NSString).lastPathComponent): \(ok ? "ok" : "failed")")
            queue.async { client.send("ParseMiniMapFinished", ["mapPath": mapPath, "destinationPath": dest.path]) }
        }
    case "UploadLog":
        DispatchQueue.global().async {
            uploadLog { name, payload in queue.async { client.send(name, payload) } }
        }
    case "DiscordSetActivity":
        discordSetActivity(cmd)
    case "LoadArchiveExtensions":
        break
    default:
        log("unhandled command: \(name)")
    }
}

// ---- listener ----------------------------------------------------------------
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
params.acceptLocalOnly = true
guard let listener = try? NWListener(using: params) else { log("cannot create listener"); exit(1) }

listener.newConnectionHandler = { conn in
    let c = Client(conn)
    clients[ObjectIdentifier(c)] = c
    log("lobby connected")
    func drop(_ why: String) {
        clients.removeValue(forKey: ObjectIdentifier(c)); log(why); conn.cancel()
    }
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
            if let data = data {
                c.buffer.append(data)
                while let nl = c.buffer.firstIndex(of: 0x0A) {
                    let line = c.buffer.subdata(in: c.buffer.startIndex..<nl)
                    c.buffer.removeSubrange(c.buffer.startIndex...nl)
                    if line.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { continue }   // blank line
                    // The lobby speaks one JSON object per line and nothing else. A peer
                    // that sends any other line (an HTTP request, for one) is not the
                    // lobby: close it instead of reading on for something that parses.
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let name = obj["name"] as? String else {
                        drop("closed a connection that did not speak the lobby protocol"); return
                    }
                    handle(name, obj["command"] as? [String: Any] ?? [:], from: c)
                }
                // no lobby message is anywhere near this long without a newline
                if c.buffer.count > 1 << 20 { drop("closed a connection: line over 1 MB"); return }
            }
            if done || err != nil { drop("lobby disconnected"); return }
            receive()
        }
    }
    conn.start(queue: queue)
    receive()
}

listener.stateUpdateHandler = { st in
    switch st {
    case .ready:
        guard let port = listener.port?.rawValue else { return }
        let info: [String: Any] = ["_sl_address": "127.0.0.1", "_sl_port": Int(port), "_sl_write_path": writeDir.path,
                                   "_sl_launcher_version": "macos-sl-bridge-1"]
        if let d = try? JSONSerialization.data(withJSONObject: info) { try? d.write(to: connFile, options: .atomic) }
        log("listening on 127.0.0.1:\(port), wrote \(connFile.path)")
        print("SL_BRIDGE_READY \(port)"); fflush(stdout)
    case .failed(let e):
        log("listener failed: \(e)"); try? FileManager.default.removeItem(at: connFile); exit(1)
    default: break
    }
}
listener.start(queue: queue)

func shutdown(_ why: String) {
    log("exiting: \(why)")
    try? FileManager.default.removeItem(at: connFile)
    current?.process?.terminate()
    exit(0)
}
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let sigs = [SIGTERM, SIGINT].map { s -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: s, queue: queue)
    src.setEventHandler { shutdown("signal \(s)") }; src.resume(); return src
}
let parentWatch = DispatchSource.makeTimerSource(queue: queue)  // top level: must outlive setup
if parentPid > 0 {
    parentWatch.schedule(deadline: .now() + 2, repeating: 2)
    parentWatch.setEventHandler { if kill(parentPid, 0) != 0 && errno == ESRCH { shutdown("parent \(parentPid) gone") } }
    parentWatch.resume()
}
_ = sigs
dispatchMain()
