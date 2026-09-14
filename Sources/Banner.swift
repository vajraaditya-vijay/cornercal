// The always-on pill in the bottom-right corner: the block you're in (progress as a fill) or free time.
// Ported from the Hammerspoon banner.lua (slot physics) + banner_canvas.lua (drawing).
// The window ignores the mouse, so clicks pass straight through to whatever is underneath.
import AppKit

private let PILL_W: CGFloat = 320, PILL_H: CGFloat = 46
private let MARGIN: CGFloat = 22     // transparent margin around the pill for its shadow
private let INSET: CGFloat = 10      // gap to the screen edges at rest
private let WALL: CGFloat = 4
private let EXT: CGFloat = 72        // extra height when a reminder expands the pill upward
private let ROOM: CGFloat = EXT + 10 // headroom above the pill (the open spring overshoots ~8%)
private let NEAR: Double = 200       // keep 60 fps frames while the cursor is this close

// MARK: - Slot physics
// The pill rests in one of two spots (home, and just above). A nearby cursor presses it (it dents); right on it,
// it gives way and flows to the other spot; once the cursor leaves home, it flows back. One underdamped spring.

private let SLOTS: [CGPoint] = [.zero, CGPoint(x: 0, y: -(PILL_H + 12))]
private let SLOT_K = 170.0, SLOT_DAMP = 15.0   // ζ ≈ 0.58: a little overshoot, settles in ~0.6 s
private let SLOT_R = 110.0, SLOT_PUSH = 1300.0
private let SNAP_D = 22.0
private let RETURN_D = 160.0, RETURN_DELAY = 0.35
private let SLOT_VMAX = 2600.0
private let ALPHA_FLOOR = 0.4, FADE_OUT_D = 8.0, FADE_IN_D = 40.0, FADE_OUT_RATE = 8.0, FADE_IN_RATE = 4.0

private struct Physics {
  var ox = 0.0, oy = 0.0, vx = 0.0, vy = 0.0
  var t = 0.0, slot = 0
  var snapT: Double?, awayT: Double?
}

private func rectDist(_ p: CGPoint, _ x: Double, _ y: Double) -> Double {
  let dx = clamp(Double(p.x), x, x + Double(PILL_W)) - Double(p.x)
  let dy = clamp(Double(p.y), y, y + Double(PILL_H)) - Double(p.y)
  return (dx * dx + dy * dy).squareRoot()
}

private func slotStep(_ st: inout Physics, _ p: CGPoint, _ home: CGPoint, _ box: CGRect, _ dt: Double) -> Double {
  st.t += dt
  let hx = Double(home.x), hy = Double(home.y)
  let x = hx + st.ox, y = hy + st.oy
  let d = rectDist(p, x, y)
  let s = SLOTS[st.slot]
  var ax = -SLOT_K * (st.ox - Double(s.x)) - SLOT_DAMP * st.vx
  var ay = -SLOT_K * (st.oy - Double(s.y)) - SLOT_DAMP * st.vy

  // Press: pushed away from the cursor, held by the stiff spring, so it dents rather than moves.
  if d < SLOT_R {
    var ux = (x + Double(PILL_W) / 2 - Double(p.x)) / Double(PILL_W / 2)
    var uy = (y + Double(PILL_H) / 2 - Double(p.y)) / Double(PILL_H / 2)
    var l = (ux * ux + uy * uy).squareRoot()
    if l < 1e-6 { ux = 0; uy = -1; l = 1 }
    let f = SLOT_PUSH * pow(1 - d / SLOT_R, 2)
    ax += ux / l * f; ay += uy / l * f
  }

  // Give way to the on-screen slot farthest from the cursor, never one the cursor is already near (it would flick).
  if d < SNAP_D && st.t - (st.snapT ?? -1) > 0.4 {
    var best: Int?, bd = 0.0
    for (i, o) in SLOTS.enumerated() where i != st.slot {
      let sx = hx + Double(o.x), sy = hy + Double(o.y)
      if sx >= Double(box.minX) && sy >= Double(box.minY) && sx + Double(PILL_W) <= Double(box.maxX) && sy + Double(PILL_H) <= Double(box.maxY) {
        let di = rectDist(p, sx, sy)
        if di > SNAP_D + 10 && (best == nil || di > bd) { best = i; bd = di }
      }
    }
    if let b = best { st.slot = b; st.snapT = st.t; st.awayT = nil }
  }

  // Come home once the cursor has left the home spot.
  if st.slot != 0 {
    if rectDist(p, hx, hy) > RETURN_D {
      st.awayT = st.awayT ?? st.t
      if st.t - st.awayT! >= RETURN_DELAY { st.slot = 0; st.snapT = st.t; st.awayT = nil }
    } else {
      st.awayT = nil
    }
  }

  st.vx = clamp(st.vx + ax * dt, -SLOT_VMAX, SLOT_VMAX)
  st.vy = clamp(st.vy + ay * dt, -SLOT_VMAX, SLOT_VMAX)
  st.ox += st.vx * dt; st.oy += st.vy * dt
  let nx = clamp(hx + st.ox, Double(box.minX), Double(box.maxX - PILL_W))
  if nx != hx + st.ox { st.ox = nx - hx; st.vx = 0 }
  let ny = clamp(hy + st.oy, Double(box.minY), Double(box.maxY - PILL_H))
  if ny != hy + st.oy { st.oy = ny - hy; st.vy = 0 }
  return d
}

