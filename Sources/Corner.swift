// The corner: an approach dot that swells as the cursor nears the bottom-right corner, the timeline panel it
// opens, and the tick loop that drives both plus the banner. Ported from cornercal.lua.
import AppKit
import WebKit

private let PANEL_W: CGFloat = 376   // includes the 8px transparent shadow margin each side
private let CORNER: CGFloat = 4
private let GRACE = 0.35
private let DOT_RANGE = 230.0, POP_DIST = 3.0, REARM_DIST = 90.0
private let DOT_CANVAS: CGFloat = 220

// MARK: - Web view that takes the first click in a non-key panel

/// Reloads the panel if WebKit's content process dies (memory pressure, WebKit updates); otherwise it stays blank.
final class CrashReloader: NSObject, WKNavigationDelegate {
  let onCrash: () -> Void
  init(_ onCrash: @escaping () -> Void) { self.onCrash = onCrash }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onCrash() }
}

final class ClickWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func loadPage(_ name: String, replacing: [String: String] = [:]) -> String {
  func res(_ n: String) -> String {
    guard let u = Bundle.main.url(forResource: n, withExtension: nil), let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
    return s
  }
  var html = res(name).replacingOccurrences(of: "/*COMMON*/", with: res("common.js"))
  for (k, v) in replacing { html = html.replacingOccurrences(of: k, with: v) }
  // A string-loaded page can't reliably read files beside it, so images go in as data URIs.
  if html.contains("\"AppIcon.png\""), let u = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
     let d = try? Data(contentsOf: u) {
    html = html.replacingOccurrences(of: "\"AppIcon.png\"", with: "\"data:image/png;base64,\(d.base64EncodedString())\"")
  }
  return html
}

/// Bridges `webkit.messageHandlers.<name>.postMessage(...)` to a closure without a retain cycle.
final class ScriptBridge: NSObject, WKScriptMessageHandler {
  let handler: ([String: Any]) -> Void
  init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if let b = m.body as? [String: Any] { handler(b) }
  }
}

// MARK: - Approach dot

private final class DotView: NSView {
  var r: CGFloat = 0, alpha: CGFloat = 0, hex = "#a8c7fa"
  var ring: (radius: CGFloat, alpha: CGFloat)?
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext, r > 0.01 else { return }
    let c = CGPoint(x: bounds.midX, y: bounds.midY)
    let base = color(hex)
    ctx.setFillColor(base.withAlphaComponent(0.22 * alpha).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r * 2.1, y: c.y - r * 2.1, width: r * 4.2, height: r * 4.2))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 8, color: NSColor(white: 0, alpha: 0.45 * alpha).cgColor)
    ctx.setFillColor(base.withAlphaComponent(alpha).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    // Highlight toward the top-left, like the canvas radial gradient.
    let light = base.blended(withFraction: 0.45, of: .white) ?? base
    if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [light.withAlphaComponent(alpha).cgColor, base.withAlphaComponent(alpha).cgColor] as CFArray,
                          locations: [0, 1]) {
      ctx.saveGState()
      ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
      ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - r * 0.45, y: c.y - r * 0.45), startRadius: 0,
                             endCenter: c, endRadius: r * 1.2, options: [.drawsAfterEndLocation])
      ctx.restoreGState()
    }
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85 * alpha).cgColor); ctx.setLineWidth(1)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    if let ring, ring.radius > 0.1 {
      ctx.setStrokeColor(base.withAlphaComponent(ring.alpha).cgColor); ctx.setLineWidth(2)
      ctx.strokeEllipse(in: CGRect(x: c.x - ring.radius, y: c.y - ring.radius, width: 2 * ring.radius, height: 2 * ring.radius))
    }
  }
}

// MARK: - Controller

final class CornerController {
  let source: CalendarSource
  let sounds = Sounds()
  let banner = Banner()
  var openSettings: (() -> Void)?
  /// Test mode: the panel stays open wherever the pointer is.
  var pinned = false

  private let panel: NSPanel
  private let web: ClickWebView
  private var panelLoaded = false
  private var shown = false
  private var shownScreen: NSScreen?
  private var panelRect: CGRect = .zero
  private var hideGen = 0
  private var leftSince: Double?
  private var lastHover = CGPoint(x: -99, y: -99)
  private var reloader: CrashReloader?
  private var lastMouse = CGPoint(x: -1, y: -1)
  private var lastMoveT = 0.0

