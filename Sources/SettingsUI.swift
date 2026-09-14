// Settings as a native SwiftUI window: real Liquid Glass buttons and the macOS 26 scroll-edge fade under the
// title bar come for free here, which a web page can't have (his ask, 14 Sep: no fake glass).
import AppKit
import SwiftUI

struct CalItem: Identifiable {
  let id: String, title: String, color: String, account: String
  var on: Bool
}

final class SettingsModel: ObservableObject {
  let source: CalendarSource
  let corner: CornerController
  @Published var access: Access = .granted
  @Published var calendars: [CalItem] = []
  @Published var showFree = true
  @Published var glass = true
  @Published var reminders = true
  @Published var sound = true
  @Published var login = false
  @Published var tint = 0.35
  @Published var volume = 0.4
  @Published var hotCorner: String?

  init(source: CalendarSource, corner: CornerController) {
    self.source = source
    self.corner = corner
    reload()
  }

  func reload() {
    access = source.demo ? .granted : CalendarSource.access
    calendars = source.calendarList().map {
      CalItem(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", color: $0["color"] as? String ?? "#888888",
              account: $0["account"] as? String ?? "", on: $0["on"] as? Bool ?? true)
    }
    showFree = Prefs.showFree; glass = Prefs.glass; reminders = Prefs.reminders; sound = Prefs.sound
    tint = Prefs.glassTint; volume = Prefs.volume
    login = LoginItem.enabled
    hotCorner = bottomRightHotCorner()
  }

  /// A binding that writes through to the preference and applies it immediately.
  func bind<T>(_ kp: ReferenceWritableKeyPath<SettingsModel, T>, _ apply: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: { self[keyPath: kp] }, set: { v in self[keyPath: kp] = v; apply(v) })
  }

  func grant() { source.requestAccess { [weak self] _ in self?.reload() } }
}

private extension View {
  @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
    if #available(macOS 26.0, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else {
      if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
  }
}

private struct Row<Trailing: View>: View {
  let title: String
  let note: String?
  @ViewBuilder let trailing: Trailing
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
      }
      Spacer(minLength: 8)
      trailing
    }
  }
}

struct SettingsView: View {
  @ObservedObject var m: SettingsModel
  var onPreview: () -> Void

  private var accounts: [String] {
    var seen = Set<String>()
    return m.calendars.map(\.account).filter { seen.insert($0).inserted }
  }

  var body: some View {
    Form {
      if let hc = m.hotCorner {
        Section {
          Row(title: "Your corner is double-booked", note: "The bottom-right Hot Corner opens \(hc), so it fires every time you open CornerCal.") {
            Button("Hot Corners…") { openURL("x-apple.systempreferences:com.apple.Desktop-Settings.extension") }.glassButton()
          }
        }
      }

      Section("Calendar") {
        switch m.access {
        case .granted:
          Row(title: "Calendar access", note: "Reads the Calendar app on this Mac.") {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
          }
        case .undetermined:
          Row(title: "Calendar access", note: "CornerCal is currently guessing your schedule.") {
            Button("Allow…") { m.grant() }.glassButton(prominent: true)
          }
        default:
          Row(title: "Calendar access", note: m.access == .writeOnly ? "It can add events but not read them. Switch it to Full Access."
                                                                     : "Switched off. The pill is just vibes right now.") {
            Button("Open Privacy Settings") { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }
              .glassButton(prominent: true)
          }
        }
      }

      ForEach(accounts, id: \.self) { account in
        Section {
          ForEach($m.calendars.filter { $0.wrappedValue.account == account }) { $cal in
            Toggle(isOn: Binding(get: { cal.on }, set: { on in cal.on = on; m.source.setCalendar(cal.id, on: on) })) {
              HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: color(cal.color))).frame(width: 10, height: 10)
                Text(cal.title).lineLimit(1)
              }
            }
          }
        } header: {
          Text(account)
        } footer: {
          if account == accounts.last {
            Text("Switch off the ones you forgot existed. We won't tell.").font(.callout).foregroundStyle(.secondary)
          }
        }
      }

      Section("Banner") {
        Toggle(isOn: m.bind(\.showFree) { Prefs.showFree = $0; m.corner.banner.showFree = $0 }) {
          Text("Show during free time")
          Text("Counts down to the next thing. Off: the pill only shows up when there's actually something on.")
        }
        Toggle(isOn: m.bind(\.glass) { Prefs.glass = $0; m.corner.banner.setGlass($0) }) {
          Text("Liquid glass")
          Text(glassSupported ? "Leave it on." : "Needs macOS 26 or later.")
        }
        .disabled(!glassSupported)
        if glassSupported && m.glass {
          LabeledContent("Pill opacity") {
            HStack {
              Slider(value: m.bind(\.tint) { Prefs.glassTint = $0; m.corner.banner.setTint($0) }, in: 0...1)
              Text("\(Int((m.tint * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
          }
        }
      }

      Section("Reminders & sound") {
        // Preview sits before the switch so every switch in the window lines up on the right edge.
        Row(title: "Reminders", note: "When something starts, and 5 minutes before it ends. Point at the pill to make it stop nagging.") {
          Button("Preview", action: onPreview).glassButton()
          Toggle("Reminders", isOn: m.bind(\.reminders) { Prefs.reminders = $0 }).labelsHidden().toggleStyle(.switch)
        }
        Toggle(isOn: m.bind(\.sound) { Prefs.sound = $0 }) {
          Text("Sounds")
          Text("Reminder chimes always play at full volume. Ignoring them is on you.")
        }
        LabeledContent("Interface volume") {
          Slider(value: m.bind(\.volume) { Prefs.volume = $0 }, in: 0...1) { editing in
            if !editing { m.corner.sounds.play("dismiss", 0.8) }
          }
        }
        .disabled(!m.sound)
      }

      Section("General") {
        Toggle(isOn: m.bind(\.login) { on in LoginItem.set(on); DispatchQueue.main.async { m.login = LoginItem.enabled } }) {
          Text("Open at login")
          Text("So you can't pretend you forgot.")
        }
        Row(title: "Quit CornerCal", note: "It'll be fine. Open it again from Applications.") {
          Button("Quit") { NSApp.terminate(nil) }.glassButton()
        }
      }

      Section {
        HStack {
          Text("CornerCal \(VERSION)")
          Spacer()
          Text("Sounds by Kenney.nl (CC0)")
        }
        .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 440, minHeight: 400)
  }
}
