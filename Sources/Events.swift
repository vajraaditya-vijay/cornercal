// Calendar data: EventKit (the macOS Calendar database), so every account the user added to
// Calendar.app shows up with one permission prompt. Same approach as Calendr, Itsycal and MeetingBar.
import AppKit
import EventKit

struct CalEvent: Codable, Equatable {
  var title: String
  var start: Double      // ms since epoch, like the JS Date the panel uses
  var end: Double
  var allDay: Bool
  var color: String      // "#rrggbb", sRGB
  var calendar: String
}

enum Access: String { case granted, undetermined, denied, restricted, writeOnly }

final class CalendarSource {
  private(set) var store = EKEventStore()
  private(set) var events: [CalEvent] = []
  private(set) var updated: Double = 0
  private(set) var error: String?
  let demo: Bool
  var onChange: (() -> Void)?
  private var fetching = false
  private var again = false
  private var observer: NSObjectProtocol?
  private var lastAccess: Access?

  init(demo: Bool) {
    self.demo = demo
    observe()
  }

  private func observe() {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    // Fires when Calendar.app syncs, or the user edits an event anywhere.
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
      self?.refresh()
    }
  }

  static var access: Access {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return .granted
    case .notDetermined: return .undetermined
    case .denied: return .denied
    case .restricted: return .restricted
    case .writeOnly: return .writeOnly
    @unknown default: return .granted
    }
  }

  func requestAccess(_ done: @escaping (Access) -> Void) {
    if demo { done(.granted); return }
    store.requestFullAccessToEvents { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        // A store created before access was granted can keep returning nothing; start fresh.
        if CalendarSource.access == .granted { self.store = EKEventStore(); self.observe() }
        self.refresh()
        done(CalendarSource.access)
      }
    }
  }

  func refresh() {
    if demo {
      events = CalendarSource.demoEvents()
      updated = nowMs(); error = nil
      onChange?()
      return
    }
    let acc = CalendarSource.access
    // Access switched on in System Settings while running: a store made before that can keep returning nothing.
    if acc == .granted, let last = lastAccess, last != .granted { store = EKEventStore(); observe() }
    lastAccess = acc
    guard acc == .granted else {
      events = []; error = "noaccess"; updated = nowMs()
      onChange?()
      return
    }
    if fetching { again = true; return }
    fetching = true
    let store = self.store
    DispatchQueue.global(qos: .userInitiated).async {
      let cal = Calendar.current
      let today = cal.startOfDay(for: Date())
      // Yesterday (shown when the panel is scrolled up), today and tomorrow.
      let from = cal.date(byAdding: .day, value: -1, to: today)!
      let to = cal.date(byAdding: .day, value: 2, to: today)!
      let hidden = Set(Prefs.hiddenCalendars)
      let cals = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
      // An empty calendars array would mean "all" to EventKit, so everything switched off has to be handled here.
      let found = cals.isEmpty ? [] : store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: cals))
      let list: [CalEvent] = found.compactMap { e in
        if e.status == .canceled { return nil }
        if e.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { return nil }
        let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalEvent(title: title.isEmpty ? "(no title)" : title,
                        start: e.startDate.timeIntervalSince1970 * 1000,
                        end: e.endDate.timeIntervalSince1970 * 1000,
                        allDay: e.isAllDay,
                        color: hexString(e.calendar?.cgColor),
                        calendar: e.calendar?.title ?? "")
      }.sorted { $0.start < $1.start }
      DispatchQueue.main.async {
        self.fetching = false
        self.events = list
        self.updated = nowMs(); self.error = nil
        self.onChange?()
        if self.again { self.again = false; self.refresh() }
      }
    }
  }

  /// Calendars for the Settings list, grouped by account (iCloud, Google, school…).
  func calendarList() -> [[String: Any]] {
    guard !demo, CalendarSource.access == .granted else { return [] }
    let hidden = Set(Prefs.hiddenCalendars)
    return store.calendars(for: .event)
      .map { c -> (String, EKCalendar) in (c.source?.title ?? "Other", c) }
      .sorted { ($0.0.lowercased(), $0.1.title.lowercased()) < ($1.0.lowercased(), $1.1.title.lowercased()) }
      .map { account, c in
        ["id": c.calendarIdentifier, "title": c.title, "color": hexString(c.cgColor), "account": account,
         "on": !hidden.contains(c.calendarIdentifier)]
      }
  }

  func setCalendar(_ id: String, on: Bool) {
    var hidden = Set(Prefs.hiddenCalendars)
    if on { hidden.remove(id) } else { hidden.insert(id) }
    Prefs.hiddenCalendars = Array(hidden)
    refresh()
  }

  /// JSON for panel.html's setData().
  func json() -> String {
    struct Payload: Codable { var updated: Double; var events: [CalEvent]; var error: String? }
    let data = try? JSONEncoder().encode(Payload(updated: updated, events: events, error: error))
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"events\":[]}"
  }

  /// A believable school day around the current time, for screenshots, the site and `--demo`.
  static func demoEvents() -> [CalEvent] {
    let now = Date()
    let cal = Calendar.current
    let m = 60_000.0
    // Snap to the quarter hour so the demo looks like real blocks.
    let q = floor(now.timeIntervalSince1970 * 1000 / (15 * m)) * 15 * m
    func ev(_ title: String, _ s: Double, _ len: Double, _ color: String, _ calName: String = "School") -> CalEvent {
      CalEvent(title: title, start: q + s * m, end: q + (s + len) * m, allDay: false, color: color, calendar: calName)
    }
    let today = cal.startOfDay(for: now).timeIntervalSince1970 * 1000
    return [
      CalEvent(title: "Exam week", start: today, end: today + 86_400_000, allDay: true, color: "#8e24aa", calendar: "School"),
      ev("Maths — sequences", -24 * 60 + 30, 60, "#039be5"),
      ev("Chemistry revision", -150, 60, "#f4511e"),
      ev("Lunch", -75, 45, "#616161", "Personal"),
      ev("Physics — lenses & dispersion", -30, 75, "#33b679"),
      ev("French — Unit 5 vocab", 60, 45, "#f6bf26"),
      ev("Gym", 135, 60, "#e67c73", "Personal"),
      ev("English letter draft", 210, 45, "#3f51b5"),
      ev("Biology past paper", 24 * 60 - 60, 90, "#0b8043"),
    ]
  }
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// MARK: - What the banner shows