  private let dotWin: NSPanel
  private let dot = DotView()
  private var dotVisible = false, dotPos: CGPoint?
  private var dotR = 0.0, dotV = 0.0
  private var pop: (t0: Double, x: CGFloat, y: CGFloat, r: Double)?
  private var armed = true

  private var fast: Timer?
  private var poll: Timer?
  private var dataTimer: Timer?
  private var remindTimer: Timer?
  private var lastFetch = 0.0

  private var queue: [(kind: String, e: CalEvent, next: CalEvent?, at: Double)] = []
  private var busy = false
  private var fired = Set<String>()

  init(source: CalendarSource) {
    self.source = source
    panel = overlayPanel(size: NSSize(width: PANEL_W, height: 600), level: .statusBar)
    let config = WKWebViewConfiguration()
    web = ClickWebView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: 600), configuration: config)
    web.setValue(false, forKey: "drawsBackground")
    web.autoresizingMask = [.width, .height]
    panel.contentView = web

    dotWin = overlayPanel(size: NSSize(width: DOT_CANVAS, height: DOT_CANVAS), level: .popUpMenu)
    dotWin.ignoresMouseEvents = true
    dot.frame = NSRect(x: 0, y: 0, width: DOT_CANVAS, height: DOT_CANVAS)
    dotWin.contentView = dot

    config.userContentController.add(ScriptBridge { [weak self] b in
      guard let self else { return }
      switch b["type"] as? String {
      case "settings": self.hide(); self.openSettings?()
      case "refresh": self.source.refresh()
      case "loaded": self.panelLoaded = true; self.push()
      default: break
      }
    }, name: "cornercalPanel")
    web.loadHTMLString(loadPage("panel.html"), baseURL: Bundle.main.resourceURL)
    reloader = CrashReloader { [weak self] in
      guard let self else { return }
      self.panelLoaded = false
      self.web.loadHTMLString(loadPage("panel.html"), baseURL: Bundle.main.resourceURL)
    }
    web.navigationDelegate = reloader

    source.onChange = { [weak self] in
      guard let self else { return }
      self.lastFetch = Date().timeIntervalSince1970
      self.push()
      self.banner.update(self.source.events)
    }
  }

  func start() {
    poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self else { return }
      if self.fast == nil { self.tick() }
    }
    dataTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.source.refresh() }
    remindTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.checkReminders()
      self.banner.update(self.source.events)
    }
    poll?.tolerance = 0.01
    dataTimer?.tolerance = 10
    remindTimer?.tolerance = 1
    for t in [poll, dataTimer, remindTimer] { if let t { RunLoop.main.add(t, forMode: .common) } }
    // New day, wake from sleep, display changes: refetch and redraw.
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.source.refresh() }
    NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.source.refresh() }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      if self.shown { self.hide() }
      self.banner.update(self.source.events)
    }
    source.refresh()
  }

  private func push() {
    guard panelLoaded else { return }
    web.evaluateJavaScript("setData(\(source.json()))", completionHandler: nil)
  }

  // MARK: panel

  func show(on screen: NSScreen) {
    let vf = topLeft(screen.visibleFrame)
    let h = min((vf.height * 0.62).rounded(.down), 900)
    panelRect = CGRect(x: vf.maxX - PANEL_W - 2, y: vf.maxY - h - 2, width: PANEL_W, height: h)
    sounds.play("open", 0.8)
    shown = true; shownScreen = screen; leftSince = nil
    hideGen += 1
    if Date().timeIntervalSince1970 - lastFetch > 120 { source.refresh() }
    panel.setFrame(cocoaRect(panelRect), display: false)
    panel.orderFrontRegardless()
    web.evaluateJavaScript("openPanel()", completionHandler: nil)
  }

  func hide() {
    guard shown else { return }
    shown = false; leftSince = nil
    hideGen += 1
    let gen = hideGen
    web.evaluateJavaScript("closePanel(); hoverAt(-1,-1)", completionHandler: nil)
    lastHover = CGPoint(x: -99, y: -99)
    sounds.play("close", 0.5)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      guard let self, !self.shown, gen == self.hideGen else { return }
      self.panel.orderOut(nil)
      self.nextReminder()
    }
  }

  var isShown: Bool { shown }

  // MARK: tick

  private func nearestCorner(_ p: CGPoint) -> (CGPoint?, Double, NSScreen?) {
    for s in NSScreen.screens {
      let f = topLeft(s.frame)
      if p.x >= f.minX && p.x <= f.maxX && p.y >= f.minY && p.y <= f.maxY {
        let dx = Double(f.maxX - p.x), dy = Double(f.maxY - p.y)
        return (CGPoint(x: f.maxX, y: f.maxY), (dx * dx + dy * dy).squareRoot(), s)
      }
    }
    return (nil, .infinity, nil)
  }

  private func inCorner(_ p: CGPoint) -> Bool {
    NSScreen.screens.contains { s in
      let f = topLeft(s.frame)
      return p.x >= f.maxX - CORNER && p.x <= f.maxX && p.y >= f.maxY - CORNER && p.y <= f.maxY
    }
  }

  private func tick() {
    let p = mouseTL()
    let now = Date().timeIntervalSince1970
    let (c, d, screen) = nearestCorner(p)
    if p != lastMouse { lastMouse = p; lastMoveT = now }
    // Resting pointer: nothing to animate once the springs settle, so drop back to the slow poll.
    let recentlyMoved = now - lastMoveT < 0.5

    if !shown && d > REARM_DIST { armed = true }
    var touching = false
    if dotVisible, let dp = dotPos {
      let dist = hypot(Double(p.x - dp.x), Double(p.y - dp.y))
      touching = dist <= max(5, dotR * 0.75)
    }
    if !shown && armed, let screen, let c, touching || d <= POP_DIST {
      armed = false
      pop = (now, c.x, c.y, dotR > 1 ? dotR : 10)
      show(on: screen)
    }

    var wantFast = animateDot(p, c, d, now)
    banner.setBlocked(shown || pop != nil)
    if banner.tick(p, now, pointerMoving: recentlyMoved) { wantFast = true }
    if wantFast && fast == nil {
      let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(t, forMode: .common)
      fast = t
    } else if !wantFast, let f = fast {
      f.invalidate(); fast = nil
    }

    guard shown else { return }
    // Hover: WebKit gets no mouse-moved events in a non-key panel, so hand it the cursor.
    if panelLoaded {
      let h = CGPoint(x: (p.x - panelRect.minX).rounded(.down), y: (p.y - panelRect.minY).rounded(.down))
      if h != lastHover {
        lastHover = h
        web.evaluateJavaScript("hoverAt(\(Int(h.x)),\(Int(h.y)))", completionHandler: nil)
      }
    }
    // Keep open over the panel and the strip between it and the corner (Dock gap).
    let f = topLeft(shownScreen?.frame ?? .zero)
    let inKeep = p.x >= panelRect.minX && p.x <= f.maxX && p.y >= panelRect.minY - 16 && p.y <= f.maxY
    if inKeep || inCorner(p) || pinned {
      leftSince = nil
    } else {
      leftSince = leftSince ?? now
      if now - leftSince! >= GRACE { hide() }
    }
  }

  private func currentHex() -> String {
    let now = nowMs()
    if let e = source.events.first(where: { !$0.allDay && $0.start <= now && now < $0.end }) { return modern(e.color) }
    return "#a8c7fa"
  }

  private func drawDot(_ x: CGFloat, _ y: CGFloat, r: Double, alpha: Double, ring: (CGFloat, CGFloat)? = nil) {
    let half = DOT_CANVAS / 2
    dotWin.setFrameOrigin(cocoaRect(CGRect(x: x - half, y: y - half, width: DOT_CANVAS, height: DOT_CANVAS)).origin)
    dot.r = CGFloat(max(0.01, r)); dot.alpha = CGFloat(alpha)
    dot.ring = ring.map { (radius: $0.0, alpha: $0.1) }
    dot.needsDisplay = true
    if !dotVisible { dotWin.orderFrontRegardless(); dotVisible = true }
  }

  private func hideDot() {
    if dotVisible { dotWin.orderOut(nil); dotVisible = false }
    dotPos = nil
  }

  /// Returns true while the dot still needs 60 fps frames.
  private func animateDot(_ p: CGPoint, _ c: CGPoint?, _ d: Double, _ now: Double) -> Bool {
    if let pp = pop {
      sounds.hum(0)
      // Burst: the droplet swells and fades while a ripple ring spreads out.
      let t = (now - pp.t0) / 0.45
      if t >= 1 { pop = nil; dotR = 0; dotV = 0; hideDot(); return false }
      let e = 1 - pow(1 - t, 3)
      drawDot(pp.x, pp.y, r: pp.r * (1 + 0.5 * e), alpha: pow(1 - t, 1.5), ring: (CGFloat(pp.r + 70 * e), CGFloat(0.7 * (1 - t))))
      return true
    }
    if shown { sounds.hum(0); dotR = 0; dotV = 0; hideDot(); return false }

    var e = 0.0
    if c != nil && d <= DOT_RANGE {
      let t = 1 - d / DOT_RANGE
      e = t * t * (3 - 2 * t)
    }
    let target = e > 0 ? 3 + 17 * e : 0
    // Liquid size: an underdamped spring chases the target radius, so it swells and settles.
    dotV = (dotV + (target - dotR) * 0.16) * 0.74
    dotR += dotV
    sounds.hum(e)
    if let c, e > 0 {
      if !dotVisible { dot.hex = currentHex() }
      dotPos = c
    }
    guard let dp = dotPos else { dotR = 0; dotV = 0; return false }
    if target == 0 && dotR < 0.4 && abs(dotV) < 0.05 { dotR = 0; dotV = 0; hideDot(); return false }
    let settled = abs(target - dotR) < 0.05 && abs(dotV) < 0.02
    if settled && dotVisible && now - lastMoveT >= 0.5 { return false }
    drawDot(dp.x, dp.y, r: dotR, alpha: 0.3 + 0.7 * min(1, max(0, dotR) / 20))
    return true
  }

  // MARK: reminders — when a block starts, and 5 min before a block of 15+ min ends

  private func checkReminders() {
    guard Prefs.reminders else { return }
    let now = nowMs()
    let timed = source.events.filter { !$0.allDay }
    for e in timed {
      let key = "\(e.title)|\(e.start)"
      // Wide windows (the fired set stops repeats): a throttled or sleeping Mac can miss a 90 s window.
      if now >= e.start && now < e.start + 5 * 60_000 {
        if fired.insert("s" + key).inserted { enqueue("start", e, nil) }
      } else if e.end - e.start >= 15 * 60_000 && now >= e.end - 300_000 && now < e.end {
        if fired.insert("e" + key).inserted {
          let next = timed.filter { $0 != e && $0.start >= e.end - 60_000 && $0.start <= e.end + 30 * 60_000 }.min { $0.start < $1.start }
          enqueue("end", e, next)
        }
      }
    }
  }

  private func enqueue(_ kind: String, _ e: CalEvent, _ next: CalEvent?) {
    queue.append((kind, e, next, nowMs()))
    nextReminder()
  }

  private func nextReminder() {
    // Queued behind an open panel for a while: "STARTING NOW" minutes late is wrong, so drop stale ones.
    queue.removeAll { nowMs() - $0.at > 120_000 }
    guard !busy, !shown, !queue.isEmpty else { return }
    let r = queue.removeFirst()
    let snd = r.kind == "start" ? "start" : "warn"
    busy = true
    banner.update(source.events)
    let ok = banner.remind(kind: r.kind, event: r.e, next: r.next,
                           onDone: { [weak self] in self?.busy = false; self?.nextReminder() },
                           onNudge: { [weak self] in self?.sounds.alert(snd) })
    if ok { sounds.alert(snd) } else { busy = false }
  }

  /// Debug: the panel's web content as a PNG (only CornerCal's own window, never the screen).
  func snapshotPanel(to url: URL) {
    web.takeSnapshot(with: nil) { image, _ in
      guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
      try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
  }

  /// Settings / onboarding preview.
  func testReminder() {
    let now = nowMs()
    let e = CalEvent(title: "This is what a reminder looks like", start: now, end: now + 45 * 60_000, allDay: false, color: "#33b679", calendar: "")
    enqueue("start", e, nil)
  }
}
