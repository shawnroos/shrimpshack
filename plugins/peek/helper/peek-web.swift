import AppKit
import Darwin
import WebKit

func emitLine(_ object: [String: Any]) {
  guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
  data.append(0x0A)
  data.withUnsafeBytes { raw in
    var offset = 0
    while offset < raw.count {
      let n = write(1, raw.baseAddress! + offset, raw.count - offset)
      if n < 0 { if errno == EINTR { continue }; return }
      offset += n
    }
  }
}

func debug(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usage(_ message: String) -> Never {
  FileHandle.standardError.write(Data("peek-web: \(message)\nusage: peek-web --width <W> --height <H>\n".utf8))
  exit(2)
}

func clampViewport(_ v: Double) -> CGFloat { CGFloat(min(4096, max(100, v.rounded()))) }

func parseArgs() -> (CGFloat, CGFloat) {
  var width: Double?
  var height: Double?
  var args = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = args.next() {
    switch arg {
    case "--width", "--height":
      guard let raw = args.next(), let value = Double(raw), value.isFinite, value > 0 else { usage("\(arg) needs a positive number") }
      if arg == "--width" { width = value } else { height = value }
    default:
      usage("unknown argument \(arg)")
    }
  }
  guard let width, let height else { usage("--width and --height are required") }
  return (clampViewport(width), clampViewport(height))
}

func makeRunDir() -> String {
  func attempt(_ base: String) -> String? {
    var template = Array("\(base)/peek-web.XXXXXX".utf8CString)
    guard let result = mkdtemp(&template) else { return nil }
    return String(cString: result)
  }
  var base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
  while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
  if base.isEmpty { base = "/tmp" }
  if let dir = attempt(base), (dir + "/ctl.sock").utf8.count < 104 { return dir }
  else if let dir = attempt(base) { try? FileManager.default.removeItem(atPath: dir) }
  guard let dir = attempt("/tmp") else { debug("peek-web: cannot create run directory"); exit(1) }
  return dir
}

final class HiddenWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

struct Response {
  var status: Int
  var body: [String: Any]
  var after: (() -> Void)?
  static let ok = Response(status: 200, body: ["ok": true])
  static func bad(_ message: String, status: Int = 400) -> Response { Response(status: status, body: ["ok": false, "error": message]) }
}

final class ControlServer {
  let path: String
  private var fd: Int32 = -1
  private let handler: (String, String, Data) -> Response

  init(path: String, handler: @escaping (String, String, Data) -> Response) {
    self.path = path
    self.handler = handler
  }

  func start() -> Bool {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in bytes.enumerated() { buf[i] = b }
      buf[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 16) == 0 else { return false }
    let listenFd = fd
    let thread = Thread { [weak self] in
      while true {
        let client = accept(listenFd, nil, nil)
        if client < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; return }
        DispatchQueue.global(qos: .userInitiated).async { self?.serve(client) }
      }
    }
    thread.start()
    return true
  }

  func close() {
    if fd >= 0 { Darwin.close(fd); fd = -1 }
    unlink(path)
  }

  private func serve(_ client: Int32) {
    defer { Darwin.close(client) }
    var one: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16384)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      let n = recv(client, &chunk, chunk.count, 0)
      if n <= 0 { return }
      buffer.append(contentsOf: chunk[0..<n])
      headerEnd = buffer.range(of: separator)
      if headerEnd == nil && buffer.count > 65536 { return }
    }
    let head = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { reply(client, .bad("malformed request")); return }
    var contentLength = 0
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
      }
    }
    guard contentLength >= 0, contentLength <= 1 << 20 else { reply(client, .bad("bad content-length")); return }
    var body = Data(buffer[headerEnd!.upperBound...])
    while body.count < contentLength {
      let n = recv(client, &chunk, chunk.count, 0)
      if n <= 0 { return }
      body.append(contentsOf: chunk[0..<n])
    }
    body = body.prefix(contentLength)
    let method = String(requestLine[0])
    let path = String(requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    let response = DispatchQueue.main.sync { handler(method, path, body) }
    reply(client, response)
    if let after = response.after { DispatchQueue.main.async(execute: after) }
  }

  private func reply(_ client: Int32, _ response: Response) {
    let body = (try? JSONSerialization.data(withJSONObject: response.body)) ?? Data("{}".utf8)
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][response.status] ?? "Error"
    var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    data.append(body)
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = send(client, raw.baseAddress! + offset, raw.count - offset, 0)
        if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
        offset += n
      }
    }
  }
}

