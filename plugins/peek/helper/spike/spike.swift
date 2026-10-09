import AppKit
import CryptoKit
import WebKit

// Throwaway U1 spike: measures hidden-window rendering, input targeting and frame cost.

let animatedPage = """
<html><body style="margin:0;font:20px sans-serif">
<div id=box style="width:80px;height:80px;background:#d79921;animation:spin 1s linear infinite"></div>
<div id=n>0</div>
<button id=b onclick="document.getElementById('clicks').textContent=String(++window.c)" style="position:absolute;left:100px;top:200px;width:200px;height:60px">click</button>
<div id=clicks>0</div>
<input id=i style="position:absolute;left:100px;top:300px;width:300px;height:40px">
<style>@keyframes spin{to{transform:rotate(360deg)}}</style>
<script>window.c=0;let k=0;setInterval(()=>{document.getElementById('n').textContent=String(++k)},100)</script>
</body></html>
"""

final class Spike: NSObject, WKNavigationDelegate {
  let width: CGFloat = 1200
  let height: CGFloat = 800
  var window: NSWindow!
  var web: WKWebView!
  var loaded: (() -> Void)?

  func make(offscreen: Bool) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let origin = offscreen ? NSPoint(x: -20000, y: -20000) : NSPoint(x: 0, y: 0)
    window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                      styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.alphaValue = offscreen ? 1 : 0.01
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
    web.navigationDelegate = self
    if CommandLine.arguments.contains("--no-occlusion") {
      let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
      if web.responds(to: sel) { web.perform(sel, with: NSNumber(value: false)); print("occlusion detection disabled") } else { print("occlusion selector missing") }
    }
    window.contentView = web
    window.orderBack(nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(); loaded = nil }

  func load(html: String? = nil, url: String? = nil, then: @escaping () -> Void) {
    loaded = then
    if let html { web.loadHTMLString(html, baseURL: nil) } else if let url { web.load(URLRequest(url: URL(string: url)!)) }
  }

  func snap(_ done: @escaping (NSImage?, Double) -> Void) {
    let start = CFAbsoluteTimeGetCurrent()
    let cfg = WKSnapshotConfiguration()
    cfg.afterScreenUpdates = true
    web.takeSnapshot(with: cfg) { image, _ in done(image, (CFAbsoluteTimeGetCurrent() - start) * 1000) }
  }
}

func digest(_ image: NSImage?) -> String {
  guard let tiff = image?.tiffRepresentation else { return "nil" }
  return SHA256.hash(data: tiff).prefix(6).map { String(format: "%02x", $0) }.joined()
}

func png(_ image: NSImage?, scale: CGFloat = 1) -> (Int, Double) {
  guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (0, 0) }
  let start = CFAbsoluteTimeGetCurrent()
  let rep = NSBitmapImageRep(cgImage: cg)
  let data = rep.representation(using: .png, properties: [:]) ?? Data()
  return (data.count, (CFAbsoluteTimeGetCurrent() - start) * 1000)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
  let sorted = values.sorted()
  return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mode = CommandLine.arguments.dropFirst().first ?? "behind"
let useActivity = CommandLine.arguments.contains("--activity")
var activity: NSObjectProtocol?
if useActivity { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "live view") }

let spike = Spike()
let launch = CFAbsoluteTimeGetCurrent()
spike.make(offscreen: mode == "offscreen")
let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

func runLoop(count: Int, gapMs: Double, _ done: @escaping ([Double], Int) -> Void) {
  var times: [Double] = []
  var hashes = Set<String>()
  func step(_ i: Int) {
    if i == count { done(times, hashes.count); return }
    spike.snap { image, ms in
      times.append(ms); hashes.insert(digest(image))
      DispatchQueue.main.asyncAfter(deadline: .now() + gapMs / 1000) { step(i + 1) }
    }
  }
  step(0)
}

spike.load(html: animatedPage) {
  print("mode=\(mode) activity=\(useActivity) firstLoadMs=\(Int((CFAbsoluteTimeGetCurrent() - launch) * 1000)) occlusionVisible=\(spike.window.occlusionState.contains(.visible))")
  runLoop(count: 60, gapMs: 33) { times, distinct in
    print("animated: snapshots=60 p50=\(Int(percentile(times, 0.5)))ms p95=\(Int(percentile(times, 0.95)))ms distinctFrames=\(distinct)")
    // Click the button and type into the field, delivered only to our own window.
    let window = spike.window!
    let point = NSPoint(x: 200, y: spike.height - 230)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(e)
      }
    }
    spike.web.evaluateJavaScript("document.getElementById('i').focus()") { _, _ in
      spike.web.insertText("webkit")
      for ch in "!" {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                                    isARepeat: false, keyCode: 0) { window.sendEvent(e) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        spike.web.evaluateJavaScript("[document.getElementById('clicks').textContent, document.getElementById('i').value].join('|')") { result, _ in
          let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
          print("input: clicks|value=\(result ?? "nil") isKey=\(window.isKeyWindow) frontBefore=\(frontBefore) frontAfter=\(frontAfter)")
          let realUrl = CommandLine.arguments.first { $0.hasPrefix("http") } ?? "https://news.ycombinator.com"
          let navStart = CFAbsoluteTimeGetCurrent()
          spike.load(url: realUrl) {
            spike.snap { image, _ in
              print("real: url=\(realUrl) loadToFirstFrameMs=\(Int((CFAbsoluteTimeGetCurrent() - navStart) * 1000))")
              let (size1, enc1) = png(image)
              print("png 1x: bytes=\(size1) encodeMs=\(Int(enc1))")
              runLoop(count: 30, gapMs: 0) { times, _ in
                print("real: back-to-back snapshots p50=\(Int(percentile(times, 0.5)))ms p95=\(Int(percentile(times, 0.95)))ms")
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                exit(0)
              }
            }
          }
        }
      }
    }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
