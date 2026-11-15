// PrintDeck Bridge — macOS menu-bar app (macOS 14+)
// - Captures the xTool Studio window with ScreenCaptureKit
// - Serves it as MJPEG + a status JSON on http://<mac>:8765
// - Broadcasts its address so the PrintDeck Pi finds it automatically
// - Checks whether the xTool O1 Omni is reachable on the network
import Cocoa
import ScreenCaptureKit
import Network
import IOKit
import ImageIO

// MARK: - Config ------------------------------------------------------------

struct BridgeConfig: Codable {
    var omni_ip: String?
    var port: Int?
    var window_match: String?
    var fps: Double?
    var max_width: Int?
    var device_name: String?
    var usb_match: String?
    var screen_capture: Bool?
}

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PrintDeck")
let config: BridgeConfig = {
    let url = supportDir.appendingPathComponent("config.json")
    if let d = try? Data(contentsOf: url),
       let c = try? JSONDecoder().decode(BridgeConfig.self, from: d) { return c }
    return BridgeConfig()
}()
let HTTP_PORT = UInt16(config.port ?? 8765)
let OMNI_IP = (config.omni_ip ?? "").trimmingCharacters(in: .whitespaces)
let WINDOW_MATCH = (config.window_match ?? "xTool").lowercased()
let FPS = max(0.5, min(config.fps ?? 2, 10))
let MAX_WIDTH = config.max_width ?? 1280
let DEVICE_NAME = config.device_name ?? "xTool O1 Omni"
let CAPTURE = config.screen_capture ?? false   // needs Screen Recording permission
let USB_MATCH = (config.usb_match ?? "xtool").lowercased()
let DISCOVERY_PORT: UInt16 = 47800
let MAC_NAME = Host.current().localizedName ?? "Mac"
let VERSION = (try? String(contentsOf: supportDir.appendingPathComponent("version"), encoding: .utf8))
    .map { String($0.prefix(7)) } ?? "dev"

// MARK: - Shared state ------------------------------------------------------

struct Snapshot {
    var jpeg: Data?
    var seq = 0
    var lastFrame = Date.distantPast
    var studioOpen = false
    var windowTitle = ""
    var omniOnline: Bool?
    var usbName = ""
    // From xTool Studio's own files
    var preview: Data?        // PNG of the last job sent to the Omni
    var previewVer = 0
    var scan: Data?           // JPEG of the latest bed scan
    var scanVer = 0
    var scanTime: Date?
    var jobTime: Date?
    var jobMode = ""
    var jobLayers = 0
    var permission = true
    var lastError = ""
}

final class Shared {
    private let lock = NSLock()
    private var s = Snapshot()
    func get() -> Snapshot { lock.lock(); defer { lock.unlock() }; return s }
    func update(_ f: (inout Snapshot) -> Void) { lock.lock(); f(&s); lock.unlock() }
}
let shared = Shared()
let netQueue = DispatchQueue(label: "printdeck.net")

// MARK: - Window capture ----------------------------------------------------

func jpegData(_ cg: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.65])
}

final class Capturer {
    private var window: SCWindow?
    private var lastLookup = Date.distantPast