let dirtyScript = """
(function () {
  if (window.__peekDirtyInstalled) return;
  window.__peekDirtyInstalled = true;
  var raf = window.requestAnimationFrame.bind(window);
  var last = 0, pending = null;
  function post() {
    var now = Date.now();
    if (now - last >= 30) {
      last = now;
      try { window.webkit.messageHandlers.peekDirty.postMessage(1); } catch (e) {}
    } else if (!pending) {
      pending = setTimeout(function () { pending = null; post(); }, 30 - (now - last));
    }
  }
  new MutationObserver(post).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  addEventListener('scroll', post, true);
  // Canvas and WebGL drawing mutate nothing, so a page's own rAF callbacks count as "something moved".
  window.requestAnimationFrame = function (cb) { return raf(function (t) { post(); cb(t); }); };
  function loop() {
    try {
      if (document.getAnimations && document.getAnimations().length > 0) post();
      else { var vs = document.getElementsByTagName('video'); for (var i = 0; i < vs.length; i++) if (!vs[i].paused) { post(); break; } }
    } catch (e) {}
    raf(loop);
  }
  raf(loop);
})();
"""

let editableScript = """
(function () {
  var e = document.activeElement;
  if (!e) return false;
  if (e.isContentEditable) return true;
  if (e.disabled || e.readOnly) return false;
  if (e.tagName === 'TEXTAREA') return true;
  if (e.tagName !== 'INPUT') return false;
  var t = (e.getAttribute('type') || 'text').toLowerCase();
  return ['text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date', 'datetime-local', 'month', 'time', 'week'].indexOf(t) >= 0;
})()
"""

let scrollScript = """
var el = document.elementFromPoint(x, y);
while (el && el !== document.body && el !== document.documentElement) {
  var s = getComputedStyle(el);
  if (/(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight) { el.scrollBy(0, dy); return; }
  el = el.parentElement;
}
(document.scrollingElement || document.documentElement).scrollBy(0, dy);
"""

func functionKey(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }

let keyTable: [String: (code: UInt16, chars: String, flags: NSEvent.ModifierFlags)] = [
  "Enter": (36, "\r", []),
  "Tab": (48, "\t", []),
  "Backspace": (51, "\u{7f}", []),
  "Delete": (117, functionKey(NSDeleteFunctionKey), [.function]),
  "ArrowUp": (126, functionKey(NSUpArrowFunctionKey), [.function, .numericPad]),
  "ArrowDown": (125, functionKey(NSDownArrowFunctionKey), [.function, .numericPad]),
  "ArrowLeft": (123, functionKey(NSLeftArrowFunctionKey), [.function, .numericPad]),
  "ArrowRight": (124, functionKey(NSRightArrowFunctionKey), [.function, .numericPad]),
  "PageUp": (116, functionKey(NSPageUpFunctionKey), [.function]),
  "PageDown": (121, functionKey(NSPageDownFunctionKey), [.function]),
  "Home": (115, functionKey(NSHomeFunctionKey), [.function]),
  "End": (119, functionKey(NSEndFunctionKey), [.function]),
  "Space": (49, " ", []),
]

enum InputEvent {
  case click(CGFloat, CGFloat)
  case scroll(Double, Double, Double)
  case text(String)
  case key(String)
}

func number(_ any: Any?) -> Double? {
  guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
  let d = n.doubleValue
  return d.isFinite ? d : nil
}

func isWebScheme(_ url: URL?) -> Bool {
  guard let scheme = url?.scheme?.lowercased() else { return false }
  return scheme == "http" || scheme == "https"
}

// Rate first, then scale: stepping up walks this list backwards, so scale recovers before rate.
let qualityLevels: [(rate: Double, scale: CGFloat)] = [(30, 1), (15, 1), (10, 1), (5, 1), (5, 0.75), (5, 0.5)]
// Measured: the terminal pane path chokes above ~1.2 MB/s.
let byteBudget = 1_000_000

