// Preferences, sounds, screen geometry and small window helpers.
import AppKit
import ServiceManagement

// MARK: - Preferences

enum Prefs {
  static let d = UserDefaults.standard
  static func register() {
    d.register(defaults: [
      "glassTint": 0.35, "sound": true, "volume": 0.4, "reminders": true,
      "showFree": true, "glass": true, "onboarded": false,
    ])
  }
  static var glassTint: Double { get { d.double(forKey: "glassTint") } set { d.set(newValue, forKey: "glassTint") } }
  static var sound: Bool { get { d.bool(forKey: "sound") } set { d.set(newValue, forKey: "sound") } }
  static var volume: Double { get { d.double(forKey: "volume") } set { d.set(newValue, forKey: "volume") } }
  static var reminders: Bool { get { d.bool(forKey: "reminders") } set { d.set(newValue, forKey: "reminders") } }
  static var showFree: Bool { get { d.bool(forKey: "showFree") } set { d.set(newValue, forKey: "showFree") } }
  static var glass: Bool { get { d.bool(forKey: "glass") } set { d.set(newValue, forKey: "glass") } }
  /// Calendar identifiers the user switched off in Settings (new calendars show by default).
  static var hiddenCalendars: [String] { get { d.stringArray(forKey: "hiddenCalendars") ?? [] } set { d.set(newValue, forKey: "hiddenCalendars") } }
  static var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
}

var glassSupported: Bool {
  if #available(macOS 26.0, *) { return true }
  return false
}

// MARK: - Launch at login (SMAppService: the system Login Items list, no LaunchAgent plist)

enum LoginItem {
  static var enabled: Bool { SMAppService.mainApp.status == .enabled }
  @discardableResult static func set(_ on: Bool) -> Bool {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      NSLog("CornerCal: login item \(on ? "register" : "unregister") failed: \(error)")
    }
    // Turned off before in Login Items, or needs approval: the switch would silently snap back, so show them where.
    if on && SMAppService.mainApp.status != .enabled {
      SMAppService.openSystemSettingsLoginItems()
      return false
    }
    return true
  }
}

// MARK: - Sounds (Kenney.nl Interface + Sci-fi packs, CC0)

final class Sounds {
  static let muted = CommandLine.arguments.contains("--mute")
  private var cache: [String: NSSound] = [:]
  private var humOn = false, humVol = -1.0
  private static let HUM_VOL = 0.8, HUM_CURVE = 4.0
  static let ALERT_VOL = 1.0   // reminders ignore the volume slider: at 0.4 they were easy to miss

  private func sound(_ name: String) -> NSSound? {
    if let s = cache[name] { return s }
    guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds"),
          let s = NSSound(contentsOf: url, byReference: false) else { return nil }
    cache[name] = s
    return s
  }

  func play(_ name: String, _ vol: Double = 0.8) {
    guard Prefs.sound, !Sounds.muted, let s = sound(name) else { return }
    s.stop(); s.volume = Float(vol * Prefs.volume); s.play()
  }

  func alert(_ name: String) {
    guard Prefs.sound, !Sounds.muted, let s = sound(name) else { return }
    s.stop(); s.volume = Float(Sounds.ALERT_VOL); s.play()
  }

  /// A low hum that swells exponentially as the cursor nears the corner; level is 0–1 proximity.
  func hum(_ level: Double) {
    let l = max(0, min(1, level))
    let shaped = (exp(Sounds.HUM_CURVE * l) - 1) / (exp(Sounds.HUM_CURVE) - 1)
    let v = Prefs.sound && !Sounds.muted ? shaped * Sounds.HUM_VOL * Prefs.volume : 0
    guard let s = sound("hum") else { return }
    if v < 0.005 {
      if humOn { s.stop(); humOn = false; humVol = -1 }
      return
    }
    if !humOn {
      s.loops = true; s.volume = Float(v); s.play()
      humOn = true; humVol = v
    } else if abs(v - humVol) >= 0.004 {
      s.volume = Float(v); humVol = v
    }
  }
}

// MARK: - Geometry in top-left coordinates
// The physics was written (in Lua) for screen coordinates with y growing downward from the top of the
// primary screen. Cocoa's y grows upward from its bottom edge. Everything converts at these two helpers.

var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 900 }

func topLeft(_ r: NSRect) -> CGRect {
  CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func cocoaRect(_ r: CGRect) -> NSRect {
  NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func mouseTL() -> CGPoint {
  let p = NSEvent.mouseLocation
  return CGPoint(x: p.x, y: primaryHeight - p.y)
}

func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { max(a, min(b, v)) }
func clamp01(_ v: Double) -> Double { clamp(v, 0, 1) }

/// A borderless, click-through-capable panel that floats on every Space, including over full-screen apps.
func overlayPanel(size: NSSize, level: NSWindow.Level) -> NSPanel {
  let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
  p.isOpaque = false
  p.backgroundColor = .clear
  p.hasShadow = false
  p.level = level
  p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
  p.isReleasedWhenClosed = false
  p.hidesOnDeactivate = false
  p.animationBehavior = .none
  return p
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

// MARK: - Easing curves shared with panel.html

/// The --liquid CSS easing: a damped spring (ζ ≈ 0.62, ~8% overshoot) sampled at 49 points.
private let LIQUID: [Double] = [0.0, 0.0244, 0.088, 0.1782, 0.2841, 0.3968, 0.5094, 0.6167, 0.715, 0.802, 0.8764, 0.9381,
  0.9872, 1.0246, 1.0515, 1.0693, 1.0795, 1.0834, 1.0824, 1.0779, 1.0708, 1.0623, 1.0529, 1.0435, 1.0344,
  1.0259, 1.0184, 1.0119, 1.0065, 1.0021, 0.9987, 0.9962, 0.9945, 0.9935, 0.9931, 0.9931, 0.9934, 0.9939,
  0.9946, 0.9954, 0.9962, 0.9969, 0.9977, 0.9983, 0.9989, 0.9993, 0.9997, 1.0, 1]

func liquid(_ t: Double) -> Double {
  let f = clamp01(t) * Double(LIQUID.count - 1)
  let i = Int(f)
  if i >= LIQUID.count - 1 { return 1 }
  return LIQUID[i] + (LIQUID[i + 1] - LIQUID[i]) * (f - Double(i))
}
func easeIn(_ t: Double) -> Double { pow(clamp01(t), 2.5) }
func easeOut(_ t: Double) -> Double { 1 - pow(1 - clamp01(t), 2.2) }

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