    func start() {
        Task.detached { [self] in
            while true {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / FPS))
            }
        }
    }

    private func findWindow() async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            shared.update { $0.permission = true }
            let matches = content.windows.filter { w in
                guard let app = w.owningApplication else { return false }
                let name = app.applicationName.lowercased()
                let bid = app.bundleIdentifier.lowercased()
                return (name.contains(WINDOW_MATCH) || bid.contains(WINDOW_MATCH))
                    && w.frame.width >= 400 && w.frame.height >= 300
            }
            return matches.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        } catch {
            shared.update { $0.permission = false; $0.lastError = error.localizedDescription }
            return nil
        }
    }

    private func tick() async {
        if window == nil || Date().timeIntervalSince(lastLookup) > 3 {
            window = await findWindow()
            lastLookup = Date()
        }
        guard let win = window else {
            shared.update { s in
                s.studioOpen = false
                if Date().timeIntervalSince(s.lastFrame) > 10 { s.jpeg = nil }
            }
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = min(1.0, Double(MAX_WIDTH) / Double(win.frame.width))
        cfg.width = max(2, Int(Double(win.frame.width) * scale))
        cfg.height = max(2, Int(Double(win.frame.height) * scale))
        cfg.showsCursor = false
        do {
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let jpg = jpegData(img) else { return }
            let title = win.title ?? ""
            shared.update { s in
                s.jpeg = jpg; s.seq &+= 1; s.lastFrame = Date()
                s.studioOpen = true; s.windowTitle = title
            }
        } catch {
            window = nil
            shared.update { $0.lastError = error.localizedDescription }
        }
    }
}

// MARK: - xTool Studio files (job preview + bed scan) -------------------------

let atommDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/xTool Studio/atomm")

func mtime(_ u: URL) -> Date? {
    (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
func children(_ u: URL, dirsOnly: Bool = false) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: u, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    guard dirsOnly else { return items }
    return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
}
func newest(_ urls: [URL]) -> URL? {
    urls.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
}

/// Small version of a (possibly huge) image. PNG keeps transparency.
func shrink(_ url: URL, maxPixels: Int, png: Bool) -> Data? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return png ? rep.representation(using: .png, properties: [:])
               : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
}

final class StudioWatcher {
    private let q = DispatchQueue(label: "printdeck.studio", qos: .utility)
    private var previewKey = "", scanKey = ""

    func start() { q.async { self.loop() } }

    private func loop() {
        scanJobs()
        scanBed()
        q.asyncAfter(deadline: .now() + 5) { self.loop() }
    }

    /// atomm/<model>/task/<job>/  - newest job folder across all models (e.g. DT002)
    private func scanJobs() {
        let tasks = children(atommDir, dirsOnly: true).flatMap { model -> [URL] in
            let t = model.appendingPathComponent("task")
            return exists(t) ? children(t, dirsOnly: true) : []
        }
        guard let job = newest(tasks) else { return }
        let uvDirs = children(job.appendingPathComponent("uv"), dirsOnly: true)
        var candidates = [job.appendingPathComponent("dtf/preLook.thumb.png"),
                          job.appendingPathComponent("dtf/preLook.png")]
        candidates += uvDirs.map { $0.appendingPathComponent("source.png") }
        let img = candidates.first(where: exists)
        var modes: [String] = []
        if !uvDirs.isEmpty { modes.append("UV") }
        if exists(job.appendingPathComponent("dtf")) { modes.append("DTF") }
        let layers = uvDirs.reduce(0) { $0 + children($1.appendingPathComponent("layers")).count }
        let when = mtime(job)

        let key = (img?.path ?? "") + "\(mtime(img ?? job) ?? Date.distantPast)"
        var data: Data? = nil
        let changed = key != previewKey
        if changed, let img = img { data = shrink(img, maxPixels: 600, png: true) }
        if changed { previewKey = key }
        shared.update { s in
            s.jobTime = when; s.jobMode = modes.joined(separator: " + "); s.jobLayers = layers
            if changed { s.preview = data; s.previewVer &+= 1 }
        }
    }

    /// atomm/temp_project/<project>/cisScanRes/output/result.jpeg - newest bed scan
    private func scanBed() {
        let projects = children(atommDir.appendingPathComponent("temp_project"), dirsOnly: true)
        let scans = projects.flatMap { p -> [URL] in
            let r = p.appendingPathComponent("cisScanRes")
            return [r.appendingPathComponent("output/result.jpeg"),
                    r.appendingPathComponent("bgImg_uvPrint_big.jpeg")].filter(exists)
        }
        guard let scan = newest(scans) else { return }
        let when = mtime(scan)
        let key = scan.path + "\(when ?? Date.distantPast)"
        guard key != scanKey else { return }
        scanKey = key
        let data = shrink(scan, maxPixels: 1280, png: false)
        shared.update { s in s.scan = data; s.scanVer &+= 1; s.scanTime = when }
    }
}