final class Helper: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  let runDir: String
  var viewport: NSSize
  let window: HiddenWindow
  let web: WKWebView
  var throttled = true
  var server: ControlServer!

  var dirty = false
  var paused = false
  var inFlight = false
  var frameId = 0
  var frames: [(path: String, at: TimeInterval)] = []
  var sent: [(at: TimeInterval, bytes: Int)] = []
  var lastFrameBytes = 0
  var level = 0
  var frameWaited = false
  var waitedInARow = 0
  var lastWaitOrStep: TimeInterval = 0
  var frameTimer: Timer?
  var cookieTimer: Timer?
  var cookiesPresent: Bool?
  var firstLoadDone = false
  var lastNav: [String: AnyHashable] = [:]
  var observers: [NSKeyValueObservation] = []
  var cleanedUp = false
  var inputQueue: [InputEvent] = []
  var inputRunning = false

  init(width: CGFloat, height: CGFloat, runDir: String) {
    self.runDir = runDir
    viewport = NSSize(width: width, height: height)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let rect = NSRect(origin: .zero, size: viewport)
    window = HiddenWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    web = WKWebView(frame: rect, configuration: config)
    super.init()
    config.userContentController.addUserScript(WKUserScript(source: dirtyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    config.userContentController.add(self, name: "peekDirty")
    web.navigationDelegate = self
    web.uiDelegate = self

    let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    if web.responds(to: sel), let method = class_getInstanceMethod(type(of: web), sel) {
      // perform(_:with:) would pass an object pointer into a BOOL slot; call the IMP with a real Bool.
      typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
      unsafeBitCast(method_getImplementation(method), to: SetBool.self)(web, sel, false)
      throttled = false
    }

    window.isOpaque = false
    window.alphaValue = 0.01
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.makeFirstResponder(web)
    window.orderBack(nil)

    observers = [
      web.observe(\.url) { [weak self] _, _ in self?.emitNav() },
      web.observe(\.title) { [weak self] _, _ in self?.emitNav() },
      web.observe(\.canGoBack) { [weak self] _, _ in self?.emitNav() },
      web.observe(\.canGoForward) { [weak self] _, _ in self?.emitNav() },
    ]
  }

  func start() {
    server = ControlServer(path: runDir + "/ctl.sock") { [unowned self] method, path, body in
      self.handle(method: method, path: path, body: body)
    }
    guard server.start() else { debug("peek-web: cannot start control socket"); shutdown(1) }
    scheduleFrameTimer()
    cookieTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, !self.paused, self.firstLoadDone else { return }
      self.checkCookies(force: false)
    }
    emit(["t": "ready", "socket": server.path, "dir": runDir, "throttled": throttled])
  }

  func shutdown(_ code: Int32) -> Never {
    if !cleanedUp {
      cleanedUp = true
      server?.close()
      try? FileManager.default.removeItem(atPath: runDir)
    }
    exit(code)
  }

  func emitNav(force: Bool = false) {
    let nav: [String: AnyHashable] = [
      "t": "nav", "url": web.url?.absoluteString ?? "", "title": web.title ?? "",
      "canBack": web.canGoBack, "canForward": web.canGoForward,
    ]
    if nav == lastNav && !force { return }
    lastNav = nav
    emit(nav)
  }

  func emitError(_ message: String) { emit(["t": "error", "message": message]) }

  func checkCookies(force: Bool) {
    web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let present = !cookies.isEmpty
      if force || present != self.cookiesPresent {
        self.cookiesPresent = present
        self.emit(["t": "cookies", "present": present])
      }
    }
  }

  func emit(_ object: [String: Any]) { emitLine(object) }

  func handle(method: String, path: String, body: Data) -> Response {
    let response = route(method: method, path: path, body: body)
    if response.status != 200, let message = response.body["error"] as? String { emitError("\(path): \(message)") }
    return response
  }

  private func route(method: String, path: String, body: Data) -> Response {
    let known = ["/navigate", "/back", "/reload", "/resize", "/input", "/pause", "/resume", "/quit"]
    guard known.contains(path) else { return .bad("unknown path", status: 404) }
    guard method == "POST" else { return .bad("POST only", status: 405) }
    var json: [String: Any] = [:]
    if !body.isEmpty {
      guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .bad("body must be a JSON object") }
      json = parsed
    }
    switch path {
    case "/navigate":
      guard let raw = json["url"] as? String, let url = URL(string: raw), isWebScheme(url), url.host?.isEmpty == false else {
        return .bad("only http and https URLs are allowed")
      }
      web.load(URLRequest(url: url))
      dirty = true
    case "/back":
      if web.canGoBack { web.goBack() }
    case "/reload":
      web.reload()
    case "/resize":
      guard let w = number(json["width"]), let h = number(json["height"]) else { return .bad("width and height must be numbers") }
      viewport = NSSize(width: clampViewport(w), height: clampViewport(h))
      window.setFrame(NSRect(origin: .zero, size: viewport), display: false)
      web.frame = NSRect(origin: .zero, size: viewport)
      dirty = true
    case "/input":
      guard let list = json["events"] as? [[String: Any]] else { return .bad("events must be an array of objects") }
      var events: [InputEvent] = []
      for item in list {
        switch item["type"] as? String {
        case "click":
          guard let x = number(item["x"]), let y = number(item["y"]) else { return .bad("click needs numeric x and y") }
          events.append(.click(CGFloat(x), CGFloat(y)))
        case "scroll":
          guard let x = number(item["x"]), let y = number(item["y"]), let dy = number(item["dy"]) else { return .bad("scroll needs numeric x, y and dy") }
          events.append(.scroll(x, y, dy))
        case "text":
          guard let text = item["text"] as? String else { return .bad("text needs a string") }
          events.append(.text(text))
        case "key":
          guard let key = item["key"] as? String, keyTable[key] != nil else { return .bad("unknown key") }
          events.append(.key(key))
        default:
          return .bad("unknown input type")
        }
      }
      inputQueue += events
      runInputQueue()
      dirty = true
    case "/pause":
      paused = true
    case "/resume":
      paused = false
      dirty = true
    case "/quit":
      return Response(status: 200, body: ["ok": true], after: { [unowned self] in self.shutdown(0) })
    default:
      break
    }
    return .ok
  }

  func runInputQueue() {
    guard !inputRunning, !inputQueue.isEmpty else { return }
    let event = inputQueue.removeFirst()
    inputRunning = true
    let next = { [weak self] in
      guard let self else { return }
      self.inputRunning = false
      self.dirty = true
      self.runInputQueue()
    }
    guard case let .key(name) = event, let key = keyTable[name] else {
      apply(event)
      web.evaluateJavaScript("0") { _, _ in next() }
      return
    }
    window.makeFirstResponder(web)
    sendKey(key, .keyDown) { self.sendKey(key, .keyUp, then: next) }
  }

  // WebKit holds mouse and key events in queues until the page acknowledges the previous one, while
  // insertText goes straight through; a script round trip after each event keeps the next event behind it.
  func sendKey(_ key: (code: UInt16, chars: String, flags: NSEvent.ModifierFlags), _ type: NSEvent.EventType, then: @escaping () -> Void) {
    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: key.chars,
                                charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code) {
      window.sendEvent(e)
    }
    web.evaluateJavaScript("0") { _, _ in then() }
  }

  func apply(_ event: InputEvent) {
    switch event {
    case let .click(x, y):
      let point = NSPoint(x: x, y: viewport.height - y)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(e)
        }
      }
      // WebKit moves focus asynchronously after mouseUp; reading activeElement immediately sees the old element.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.web.evaluateJavaScript(editableScript) { result, _ in
          emitLine(["t": "focus", "editable": (result as? Bool) ?? false])
        }
      }
    case let .scroll(x, y, dy):
      web.callAsyncJavaScript(scrollScript, arguments: ["x": x, "y": y, "dy": dy], in: nil, in: .page) { _ in }
    case let .text(text):
      window.makeFirstResponder(web)
      web.insertText(text)
    case .key:
      break
    }
  }

  func scheduleFrameTimer() {
    frameTimer?.invalidate()
    let timer = Timer(timeInterval: 1 / qualityLevels[level].rate, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  var windowBytes: Int { sent.reduce(0) { $0 + $1.bytes } }

  func overBudget(_ bytes: Int) -> Bool {
    let used = windowBytes
    return used > 0 && used + bytes > byteBudget
  }

  func noteWait(_ now: TimeInterval) {
    frameWaited = true
    lastWaitOrStep = now
  }

  func setLevel(_ newLevel: Int, _ now: TimeInterval) {
    level = newLevel
    lastWaitOrStep = now
    debug("peek-web: rate=\(qualityLevels[level].rate) scale=\(qualityLevels[level].scale)")
    scheduleFrameTimer()
  }

  func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    sent.removeAll { now - $0.at > 1 }
    while let oldest = frames.first, now - oldest.at > 1 {
      unlink(oldest.path)
      frames.removeFirst()
    }
    if level > 0 && now - lastWaitOrStep >= 3 { setLevel(level - 1, now) }
    guard !paused, dirty, !inFlight else { return }
    if overBudget(lastFrameBytes) { noteWait(now); return }
    dirty = false
    inFlight = true
    let scale = qualityLevels[level].scale
    let config = WKSnapshotConfiguration()
    config.afterScreenUpdates = true
    // snapshotWidth is in points and the image comes back at the backing scale, so divide it out to get 1x pixels.
    config.snapshotWidth = NSNumber(value: Double(viewport.width * scale / max(1, window.backingScaleFactor)))
    web.takeSnapshot(with: config) { [weak self] image, error in
      guard let self else { return }
      guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        self.inFlight = false
        if let error { debug("peek-web: snapshot failed: \(error.localizedDescription)") }
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        DispatchQueue.main.async { self.finishFrame(png, width: cg.width, height: cg.height) }
      }
    }
  }

  func finishFrame(_ png: Data?, width: Int, height: Int) {
    inFlight = false
    guard let png, !paused else { return }
    let now = ProcessInfo.processInfo.systemUptime
    lastFrameBytes = png.count
    if overBudget(png.count) {
      dirty = true
      noteWait(now)
      return
    }
    frameId += 1
    let path = "\(runDir)/frame-\(frameId).png"
    let temp = "\(runDir)/.frame-\(frameId).tmp"
    guard FileManager.default.createFile(atPath: temp, contents: png), rename(temp, path) == 0 else {
      unlink(temp)
      debug("peek-web: cannot write frame")
      return
    }
    frames.append((path, now))
    sent.append((now, png.count))
    emit(["t": "frame", "id": frameId, "path": path, "width": width, "height": height, "bytes": png.count])
    if frameWaited {
      waitedInARow += 1
      if waitedInARow >= 3 {
        waitedInARow = 0
        if level < qualityLevels.count - 1 { setLevel(level + 1, now) }
      }
    } else {
      waitedInARow = 0
    }
    frameWaited = false
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "peekDirty" { dirty = true }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if action.shouldPerformDownload {
      emitError("download blocked: \(action.request.url?.absoluteString ?? "")")
      decisionHandler(.cancel)
      return
    }
    let url = action.request.url
    let scheme = url?.scheme?.lowercased() ?? ""
    let mainFrame = action.targetFrame?.isMainFrame ?? true
    // Subframes routinely use about:srcdoc, data: and blob: documents; none of them can reach the disk or launch an app.
    let allowed = isWebScheme(url)
      || url?.absoluteString == "about:blank"
      || (!mainFrame && ["about", "data", "blob"].contains(scheme))
    if allowed {
      decisionHandler(.allow)
    } else {
      emitError("navigation refused: \(url?.absoluteString ?? "")")
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if response.canShowMIMEType {
      decisionHandler(.allow)
    } else {
      emitError("download blocked: \(response.response.url?.absoluteString ?? "")")
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    emit(["t": "load", "state": "loading"])
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    dirty = true
    emitNav(force: true)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    dirty = true
    emitNav()
    emit(["t": "load", "state": "ready"])
    checkCookies(force: !firstLoadDone)
    firstLoadDone = true
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }

  func loadFailed(_ error: Error) {
    let ns = error as NSError
    // -999 means a newer navigation replaced this one; that newer load reports its own state.
    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
    dirty = true
    emit(["t": "load", "state": "failed", "error": ns.localizedDescription])
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    emit(["t": "load", "state": "failed", "error": "web content process terminated"])
    webView.reload()
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
               windowFeatures: WKWindowFeatures) -> WKWebView? {
    if isWebScheme(action.request.url) { webView.load(action.request) }
    else { emitError("navigation refused: \(action.request.url?.absoluteString ?? "")") }
    return nil
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping () -> Void) { completionHandler() }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
}

let (initialWidth, initialHeight) = parseArgs()
signal(SIGPIPE, SIG_IGN)
NSApplication.shared.setActivationPolicy(.accessory)
let runDir = makeRunDir()
let helper = Helper(width: initialWidth, height: initialHeight, runDir: runDir)

let parentPid = getppid()
if parentPid == 1 { helper.shutdown(0) }
let parentWatch = DispatchSource.makeProcessSource(identifier: parentPid, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { helper.shutdown(0) }
parentWatch.resume()
// The parent can die between getppid() and the kqueue registration; that exit would never be delivered.
if getppid() != parentPid { helper.shutdown(0) }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
  signal(sig, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  source.setEventHandler { helper.shutdown(0) }
  source.resume()
  signalSources.append(source)
}

helper.start()
NSApplication.shared.run()
