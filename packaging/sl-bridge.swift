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
//   ParseMiniMap                    -> ParseMiniMapFinished without an image (no
//                                      minimap extraction yet; the lobby keeps its
//                                      placeholder)
//   UploadLog, DiscordSetActivity   -> ignored
//
// Usage: sl-bridge --writedir DIR --prd PATH --engine PATH --engine-version V
//                  [--parent-pid PID] [--log FILE]
// Exits when --parent-pid (the launcher, which execs into the engine) is gone,
// removing sl-connection.json. Listens on 127.0.0.1 only.

import Foundation
import Network

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

func log(_ s: String) {
    let line = "[sl-bridge \(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    if let u = logURL, let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else if let u = logURL { try? line.data(using: .utf8)!.write(to: u) }
    else { FileHandle.standardError.write(line.data(using: .utf8)!) }
}

// A path the lobby names must stay inside the write dir.
func insideWriteDir(_ rel: String) -> URL? {
    let u = writeDir.appendingPathComponent(rel).standardizedFileURL
    return u.path.hasPrefix(writeDir.path + "/") ? u : nil
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
    guard headerSize > 0, scriptSize >= 0, headerSize + scriptSize <= d.count else { return nil }
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
        if u.scheme == "https" || u.scheme == "http" { allowed = true }
        else if u.scheme == "file" {
            let p = URL(fileURLWithPath: u.path).standardizedFileURL.path
            allowed = p == writeDir.path || p.hasPrefix(writeDir.path + "/")
        }
        if allowed {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [u.absoluteString]
            let ok = (try? p.run()) != nil
            client.send(ok ? "OpenFileFinished" : "OpenFileFailed", ["path": path])
        } else {
            log("OpenFile refused: \(path)")
            client.send("OpenFileFailed", ["path": path])
        }
    case "StartNewSpring":
        let eng = (cmd["Engine"] as? String) ?? ""
        guard let demo = (cmd["StartDemoName"] as? String).flatMap(insideWriteDir) else { return }
        if !engineVersion.isEmpty && eng.lowercased().hasPrefix(engineVersion.lowercased()) == false {
            log("StartNewSpring refused: demo engine \(eng) != bundled \(engineVersion)"); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: enginePath)
        p.arguments = ["--write-dir", writeDir.path, demo.path]
        do { try p.run(); log("StartNewSpring: \(demo.lastPathComponent)") } catch { log("StartNewSpring failed: \(error)") }
    case "ParseMiniMap":
        let dest = (cmd["destination"] as? String).flatMap(insideWriteDir)?.path ?? ""
        client.send("ParseMiniMapFinished", ["mapPath": cmd["mapPath"] ?? "", "destinationPath": dest])
    case "UploadLog", "DiscordSetActivity", "LoadArchiveExtensions":
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
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
            if let data = data {
                c.buffer.append(data)
                while let nl = c.buffer.firstIndex(of: 0x0A) {
                    let line = c.buffer.subdata(in: c.buffer.startIndex..<nl)
                    c.buffer.removeSubrange(c.buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let name = obj["name"] as? String {
                        handle(name, obj["command"] as? [String: Any] ?? [:], from: c)
                    }
                }
            }
            if done || err != nil { clients.removeValue(forKey: ObjectIdentifier(c)); log("lobby disconnected"); conn.cancel(); return }
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