// MARK: - USB detection -----------------------------------------------------

func usbProp(_ svc: io_object_t, _ key: String) -> String {
    let v = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (v as? String) ?? ""
}

/// Every USB device plugged into the Mac: "Vendor Product"
func listUSBDevices() -> [String] {
    var out: [String] = []
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS
    else { return out }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        let name = usbProp(svc, "USB Product Name")
        let vendor = usbProp(svc, "USB Vendor Name")
        IOObjectRelease(svc)
        let full = [vendor, name].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { out.append(full) }
    }
    return out
}

// MARK: - Omni reachability -------------------------------------------------

final class OmniChecker {
    private let q = DispatchQueue(label: "printdeck.omni")
    private let ports: [NWEndpoint.Port] = [28900, 8080, 80, 443]

    func start() {
        if OMNI_IP.isEmpty { q.async { self.checkUSB() } }   // Omni plugged in by USB
        else { q.async { self.check() } }                    // Omni on the network
    }

    private func checkUSB() {
        // xTool devices report as Makeblock ("makeblock_cm") over USB
        let keys = Set([USB_MATCH, "makeblock", "xtool"])
        let hit = listUSBDevices().first { d in keys.contains { d.lowercased().contains($0) } }
        shared.update { $0.omniOnline = hit != nil; $0.usbName = hit ?? "" }
        q.asyncAfter(deadline: .now() + 3) { self.checkUSB() }
    }

    private func check() {
        var resolved = false
        var failed = Set<Int>()
        var conns: [NWConnection] = []
        let finish: (Bool) -> Void = { ok in
            if resolved { return }
            resolved = true
            conns.forEach { $0.cancel() }
            shared.update { $0.omniOnline = ok }
            self.q.asyncAfter(deadline: .now() + 5) { self.check() }
        }
        for (i, p) in ports.enumerated() {
            let c = NWConnection(host: NWEndpoint.Host(OMNI_IP), port: p, using: .tcp)
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting:
                    failed.insert(i)
                    if failed.count == self.ports.count { finish(false) }
                default: break
                }
            }
            conns.append(c)
        }
        conns.forEach { $0.start(queue: q) }
        q.asyncAfter(deadline: .now() + 3) { finish(false) }
    }
}

// MARK: - Discovery broadcast -----------------------------------------------