private func isMoving(_ st: Physics) -> Bool {
  let s = SLOTS[st.slot]
  return abs(st.ox - Double(s.x)) + abs(st.oy - Double(s.y)) > 0.3 || abs(st.vx) + abs(st.vy) > 2
}

/// Pressed: squashed on the cursor's side and bulging across. Travelling: stretched along the motion, thinner across.
/// Returns the top-left shift and size change of the pill.
private func shapeOf(_ st: Physics) -> (dx: Double, dy: Double, dw: Double, dh: Double) {
  let DENT_SQUASH = 0.9, BULGE = 0.5, TRAVEL_STRETCH = 0.004, THIN = 0.35, SHAPE_MAX = 8.0
  let s = SLOTS[st.slot]
  let ex = st.ox - Double(s.x), ey = st.oy - Double(s.y)
  var dx = 0.0, dy = 0.0, dw = 0.0, dh = 0.0
  let near = clamp01(1 - ((ex * ex + ey * ey).squareRoot() - 8) / 8)
  if near > 0 {
    let qx = clamp(abs(ex) * DENT_SQUASH * near, 0, SHAPE_MAX)
    let qy = clamp(abs(ey) * DENT_SQUASH * near, 0, SHAPE_MAX)
    if ex > 0 { dx += qx }
    dw -= qx
    if ey > 0 { dy += qy }
    dh -= qy
    dx -= qy * BULGE / 2; dw += qy * BULGE
    dy -= qx * BULGE / 2; dh += qx * BULGE
  }
  let lx = clamp(abs(st.vx) * TRAVEL_STRETCH, 0, SHAPE_MAX)
  let ly = clamp(abs(st.vy) * TRAVEL_STRETCH, 0, SHAPE_MAX)
  if st.vx < 0 { dx -= lx }
  dw += lx
  if st.vy < 0 { dy -= ly }
  dh += ly
  dx += ly * THIN / 2; dw -= ly * THIN
  dy += lx * THIN / 2; dh -= lx * THIN
  return (dx, dy, dw, dh)
}

// MARK: - Look

private struct Theme {
  let bg: NSColor, fg: NSColor, mut: NSColor, ring: NSColor, outer: NSColor, tag: NSColor, tagbg: NSColor
  static let dark = Theme(bg: color("#26272b"), fg: color("#ececec"), mut: color("#9aa0a6"),
                          ring: NSColor(white: 1, alpha: 0.16), outer: NSColor(white: 0, alpha: 0.55),
                          tag: color("#a8c7fa"), tagbg: color("#a8c7fa", 0.16))
  static let light = Theme(bg: color("#ffffff"), fg: color("#1f1f1f"), mut: color("#5f6368"),
                           ring: NSColor(white: 0, alpha: 0.10), outer: NSColor(white: 0, alpha: 0),
                           tag: color("#0b57d0"), tagbg: color("#0b57d0", 0.12))
}
private let FREE = "#a8c7fa"

private struct Look { let th: Theme; let c: String; let tc: String; let free: Bool }
private struct TitleAnim { let key: String; let free: Bool; let text: String; var t0: Double?; var out: Double? }
private struct Reminder {
  var t0: Double; var eyebrow: String; var title: String; var sub: String; var c: String
  var onDone: (() -> Void)?; var onNudge: (() -> Void)?
  var closeT: Double?; var fromExt: Double = 0; var nudged = -1
}

