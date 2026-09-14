// CornerCal — your calendar in the corner of the screen.
// No menu-bar icon: settings live behind the gear in the panel, or open the app again from Finder/Spotlight.
import AppKit
import WebKit
import SwiftUI

let VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

/// A normal titled window hosting one of the bundled HTML pages (settings, welcome).
final class WebWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let web: ClickWebView
  var onClose: (() -> Void)?

  init(title: String, size: NSSize, page: String, state: String, handlerName: String, handler: @escaping ([String: Any]) -> Void) {
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    window.title = title
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = true
    let config = WKWebViewConfiguration()
    config.userContentController.add(ScriptBridge(handler), name: handlerName)
    web = ClickWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    web.setValue(false, forKey: "drawsBackground")
    web.autoresizingMask = [.width, .height]
    // The page fills the window under a transparent title bar, and a web view swallows drags, so give the
    // title-bar strip back to the window: without this the window can't be moved.
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.addSubview(web)
    let strip = DragStrip(frame: NSRect(x: 0, y: size.height - 32, width: size.width, height: 32))
    strip.autoresizingMask = [.width, .minYMargin]
    container.addSubview(strip)
    window.contentView = container
    super.init()
    window.delegate = self
    web.loadHTMLString(loadPage(page, replacing: ["/*STATE*/": state]), baseURL: Bundle.main.resourceURL)
    window.center()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func js(_ s: String) { web.evaluateJavaScript(s, completionHandler: nil) }

  func windowWillClose(_ notification: Notification) { onClose?() }
}

final class DragStrip: NSView {
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

func jsonString(_ obj: Any) -> String {
  guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "{}" }
  return s
}

/// What the bottom-right Hot Corner is set to, if anything (it would fire alongside CornerCal).
func bottomRightHotCorner() -> String? {
  let names = [2: "Mission Control", 3: "Application Windows", 4: "Desktop", 5: "Start Screen Saver", 6: "Disable Screen Saver",
               10: "Put Display to Sleep", 11: "Launchpad", 12: "Notification Center", 13: "Lock Screen", 14: "Quick Note"]
  let v = UserDefaults(suiteName: "com.apple.dock")?.integer(forKey: "wvous-br-corner") ?? 0
  return names[v]
}

/// Running from the disk image or from a quarantined copy macOS moved aside (App Translocation).
var runningOutsideApplications: Bool {
  let p = Bundle.main.bundlePath
  return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
}

func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

final class AppDelegate: NSObject, NSApplicationDelegate {
  var source: CalendarSource!
  var corner: CornerController!
  var settingsWindow: NSWindow?
  var settingsModel: SettingsModel?
  var welcome: WebWindow?
  var activity: NSObjectProtocol?
  let args = CommandLine.arguments

  func applicationDidFinishLaunching(_ note: Notification) {
    Prefs.register()
    // A corner utility has to answer the pointer promptly and fire reminders on time; App Nap would throttle its timers.
    activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Watching the screen corner and reminders")
    buildMenu()
    source = CalendarSource(demo: args.contains("--demo"))
    corner = CornerController(source: source)
    corner.openSettings = { [weak self] in self?.showSettings() }
    corner.start()

    if args.contains("--welcome") || (!source.demo && !Prefs.onboarded) {
      showWelcome()
    }
    if args.contains("--settings") { showSettings() }
    if args.contains("--test-remind") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.corner.testReminder() }
    }
    if args.contains("--test-panel") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if let s = NSScreen.screens.first { self.corner.pinned = true; self.corner.show(on: s) } }
    }
    if let i = args.firstIndex(of: "--snapshot-panel"), i + 1 < args.count {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.corner.snapshotPanel(to: URL(fileURLWithPath: self.args[i + 1])) }
    }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
      let path = args[i + 1]
      let delay = Double(args.count > i + 2 ? args[i + 2] : "") ?? 2.5
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        self.corner.banner.snapshot(to: URL(fileURLWithPath: path))
        try? self.corner.banner.debugInfo.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
      }
    }
  }

  /// Opening the app again (Finder, Spotlight, Launchpad) while it runs is the way back to settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if welcome != nil { welcome?.show() } else { showSettings() }
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  private func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let m = NSMenu()
    m.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
    m.addItem(.separator())
    m.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    m.addItem(withTitle: "Quit CornerCal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = m
    NSApp.mainMenu = main
  }

  @objc func settingsAction() { showSettings() }

  // MARK: settings (native SwiftUI, SettingsUI.swift)

  func showSettings() {
    if let w = settingsWindow {
      settingsModel?.reload()
      NSApp.activate(ignoringOtherApps: true)
      w.makeKeyAndOrderFront(nil)
      return
    }
    let m = SettingsModel(source: source, corner: corner)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled, .closable],
                     backing: .buffered, defer: false)
    w.title = "CornerCal Settings"
    w.isReleasedWhenClosed = false
    w.contentViewController = NSHostingController(rootView: SettingsView(m: m, onPreview: { [weak self, weak w] in
      guard let self else { return }
      w?.orderOut(nil)
      self.corner.testReminder()
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { w?.makeKeyAndOrderFront(nil) }
    }))
    w.setContentSize(NSSize(width: 480, height: 660))
    w.center()
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
      self?.settingsWindow = nil; self?.settingsModel = nil
    }
    settingsWindow = w; settingsModel = m
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
  }

  // MARK: welcome

  private func welcomeState() -> String {
    jsonString([
      "access": source.demo ? "granted" : CalendarSource.access.rawValue,
      "login": LoginItem.enabled, "outside": runningOutsideApplications,
      "hotCorner": bottomRightHotCorner().map { $0 as Any } ?? NSNull(), "version": VERSION,
    ])
  }

  func showWelcome() {
    if let w = welcome { w.show(); return }
    let w = WebWindow(title: "Welcome to CornerCal", size: NSSize(width: 520, height: 660), page: "welcome.html",
                      state: welcomeState(), handlerName: "cornercal") { [weak self] b in self?.handleWelcome(b) }
    w.onClose = { [weak self] in
      guard let self else { return }
      self.welcome = nil
      Prefs.onboarded = true
    }
    welcome = w
    w.show()
  }

  private func handleWelcome(_ b: [String: Any]) {
    switch b["type"] as? String {
    case "grant":
      source.requestAccess { [weak self] _ in
        guard let self else { return }
        self.welcome?.js("setState(\(self.welcomeState()))")
        self.welcome?.show()   // the system prompt took focus
      }
    case "privacy": openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    case "hotcorners": openURL("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
    case "recheck": welcome?.js("setState(\(welcomeState()))")
    case "finish":
      if let login = b["login"] as? Bool, login != LoginItem.enabled { LoginItem.set(login) }
      Prefs.onboarded = true
      welcome?.window.close()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.corner.testReminder() }
    default: break
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    // Coming back from System Settings: pick up a permission granted there.
    welcome?.js("setState(\(welcomeState()))")
    settingsModel?.reload()
    if CalendarSource.access == .granted && source.error == "noaccess" { source.refresh() }
  }
}

// Only one CornerCal at a time (e.g. one from the disk image and one from Applications).
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }),
   !CommandLine.arguments.contains("--allow-second") {
  NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0 != .current }?.activate()
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