func sendBroadcast() {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = DISCOVERY_PORT.bigEndian
    addr.sin_addr.s_addr = in_addr_t(0xFFFF_FFFF)
    let msg = Array("PRINTDECK_OMNI_BRIDGE \(HTTP_PORT)".utf8)
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            sendto(fd, msg, msg.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

// MARK: - HTTP server -------------------------------------------------------

func cleanTitle(_ t: String) -> String {
    var s = t
    for junk in [" - xTool Studio", "xTool Studio - ", "xTool Studio"] {
        s = s.replacingOccurrences(of: junk, with: "")
    }
    return s.trimmingCharacters(in: .whitespaces)
}

func statusJSON() -> Data {
    let s = shared.get()
    let fresh = s.jpeg != nil && Date().timeIntervalSince(s.lastFrame) < 10
    var state = "Online", color = "good"
    if !s.permission { state = "Needs permission"; color = "bad" }
    else if s.omniOnline == false { state = OMNI_IP.isEmpty ? "Omni unplugged" : "Omni offline"; color = "bad" }
    else if CAPTURE && !s.studioOpen { state = "Studio closed"; color = "warn" }

    var fields: [[String]] = []
    if OMNI_IP.isEmpty {
        let o = s.omniOnline.map { $0 ? "Connected" : "Not plugged in" } ?? "Checking…"
        fields.append(["Omni USB", o])
    } else {
        let o = s.omniOnline.map { $0 ? "Online" : "Offline" } ?? "Checking…"
        fields.append(["Omni", o])
        fields.append(["Omni IP", OMNI_IP])
    }
    if CAPTURE { fields.append(["xTool Studio", s.studioOpen ? "Open" : "Closed"]) }
    let df = DateFormatter(); df.dateFormat = "MMM d, h:mm a"
    if let t = s.jobTime { fields.append(["Last job sent", df.string(from: t)]) }
    if !s.jobMode.isEmpty { fields.append(["Mode", s.jobMode]) }
    if s.jobLayers > 0 { fields.append(["Layers", "\(s.jobLayers)"]) }
    if let t = s.scanTime { fields.append(["Last bed scan", df.string(from: t)]) }
    var title: String
    var subtitle: String
    if CAPTURE {
        let t = cleanTitle(s.windowTitle)
        title = t.isEmpty ? "xTool Studio" : t
        if !s.permission { subtitle = "Allow Screen Recording for PrintDeck Bridge on the Mac" }
        else if s.studioOpen { subtitle = "Live view of xTool Studio" }
        else { subtitle = "Open xTool Studio on the Mac" }
    } else {
        if let jt = s.jobTime {
            title = "Last job · " + RelativeDateTimeFormatter().localizedString(for: jt, relativeTo: Date())
        } else {
            title = s.omniOnline == true ? "Connected to Mac" : "Not connected"
        }
        if s.preview != nil && s.scan != nil { subtitle = "Job preview · latest bed scan in the corner" }
        else if s.preview != nil { subtitle = "Preview of the last job" }
        else if s.scan != nil { subtitle = "Latest bed scan" }
        else { subtitle = "Send a job from xTool Studio to see it here" }
    }
    var o: [String: Any] = [:]
    o["device_name"] = DEVICE_NAME
    o["state"] = state
    o["state_color"] = color
    o["title"] = title
    o["subtitle"] = subtitle
    o["stream"] = fresh
    o["fields"] = fields
    o["bridge_version"] = VERSION
    if s.scan != nil { o["image"] = "/scan.jpg?v=\(s.scanVer)" }
    if s.preview != nil { o["thumb"] = "/preview.png?v=\(s.previewVer)" }
    return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
}

let previewHTML = """
<!doctype html><html><head><meta charset="utf-8"><title>PrintDeck Bridge</title>
<style>body{background:#07090d;color:#eef1f7;font-family:system-ui;margin:24px}
img{max-width:100%;border-radius:12px;background:#000}pre{background:#10141c;padding:12px;border-radius:8px}</style>
</head><body><h2>PrintDeck Bridge</h2><img src="/scan.jpg" style="max-width:48%"> <img src="/preview.png" style="max-width:48%"><pre id="s"></pre>
<script>setInterval(async()=>{document.getElementById('s').textContent=
JSON.stringify(await (await fetch('/status.json')).json(),null,2)},2000)</script></body></html>
"""

func isClosed(_ c: NWConnection) -> Bool {
    switch c.state {
    case .cancelled, .failed: return true
    default: return false
    }
}

func respond(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        + "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    var d = Data(head.utf8)
    d.append(body)
    c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
}

func pushFrame(_ c: NWConnection, lastSeq: Int) {
    if isClosed(c) { return }
    let s = shared.get()
    guard let jpg = s.jpeg, s.seq != lastSeq else {
        netQueue.asyncAfter(deadline: .now() + 0.1) { pushFrame(c, lastSeq: lastSeq) }
        return
    }
    var d = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8)
    d.append(jpg)
    d.append(Data("\r\n".utf8))
    c.send(content: d, completion: .contentProcessed { err in
        if err != nil { c.cancel(); return }
        netQueue.asyncAfter(deadline: .now() + 0.05) { pushFrame(c, lastSeq: s.seq) }
    })
}

func streamMJPEG(_ c: NWConnection) {
    let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
        + "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
    c.send(content: Data(head.utf8), completion: .contentProcessed { err in
        if err != nil { c.cancel(); return }
        pushFrame(c, lastSeq: -1)
    })
}

func handle(_ c: NWConnection) {
    c.start(queue: netQueue)
    c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
        guard let data = data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
        let target = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = target.split(separator: "?").first.map(String.init) ?? "/"
        switch path {
        case "/status.json": respond(c, "200 OK", "application/json", statusJSON())
        case "/stream.mjpg": streamMJPEG(c)
        case "/snapshot.jpg":
            if let j = shared.get().jpeg { respond(c, "200 OK", "image/jpeg", j) }
            else { respond(c, "404 Not Found", "text/plain", Data("no frame".utf8)) }
        case "/scan.jpg":
            if let j = shared.get().scan { respond(c, "200 OK", "image/jpeg", j) }
            else { respond(c, "404 Not Found", "text/plain", Data("no scan".utf8)) }
        case "/preview.png":
            if let p = shared.get().preview { respond(c, "200 OK", "image/png", p) }
            else { respond(c, "404 Not Found", "text/plain", Data("no preview".utf8)) }
        case "/usb.json":
            let body = (try? JSONSerialization.data(withJSONObject: listUSBDevices(), options: .prettyPrinted)) ?? Data("[]".utf8)
            respond(c, "200 OK", "application/json", body)
        case "/": respond(c, "200 OK", "text/html; charset=utf-8", Data(previewHTML.utf8))
        default: respond(c, "404 Not Found", "text/plain", Data("not found".utf8))
        }
    }
}