private func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: weight) }

private func styled(_ s: String, _ f: NSFont, _ c: NSColor, stroke: Bool = false, kern: CGFloat = 0) -> NSAttributedString {
  let p = NSMutableParagraphStyle()
  p.lineBreakMode = .byTruncatingTail
  var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c, .paragraphStyle: p]
  // Text on the fill is thickened with a 0.45px stroke; NSStrokeWidth is a % of the font size, negative = fill too.
  if stroke { a[.strokeWidth] = -(0.45 / f.pointSize * 100); a[.strokeColor] = c }
  if kern != 0 { a[.kern] = kern }
  return NSAttributedString(string: s, attributes: a)
}

// MARK: - Banner

final class Banner {
  var enabled = true
  var showFree = Prefs.showFree { didSet { sync() } }

  private let window: NSPanel
  private let content = FlippedView()
  private let canvas: BannerCanvas
  private var glass: NSView?

  private var tint: Double
  private var state: BannerState?
  private var override: (state: BannerState, until: Double)?
  private var look: Look?
  private var styleKey = ""
  private var up = false, blocked = false
  private var st = Physics()
  private var lastT: Double?
  private var fadeAlpha = 1.0, fadeTarget = 1.0
  private var showAnim: (dir: Int, t0: Double)?   // dir 1 = in, 0 = out
  private var titles: [TitleAnim] = []
  private var rem: Reminder?
  private var ext = 0.0
  private var lastSec = -1, lastShapeKey = ""
  private var shownAlpha = -1.0
  fileprivate var drawScale = 1.0, drawTy = 0.0

  init() {
    let size = NSSize(width: PILL_W + 2 * MARGIN, height: PILL_H + ROOM + 2 * MARGIN)
    window = overlayPanel(size: size, level: .statusBar)
    window.ignoresMouseEvents = true
    content.frame = NSRect(origin: .zero, size: size)
    canvas = BannerCanvas(frame: content.bounds)
    tint = 1
    canvas.banner = self
    window.contentView = content
    setGlass(Prefs.glass)
    content.addSubview(canvas)
  }

