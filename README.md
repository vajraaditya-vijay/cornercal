# CornerCal

Your calendar, parked in the bottom-right corner of your Mac.

- A pill in the corner shows the event you're in (it fills up as it goes), or your free time counting down to the next one.
- Rest the pointer in the corner and your day's timeline springs open: yesterday above, today, tomorrow.
- When something starts, and 5 minutes before it ends, the pill grows with a chime and keeps nudging until you point at it.
- Reads the macOS Calendar app, so Google, iCloud and school accounts on your Mac all work. Pick which calendars show.
- Liquid glass on macOS 26. No account, no tracking, nothing leaves your Mac.

**Download:** https://cornercal.vajraaditya.me · macOS 14+ · Apple Silicon and Intel · free

## Installing

CornerCal isn't notarized (that's Apple's $99/year Developer Program, and this is a student project), so macOS blocks it the first time:

1. Open the DMG and drag CornerCal to Applications.
2. Open CornerCal. macOS says it can't verify the developer.
3. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to CornerCal (within about an hour).
4. Enter your password, click **Open**.
5. Allow Calendar access.

Terminal people: `xattr -dr com.apple.quarantine /Applications/CornerCal.app`

## Building

Needs only the Xcode Command Line Tools.

```bash
./build.sh                 # build/CornerCal.app, universal, ad-hoc signed
./dist-tools/make-dmg.sh   # dist/CornerCal-<version>.dmg
open build/CornerCal.app --args --demo   # fake events, no calendar permission needed
```

Swift (AppKit + SwiftUI) for the pill, glass and settings; the timeline panel is HTML in a WKWebView. EventKit for calendar data.

## Credits

Made by Vajraaditya. Sounds by [Kenney.nl](https://kenney.nl) (CC0).