func startHTTP() -> NWListener? {
    do {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: HTTP_PORT)!)
        l.newConnectionHandler = { handle($0) }
        l.start(queue: netQueue)
        return l
    } catch {
        shared.update { $0.lastError = "HTTP server: \(error.localizedDescription)" }
        return nil
    }
}

// MARK: - Menu bar app ------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    let omniLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let capturer = Capturer()
    let omni = OmniChecker()
    let studio = StudioWatcher()
    var listener: NWListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "printer", accessibilityDescription: "PrintDeck Bridge") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "PD"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "PrintDeck Bridge \(VERSION)", action: nil, keyEquivalent: ""))
        menu.addItem(statusLine)
        menu.addItem(omniLine)
        menu.addItem(.separator())
        menu.addItem(item("Open Preview", #selector(openPreview)))
        menu.addItem(item("Screen Recording Settings…", #selector(openPrivacy)))
        menu.addItem(item("Show USB Devices", #selector(openUSB)))
        menu.addItem(item("Open Config Folder", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
        statusItem.menu = menu

        listener = startHTTP()
        if CAPTURE {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            capturer.start()
        }
        omni.start()
        studio.start()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        refresh()
    }

    func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func refresh() {
        netQueue.async { sendBroadcast() }
        let s = shared.get()
        if !CAPTURE { statusLine.title = "Screen capture off · sharing USB status" }
        else if !s.permission { statusLine.title = "⚠️ Needs Screen Recording permission" }
        else if s.studioOpen { statusLine.title = "● Streaming xTool Studio on port \(HTTP_PORT)" }
        else { statusLine.title = "○ xTool Studio not open" }
        if OMNI_IP.isEmpty {
            omniLine.title = "Omni USB: " + (s.omniOnline.map { $0 ? "connected (\(s.usbName))" : "not found" } ?? "checking…")
        }
        else { omniLine.title = "Omni \(OMNI_IP): " + (s.omniOnline.map { $0 ? "online" : "offline" } ?? "checking…") }
    }

    @objc func openPreview() { NSWorkspace.shared.open(URL(string: "http://localhost:\(HTTP_PORT)")!) }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func openUSB() { NSWorkspace.shared.open(URL(string: "http://localhost:\(HTTP_PORT)/usb.json")!) }
    @objc func openConfig() { NSWorkspace.shared.open(supportDir) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