  /// Liquid glass under a translucent pill (macOS 26+), or a solid pill with shadows.
  func setGlass(_ on: Bool) {
    glass?.removeFromSuperview(); glass = nil
    if on, #available(macOS 26.0, *) {
      let g = NSGlassEffectView(frame: .zero)
      g.cornerRadius = PILL_H / 2
      g.style = .regular
      content.addSubview(g, positioned: .below, relativeTo: canvas.superview == nil ? nil : canvas)
      glass = g
      tint = Prefs.glassTint
    } else {
      tint = 1
    }
    lastShapeKey = ""; canvas.needsDisplay = true
  }

  func setTint(_ t: Double) {
    if glass != nil { tint = clamp01(t); canvas.needsDisplay = true }
  }

  private func geometry() -> (home: CGPoint, box: CGRect) {
    let f = topLeft(NSScreen.screens.first?.frame ?? .zero)
    return (CGPoint(x: f.maxX - INSET - PILL_W, y: f.maxY - INSET - PILL_H), f.insetBy(dx: WALL, dy: WALL))
  }

  private func shape() -> (dx: Double, dy: Double, dw: Double, dh: Double) {
    reduceMotion ? (0, 0, 0, 0) : shapeOf(st)
  }

  /// The pill's rectangle in canvas coordinates (before the show/hide pop transform).
  fileprivate func pillRect() -> CGRect {
    let s = shape()
    let row = MARGIN + ROOM
    return CGRect(x: MARGIN + s.dx, y: row - ext + s.dy, width: PILL_W + s.dw, height: PILL_H + ext + s.dh)
  }

  private func place(_ home: CGPoint) {
    let tl = CGRect(x: (home.x + st.ox - MARGIN).rounded(), y: (home.y + st.oy - MARGIN - ROOM).rounded(),
                    width: window.frame.width, height: window.frame.height)
    let o = cocoaRect(tl).origin
    if o != window.frame.origin { window.setFrameOrigin(o) }
  }

  private func placeGlass() {
    guard let g = glass else { return }
    var r = pillRect()
    if drawScale != 1 || drawTy != 0 {
      // Same pop transform the canvas draws with: scale about the pill's bottom-right corner.
      let ox = MARGIN + PILL_W, oy = MARGIN + ROOM + PILL_H
      r = CGRect(x: ox + (r.minX - ox) * drawScale, y: oy + drawTy + (r.minY - oy) * drawScale,
                 width: r.width * drawScale, height: r.height * drawScale)
    }
    if g.frame != r { g.frame = r }
  }

  // MARK: state

  func update(_ events: [CalEvent]) {
    if let o = override, Date().timeIntervalSince1970 > o.until { override = nil }
    state = override?.state ?? pickState(events, now: nowMs())
    if let s = state { apply(s) }
    sync()
  }

  func setBlocked(_ b: Bool) { if b != blocked { blocked = b; sync() } }

  /// Show a fake state for a few seconds (settings preview, onboarding).
  func test(_ s: BannerState, seconds: Double) {
    override = (s, Date().timeIntervalSince1970 + seconds)
    update([])
  }

  private func apply(_ s: BannerState) {
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let key = "\(s)\(dark)\(tint)"
    if key == styleKey { return }
    styleKey = key
    let c = mute(s.mode == .free ? FREE : modern(s.color))
    // Muted colours sit mid-brightness; take whichever text colour has more contrast.
    let lc = luminance(c)
    let ratio = { (a: Double, b: Double) in (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    let tc = ratio(lc, 1) >= ratio(lc, luminance("#1f1f1f")) ? "#ffffff" : "#1f1f1f"
    look = Look(th: dark ? .dark : .light, c: c, tc: tc, free: s.mode == .free)

    let free = s.mode == .free
    let text = free ? (s.nextTitle ?? "") : s.title
    let tkey = (free ? "F|" : "T|") + text
    let cur = titles.lastIndex { $0.out == nil }
    if cur == nil || titles[cur!].key != tkey {
      let now = Date().timeIntervalSince1970
      if let i = cur { titles[i].out = now }
      titles.append(TitleAnim(key: tkey, free: free, text: text, t0: cur == nil ? nil : now))
    }
    canvas.needsDisplay = true
  }

  private func sync() {
    let want = enabled && state != nil && !blocked && (state!.mode != .free || showFree || rem != nil)
    if want == up { return }
    up = want
    let now = Date().timeIntervalSince1970
    if want {
      st = Physics(); lastT = nil
      fadeAlpha = 1; fadeTarget = 1
      place(geometry().home)
      showAnim = (1, now)
      visual(now)
      canvas.needsDisplay = true
      window.orderFrontRegardless()
    } else {
      showAnim = (0, now)
      if rem != nil { finishRemind() }   // the panel opened over it: the reminder is done
    }
  }

  var isUp: Bool { up }

  // MARK: frame loop

  /// Called on every tick. Returns true while it needs 60 fps frames.
  func tick(_ p: CGPoint, _ now: Double, pointerMoving: Bool = true) -> Bool {
    if !up {
      lastT = nil
      if showAnim != nil { visual(now); return showAnim != nil }
      return false
    }
    let (home, box) = geometry()
    let dt = lastT.map { min(now - $0, 0.1) } ?? 0
    var d: Double
    if reduceMotion {
      d = rectDist(p, Double(home.x), Double(home.y))
      st = Physics()
    } else {
      let n = max(1, Int((dt * 120).rounded(.up)))
      d = 0
      for i in 0..<n {
        let di = slotStep(&st, p, home, box, dt / Double(n))
        if i == 0 { d = di }
      }
    }
    place(home)
    lastT = now

    if d < FADE_OUT_D { fadeTarget = ALPHA_FLOOR } else if d > FADE_IN_D { fadeTarget = 1 }
    let rate = fadeTarget < fadeAlpha ? FADE_OUT_RATE : FADE_IN_RATE
    fadeAlpha += (fadeTarget - fadeAlpha) * min(1, rate * dt)
    if abs(fadeTarget - fadeAlpha) < 0.005 { fadeAlpha = fadeTarget }

    let remAnim = remindStep(now, d)
    let s = shape()
    let sk = String(format: "%.1f %.1f %.1f %.1f %.1f", s.dx, s.dy, s.dw, s.dh, ext)
    let reshaped = sk != lastShapeKey
    if reshaped { lastShapeKey = sk }
    let anim = titlesAnimating(now) || remAnim
    let sec = Int(now)
    if reshaped || anim || sec != lastSec { canvas.needsDisplay = true; lastSec = sec }
    visual(now)
    placeGlass()
    return isMoving(st) || (d < NEAR && pointerMoving) || fadeAlpha != fadeTarget || anim
  }

  private func titlesAnimating(_ now: Double) -> Bool {
    if showAnim != nil { return true }
    return titles.contains { $0.out != nil || ($0.t0 != nil && now - $0.t0! < 0.6) }
  }

  /// Opacity plus the show/hide pop (scale from the bottom-right corner).
  private func visual(_ now: Double) {
    var a = 1.0, ty = 0.0, s = 1.0
    if let sa = showAnim {
      let k = now - sa.t0
      if sa.dir == 1 {
        a = clamp01(k / 0.2)
        if !reduceMotion { let e = liquid(k / 0.8); ty = 10 * (1 - e); s = 0.92 + 0.08 * e }
        if k >= 0.8 { showAnim = nil }
      } else {
        a = 1 - easeIn(k / 0.18)
        if !reduceMotion { let e = easeIn(k / 0.2); ty = 10 * e; s = 1 - 0.08 * e }
        if k >= 0.22 { showAnim = nil; window.orderOut(nil); a = 0 }
      }
    }
    a *= fadeAlpha
    if abs(a - shownAlpha) >= 0.005 { window.alphaValue = CGFloat(a); shownAlpha = a }
    if s != drawScale || ty != drawTy { drawScale = s; drawTy = ty; canvas.needsDisplay = true; placeGlass() }
  }

  // MARK: reminders
  // The pill grows upward into the reminder. It stays until the cursor comes within ACK_D (he's seen it)
  // or MAX_HOLD, and nudges every NUDGE_EVERY s with a hop and the chime again.

  private let OPEN = 0.7, CLOSE = 0.3, MAX_HOLD = 60.0, ACK_D = 60.0, NUDGE_EVERY = 15.0, NUDGES = 3, HOP = 520.0

  /// kind "start" or "end". Returns false if the banner can't take it right now.
  func remind(kind: String, event e: CalEvent, next: CalEvent?, onDone: @escaping () -> Void, onNudge: @escaping () -> Void) -> Bool {
    if blocked || !enabled { return false }
    var sub = kind == "start" ? rangeText(e.start, e.end) + " · " + durText(e.end - e.start) : "Ends at " + hmText(e.end)
    if let n = next { sub += " · next: " + n.title }
    rem = Reminder(t0: Date().timeIntervalSince1970, eyebrow: kind == "start" ? "STARTING NOW" : "5 MIN LEFT",
                   title: e.title, sub: sub, c: mute(modern(e.color)), onDone: onDone, onNudge: onNudge)
    if state == nil { update([]) }
    sync()
    if !up { rem = nil; return false }
    canvas.needsDisplay = true
    return true
  }

  private func finishRemind() {
    let done = rem?.onDone
    rem = nil; ext = 0
    canvas.needsDisplay = true
    placeGlass()
    done?()
    sync()   // free time with "show free time" off: the pill only came up for the reminder
  }

  private func remindStep(_ now: Double, _ d: Double) -> Bool {
    guard var r = rem else { return false }
    let k = now - r.t0
    if r.closeT == nil {
      if (k > OPEN + 0.3 && d < ACK_D) || k >= MAX_HOLD {
        r.closeT = now; r.fromExt = ext
      } else {
        let n = Int(k / NUDGE_EVERY)
        if n != r.nudged && n <= NUDGES {
          r.nudged = n
          if !reduceMotion { st.vy -= HOP }        // the spring turns this into a hop with a little wobble
          if n > 0 { r.onNudge?() }                // the first chime is played by the caller
        }
      }
    }
    rem = r
    if let c0 = r.closeT {
      let c = (now - c0) / (reduceMotion ? 0.2 : CLOSE)
      if c >= 1 { finishRemind(); return true }
      ext = r.fromExt * (1 - (reduceMotion ? c : easeIn(c)))
    } else {
      ext = Double(EXT) * (reduceMotion ? clamp01(k / 0.2) : liquid(k / OPEN))
    }
    return r.closeT != nil || k < OPEN + 0.05
  }

  // MARK: drawing

  fileprivate func draw(_ ctx: CGContext) {
    guard let state, let look else { return }
    let now = Date().timeIntervalSince1970
    titles.removeAll { $0.out != nil && now - $0.out! > 0.7 }

    if drawScale != 1 || drawTy != 0 {
      let ox = MARGIN + PILL_W, oy = MARGIN + ROOM + PILL_H
      ctx.translateBy(x: ox, y: oy + drawTy)
      ctx.scaleBy(x: drawScale, y: drawScale)
      ctx.translateBy(x: -ox, y: -oy)
    }

    let ROW = MARGIN + ROOM
    let pill = pillRect()
    let radius = PILL_H / 2
    let th = look.th
    let nowMs = now * 1000
    var p = 0.0
    var remain: Double?
    if state.mode == .free {
      if let to = state.nextStart {
        p = (nowMs - state.start) / max(1, to - state.start); remain = to - nowMs
      }
    } else {
      p = (nowMs - state.start) / max(1, state.end - state.start); remain = state.end - nowMs
    }
    let fillW = CGFloat(clamp01(p)) * pill.width

    func leftText(_ onFill: Bool) -> NSAttributedString? {
      guard let remain else { return nil }
      let b = styled(durText(remain), font(13, .semibold), color(onFill ? look.tc : "#000000"), stroke: onFill)
      let bold = onFill ? b : styled(durText(remain), font(13, .semibold), th.fg)
      let r = styled(state.mode == .free ? "in " : " left", font(12, .regular), onFill ? color(look.tc) : th.mut)
      let out = NSMutableAttributedString()
      if state.mode == .free { out.append(r); out.append(bold) } else { out.append(bold); out.append(r) }
      return out
    }
    let leftN = leftText(false)
    let leftSz = leftN?.size() ?? .zero
    let leftX = MARGIN + PILL_W - 16 - leftSz.width
    let textX = MARGIN + 15 + 8 + 10
    let titleW = (leftN != nil ? leftX - 10 : MARGIN + PILL_W - 16) - textX
    let path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Pill body. Over glass it's a translucent tint with no shadow (a shadow shows through the tint as a smear).
    ctx.saveGState()
    if glass == nil {
      ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 12, color: NSColor(white: 0, alpha: 0.3).cgColor)
      ctx.addPath(path); ctx.setFillColor(th.bg.cgColor); ctx.fillPath()
      ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.16).cgColor)
      ctx.addPath(path); ctx.fillPath()
    } else {
      ctx.addPath(path); ctx.setFillColor(th.bg.withAlphaComponent(CGFloat(tint)).cgColor); ctx.fillPath()
    }
    ctx.restoreGState()
    let outer = pill.insetBy(dx: -0.5, dy: -0.5)
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil))
    ctx.setStrokeColor(th.outer.cgColor); ctx.setLineWidth(1); ctx.strokePath()

    // Progress fill.
    if fillW > 0 {
      ctx.saveGState()
      ctx.addPath(path); ctx.clip()
      ctx.setFillColor(color(look.c).cgColor)
      ctx.fill(CGRect(x: pill.minX, y: pill.minY, width: fillW, height: pill.height))
      ctx.restoreGState()
    }

    func layer(_ onFill: Bool) {
      let ink = color(onFill ? look.tc : look.c)
      let center = CGPoint(x: MARGIN + 19, y: ROW + PILL_H / 2)
      if look.free {
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
      } else {
        ctx.setFillColor(ink.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
      }
      if let l = onFill ? leftText(true) : leftN {
        l.draw(in: CGRect(x: leftX, y: ROW + (PILL_H - leftSz.height) / 2, width: leftSz.width + 4, height: leftSz.height + 2))
      }
      for t in titles {
        let (a, oy) = titleAnim(t, now)
        guard a > 0.01 else { continue }
        let y = ROW + 13 + CGFloat(oy)
        var x = textX, w = titleW
        if t.free {
          let tag = styled("Free", font(11.5, .semibold), onFill ? color(look.tc, CGFloat(a)) : th.tag.withAlphaComponent(CGFloat(a)), kern: 0.23)
          let ts = tag.size()
          let tagW = ts.width + 14
          ctx.setFillColor((onFill ? color(look.tc, CGFloat(0.14 * a)) : th.tagbg.withAlphaComponent(th.tagbg.alphaComponent * CGFloat(a))).cgColor)
          ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y + 1.5, width: tagW, height: 17), cornerWidth: 8.5, cornerHeight: 8.5, transform: nil))
          ctx.fillPath()
          tag.draw(at: CGPoint(x: x + 7, y: y + 1.5 + (17 - ts.height) / 2))
          x += tagW + 5; w -= tagW + 5
        }
        if w > 4 && !t.text.isEmpty {
          let s = styled(t.text, font(13.5, .medium), onFill ? color(look.tc, CGFloat(a)) : th.fg.withAlphaComponent(CGFloat(a)), stroke: onFill)
          let h = s.size().height
          s.draw(in: CGRect(x: x, y: y + (20 - h) / 2, width: w, height: h + 2))
        }
      }
      // The reminder sits at its final place and the growing pill edge (the clip) reveals it.
      if let r = rem, ext > 0.5 {
        let a = CGFloat(clamp01(ext / Double(EXT)))
        let top = ROW - EXT
        let mut = onFill ? color(look.tc, a) : th.mut.withAlphaComponent(a)
        let fg = onFill ? color(look.tc, a) : th.fg.withAlphaComponent(a)
        let w = MARGIN + PILL_W - 18 - textX
        ctx.setFillColor((onFill ? color(look.tc, a) : color(r.c, a)).cgColor)
        ctx.fillEllipse(in: CGRect(x: MARGIN + 19 - 3.5, y: top + 20 - 3.5, width: 7, height: 7))
        let eb = styled(r.eyebrow, font(10.5, .bold), mut, kern: 0.8)
        eb.draw(in: CGRect(x: textX, y: top + 20 - eb.size().height / 2, width: w, height: eb.size().height + 2))
        let tt = styled(r.title, font(14.5, .semibold), fg, stroke: onFill)
        tt.draw(in: CGRect(x: textX, y: top + 29, width: w, height: tt.size().height + 2))
        let sb = styled(r.sub, font(12, .regular), mut)
        sb.draw(in: CGRect(x: textX, y: top + 49, width: w, height: sb.size().height + 2))
        ctx.setFillColor((onFill ? color(look.tc, 0.25 * a) : th.ring.withAlphaComponent(th.ring.alphaComponent * a)).cgColor)
        ctx.fill(CGRect(x: MARGIN + 16, y: ROW - 0.5, width: PILL_W - 32, height: 1))
      }
    }

    // Content twice: normal colours right of the fill edge, fill-readable colours left of it,
    // so each letter flips colour as the fill passes it.
    if fillW < pill.width {
      ctx.saveGState()
      ctx.addPath(path); ctx.clip()
      ctx.clip(to: CGRect(x: pill.minX + fillW, y: pill.minY, width: pill.width - fillW, height: pill.height))
      layer(false)
      ctx.restoreGState()
    }
    if fillW > 0 {
      ctx.saveGState()
      ctx.addPath(path); ctx.clip()
      ctx.clip(to: CGRect(x: pill.minX, y: pill.minY, width: fillW, height: pill.height))
      layer(true)
      ctx.restoreGState()
    }
    // Light hairline inside, on top of everything.
    let inner = pill.insetBy(dx: 0.5, dy: 0.5)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
    ctx.setStrokeColor(th.ring.cgColor); ctx.setLineWidth(1); ctx.strokePath()
  }

  private func titleAnim(_ t: TitleAnim, _ now: Double) -> (Double, Double) {
    if reduceMotion {
      if let o = t.out { return (1 - clamp01((now - o) / 0.2), 0) }
      if let s = t.t0 { return (clamp01((now - s) / 0.2), 0) }
      return (1, 0)
    }
    if let o = t.out { let k = now - o; return (1 - easeOut(k / 0.25), -8 * liquid(k / 0.6)) }
    if let s = t.t0 { let k = now - s; return (easeOut(k / 0.25), 8 * (1 - liquid(k / 0.6))) }
    return (1, 0)
  }

  /// Debug: the banner as a PNG (without the glass, which only the window server can draw).
  func snapshot(to url: URL) {
    guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }

  var debugInfo: String {
    "up=\(up) blocked=\(blocked) slot=\(st.slot) off=(\(Int(st.ox)),\(Int(st.oy))) alpha=\(String(format: "%.2f", fadeAlpha)) rem=\(rem != nil) ext=\(Int(ext)) state=\(String(describing: state?.mode)) title=\(state?.title ?? "")"
  }
}

private final class BannerCanvas: NSView {
  weak var banner: Banner?
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    banner?.draw(ctx)
  }
}