struct BannerState: Equatable {
  enum Mode { case task, free }
  var mode: Mode
  var title = ""
  var start: Double = 0
  var end: Double = 0
  var color = "#4285f4"
  var nextTitle: String?
  var nextStart: Double?
}

/// The block you're in, or free time until the next one (ported from banner.lua B.pick).
func pickState(_ events: [CalEvent], now: Double) -> BannerState {
  var cur: CalEvent?, nxt: CalEvent?
  var prevEnd: Double?
  for e in events where !e.allDay {
    if e.start <= now && now < e.end {
      if cur == nil || e.start > cur!.start { cur = e }        // overlapping: the most recent start wins
    } else if e.end <= now {
      if prevEnd == nil || e.end > prevEnd! { prevEnd = e.end }
    } else if nxt == nil || e.start < nxt!.start {
      nxt = e
    }
  }
  if let c = cur {
    return BannerState(mode: .task, title: c.title, start: c.start, end: c.end, color: c.color)
  }
  // Free time fills from the end of the last block (or an hour before the next, first thing in the day).
  // Yesterday's blocks don't count: free time since last night would fill the pill all morning.
  let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
  let from = prevEnd.map { max($0, midnight) } ?? (nxt.map { $0.start - 3_600_000 } ?? 0)
  return BannerState(mode: .free, start: from, nextTitle: nxt?.title, nextStart: nxt?.start)
}

// MARK: - Colour helpers (ported from common.js / banner_canvas.lua)

func rgb(_ hex: String) -> (Double, Double, Double) {
  var s = hex.trimmingCharacters(in: .whitespaces)
  if s.hasPrefix("#") { s.removeFirst() }
  guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
  return (Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff))
}

func hexString(_ cg: CGColor?) -> String {
  guard let cg, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return "#4285f4" }
  let f = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
  return String(format: "#%02x%02x%02x", f(c.redComponent), f(c.greenComponent), f(c.blueComponent))
}

func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
  let (r, g, b) = rgb(hex)
  return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
}

private let MODERN = ["#d50000", "#e67c73", "#f4511e", "#f6bf26", "#33b679", "#0b8043",
                      "#039be5", "#3f51b5", "#7986cb", "#8e24aa", "#616161"]

/// Snap Google's legacy palette to the modern one, only when genuinely close.
func modern(_ hex: String) -> String {
  let (r, g, b) = rgb(hex)
  var best = hex, bd = 5000.0
  for p in MODERN {
    let (pr, pg, pb) = rgb(p)
    let d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
    if d < bd { bd = d; best = p }
  }
  return best
}

func luminance(_ hex: String) -> Double {
  let (r, g, b) = rgb(hex)
  let lin = { (v: Double) -> Double in let x = v / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

/// Keep MUTE of the colour's saturation: calendar colours at full strength were too loud for an always-on pill.
func mute(_ hex: String, _ k: Double = 0.58) -> String {
  let (R, G, B) = rgb(hex)
  let r = R / 255, g = G / 255, b = B / 255
  let mx = max(r, g, b), mn = min(r, g, b)
  if mx == mn { return hex }
  let l = (mx + mn) / 2, d = mx - mn
  let s = d / (1 - abs(2 * l - 1))
  var h: Double
  if mx == r { h = fmod((g - b) / d, 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
  h = fmod(h * 60 + 360, 360)
  let c = (1 - abs(2 * l - 1)) * s * k
  let x = c * (1 - abs(fmod(h / 60, 2) - 1))
  let m = l - c / 2
  let (a, bb, cc): (Double, Double, Double)
  switch h {
  case ..<60: (a, bb, cc) = (c, x, 0)
  case ..<120: (a, bb, cc) = (x, c, 0)
  case ..<180: (a, bb, cc) = (0, c, x)
  case ..<240: (a, bb, cc) = (0, x, c)
  case ..<300: (a, bb, cc) = (x, 0, c)
  default: (a, bb, cc) = (c, 0, x)
  }
  let hx = { (v: Double) in String(format: "%02x", Int(((v + m) * 255).rounded())) }
  return "#" + hx(a) + hx(bb) + hx(cc)
}

// MARK: - Time text (same wording as common.js)

func durText(_ ms: Double) -> String {
  let m = max(0, Int((ms / 60000).rounded()))
  return m >= 60 ? "\(m / 60)h" + (m % 60 > 0 ? " \(m % 60)m" : "") : "\(m)m"
}

func hmText(_ ms: Double, ampm: Bool = true) -> String {
  let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
  let h = c.hour ?? 0, mi = c.minute ?? 0
  let s = "\(h % 12 == 0 ? 12 : h % 12)" + (mi > 0 ? String(format: ":%02d", mi) : "")
  return ampm ? s + (h >= 12 ? "pm" : "am") : s
}

func rangeText(_ a: Double, _ b: Double) -> String {
  let hour = { (ms: Double) in Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ms / 1000)) }
  let same = (hour(a) >= 12) == (hour(b) >= 12)
  return hmText(a, ampm: !same) + " – " + hmText(b)
}
