# PDF Viewer

A native macOS PDF viewer built with SwiftUI and PDFKit. macOS 14+, no third-party
dependencies. No paid Apple Developer account needed.

- Tabbed interface, one tab per PDF
- Tab context menu: pin, duplicate, reload, close, close other tabs, close tabs to the right
- Split view: show two PDFs side by side with a draggable divider (right-click a tab)
- Open via File > Open (⌘O), by dragging onto the window, or by dropping onto the Dock icon
- ⌘⇧`[` / ⌘⇧`]` switch tabs, ⌘W closes the current tab, ⌘⇧T reopens a closed tab
- Remembers every open tab, its page, its zoom, pinned tabs and split layout, and restores them on relaunch
- Continuous vertical scrolling, zoom (⌘+ / ⌘−), fit to width
- Find bar (⌘F) with match highlighting and next/previous
- Toggleable thumbnail sidebar (⌘⌥T)
- Opencode agent panel (⌘⌥A): chat about the whole document or just the current page, using a local `opencode serve`
- Light and dark mode follow the system automatically

---

## 1. Run it without Xcode (recommended if you don't want to touch macOS)

You do **not** need Xcode, and you do **not** need to update macOS. The Command
Line Tools that ship with macOS can build this app on their own.

```bash
./build-app.sh              # builds dist/PDFViewer.app
./build-app.sh --install    # builds and installs to /Applications
```

Then launch it:

```bash
open dist/PDFViewer.app
```

Or after `--install`, just find **PDF Viewer** in Launchpad.

The script produces a universal (arm64 + x86_64) binary targeting macOS 14.0,
so it runs on your machine and survives being moved to another Mac.

### What it signs with

An ad-hoc local signature — no Apple ID, no developer account, no network. macOS
will run it because you built it yourself and it carries no quarantine flag.

```
codesign --verify --strict --verbose=2 dist/PDFViewer.app
```

Because it is ad-hoc and not notarized, it will only ever run on your Mac. That
is fine for personal use.

### Why no macOS update is needed

The app targets **macOS 14.0** and is compiled against the **15.5 SDK** that
ships with your Command Line Tools. Running it requires macOS 14 or later. You
are on 15.5, so you are already fine.

The macOS update is only needed for a *newer Xcode*, not for this app:

| Xcode  | Needs macOS | Works on your 15.5? |
| ------ | ----------- | ------------------- |
| 26.x   | 15.6+       | No                  |
| 16.4   | 15.3+       | Yes                 |
| 16.3   | 15.5+       | Yes                 |
| 16.2   | 14.5+       | Yes                 |

If you later want the Xcode IDE for debugging, install **Xcode 16.4** from
<https://developer.apple.com/downloads/> rather than the App Store copy — the
App Store will keep nudging you toward a version your machine cannot run.

### Two things this build cannot do

- **No app icon.** `actool` (which compiles `.xcassets`) only ships with the full
  Xcode, so the app shows the generic document icon. Cosmetic only.
- **No debugger.** Use `Console.app` or `log stream --predicate 'process ==
  "PDFViewer"'` to read messages.

If you build inside an iCloud-synced folder (`~/Documents` often is), the script
strips extended attributes before signing — macOS otherwise stamps
`com.apple.FinderInfo` onto the bundle and `codesign` refuses it. To build
somewhere else:

```bash
BUILD_DIR=~/build ./build-app.sh
```

---

## 2. If you do want to use Xcode

Nothing here is required. Jump to section 3 if you want to start from a
fresh template instead.

### Install a compatible Xcode

Download **Xcode 16.4** from <https://developer.apple.com/downloads/> (see the
table above for why not a newer one). Then point the command line tools at it:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcode-select -p     # must contain "Xcode.app"
```

### Open the project

1. Open `PDFViewer.xcodeproj`.
2. Pick the **PDFViewer** scheme at the top-left of the toolbar.
3. Press **⌘R**.

The shared scheme is checked in, so it selects automatically.

### Setting the bundle identifier

The project ships with `com.example.PDFViewer`. Make it yours:

1. Click the blue **PDFViewer** project icon.
2. Select the **PDFViewer** target.
3. **Signing & Capabilities** tab.
4. Replace **Bundle Identifier** with something unique, e.g. `com.ian.pdfsviewer`
   (at least two segments; letters, numbers, hyphens and periods only).

---

## 3. Signing and installing from Xcode

macOS lets you run apps signed by your own Apple ID, for free. Nothing extra to
install — the project is already configured for this.

**In Xcode**, the app runs with ⌘R. That is already working. Xcode handles the
local signing for you.

**Check what it is signed as** at any time via
**Product > Build… > Signing**.

If Xcode ever offers you a choice, pick **Sign to Run Locally**.

### Making a proper .app you can keep

To get a normal `.app` bundle on disk (rather than a temp build folder):

1. **Product > Build** (⌘B).
2. Open the **Report navigator** (the leftmost icon in the Xcode toolbar).
3. Find the most recent "Build PDFViewer" entry and expand it.
4. Click the **Products** folder node.
5. Right-click `PDFViewer.app` and choose **Show in Finder**.

Or find it directly:

```bash
find ~/Library/Developer/Xcode/DerivedData -name "PDFViewer.app" -maxdepth 5
```

### Installing to /Applications

```bash
DRAG_PATH="$(find ~/Library/Developer/Xcode/DerivedData -name 'PDFViewer.app' -maxdepth 5 -print -quit)"
cp -R "$DRAG_PATH" /Applications/
```

Then launch it from Launchpad or Finder. **Quit Xcode first** so it is not
overwriting the file you copied.

### What "Sign to Run Locally" means

- The app is signed with an ad-hoc local certificate tied to your Mac.
- It runs fine on your Mac.
- It will not run on anyone else's Mac, and it cannot be notarized or put on the
  Mac App Store. For personal use, that is all you need.
- If macOS ever refuses to open it (e.g. the file lost its quarantine flag after
  copying), clear the attribute:

```bash
xattr -d com.apple.quarantine /Applications/PDFViewer.app
```

### If you would rather use a free Apple ID as the signing team

1. **Xcode > Settings… > Accounts** (⌘,).
2. Click **+ > Apple ID** and sign in with your free @icloud.com address.
3. Back in **Signing & Capabilities**, set **Team** to your personal team.

Xcode will generate a development certificate automatically. You get the same
locally-runnable app either way.

---

## 4. Building it yourself from scratch in Xcode

You do not need this — the project is ready. But if you want to see how it is
put together, or want to start from your own file, here is the equivalent.

### a. Create the project

1. **File > New > Project…**
2. Choose **macOS** at the top.
3. Choose the **App** template (SwiftUI is pre-selected).
4. Click **Next**.
5. Fill in:

   | Field                    | Value                     |
   | ------------------------ | ------------------------- |
   | Product Name             | `PDFViewer`               |
   | Interface                | SwiftUI                   |
   | Language                 | Swift                     |
   | Tests                    | None                      |
   | Storage                  | None                      |

6. Click **Next**, then **Create**. Xcode makes a `PDFViewer` folder.
7. Select the **PDFViewer** target > **Build Settings** and confirm
   **macOS Deployment Target** is `14.0` (or higher).

### b. Delete the template's files

In the Project navigator, select and delete:

- `PDFViewerApp.swift`
- `ContentView.swift`
- `PDFViewer.assetset` is fine to keep — the folder is called `Assets.xcassets`
  and you will replace its contents.

### c. Add the source files

**Drag the folders in.** In Finder, this project has:

```
PDFViewer/
├── Sources/
│   ├── App/
│   ├── Model/
│   ├── Store/
│   └── Views/
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

Drag `Sources` into the Xcode project navigator (onto the blue `PDFViewer` icon,
above the `PDFViewer` group). When Xcode asks, choose:

- **Create groups** (not folder references)
- Tick **Add to targets** → `PDFViewer`

Do the same for `Resources/Assets.xcassets`.

> Do **not** add `Info.plist` as a file reference. It is already wired up through
> the **Info** build setting and adding it a second time causes a duplicate
> `CFBundleIdentifier` crash at launch.

### d. Verify the Info build setting

Target > **Build Settings** > **Info**:

- **Info.plist File** = `Resources/Info.plist`
- **Generate Info.plist File** = **No**

### e. Build and run (⌘R)

---

## 5. Keyboard shortcuts

| Action              | Shortcut              |
| ------------------- | --------------------- |
| Open PDF(s)         | ⌘O                   |
| Close current tab   | ⌘W                   |
| Find in document    | ⌘F                   |
| Next / previous tab | ⌘⇧`]` / ⌘⇧`[`      |
| Reopen closed tab   | ⌘⇧T                  |
| Zoom in / out       | ⌘+ / ⌘−              |
| Actual size (100%)  | ⌘0                   |
| Toggle thumbnails   | ⌘⌥T                  |
| Toggle agent panel  | ⌘⌥A                  |
| Next / previous hit | ⏎ / ⌘G in the find bar |
| Dismiss find bar    | esc                   |

---

## 6. Where your data lives

Open tabs, pages and zoom are saved to:

```
~/Library/Application Support/com.example.PDFViewer/session.json
```

(Use your own bundle identifier if you changed it.) Paths are stored alongside
bookmarks, so PDFs keep working if you move or rename them.

To reset the app to a blank slate, quit it and delete that `session.json`.

---

## 7. Troubleshooting

**codesign: "resource fork, Finder information, or similar detritus not allowed"**
You are building inside an iCloud-synced folder. `build-app.sh` already runs
`xattr -cr` to handle this. If you hit it anyway, run
`xattr -cr dist/PDFViewer.app` and build to a non-synced folder with
`BUILD_DIR=~/build ./build-app.sh`.

**"The application cannot be opened because it is not a developer-signed application"**
The bundle picked up a quarantine flag, usually from being zipped and unzipped or
downloaded from somewhere. Run:
`xattr -dr com.apple.quarantine /Applications/PDFViewer.app`

**"The application cannot be opened" after changing the bundle identifier**
Delete the old copy first. `build-app.sh --install` does this for you.

**No app icon / no custom accent colour**
Expected. Compiling an `.xcassets` needs `actool`, which only exists in the full
Xcode. Cosmetic only.

**"No profiles for 'PDFViewer' were found"** or a red signing error.
Go to Target > **Signing & Capabilities** and set **Team** to your personal team,
or select **Sign to Run Locally**. If the team list is empty, add your Apple ID
under **Xcode > Settings > Accounts**.

**"Signing for 'PDFViewer' requires a development team"**
Same fix — pick a team. For a purely local build you can also set
**Signing Certificate** to **Sign to Run Locally** and leave Team blank.

**Build fails: `Multiple commands produce ... Info.plist`**
You have two Info.plist references. Delete the one shown in red from the
navigator, and confirm **Generate Info.plist File** is **No**.

**Build fails: `Cannot find 'PDFViewerApp' in scope`**
The file `Sources/App/PDFViewerApp.swift` is missing from the target, or the
`@main` entry point got deleted. Select the file, check **Target Membership**
under **File > Inspect** includes `PDFViewer`, and confirm one — and only one —
type is marked `@main`.

**Nothing happens when I press ⌘R / the app doesn't appear**
The Xcode scheme may be set to a Test action. Use **Product > Run**, and make sure
the scheme next to the play button reads **PDFViewer**.

**"The application cannot be opened because it is not a developer-signed application"**
You are double-clicking a `.app` from DerivedData that was copied while still
signed for a different bundle ID, or an unsigned one. Rebuild (⌘B), copy it
fresh, and if needed run `xattr -dr com.apple.quarantine /Applications/PDFViewer.app`.

**⌘W closes the whole window instead of the tab**
The `MainMenuTweaks` fixup runs in `ContentView.onAppear`. If you moved
`PDFViewerApp.swift`'s scene body around and dropped that `.onAppear`, put it
back — AppKit gives the menu bar first refusal on ⌘W.

**The window is blank / the PDF does not appear**
Check **View > Debug View Hierarchy** is off, then **Product > Run** to relaunch.
If a tab shows an empty pane, close and reopen that tab.

**Tabs come back on the wrong page**
`session.json` is only written 0.75 s after you stop scrolling, and again at
quit. If the app was force-quit, the last scroll may not have been saved. Quit
normally with ⌘Q instead.

**Dark mode looks wrong, or the PDF area stays white in dark mode**
The app reads system colors so it follows the system. Switch macOS appearance in
**System Settings > Appearance** with the app open.

**Xcode is asking for my keychain password every build**
Choose **Always Allow** on the prompt. If it never sticks, **Keychain Access >
login > right-click "Mac-Auto-Update-..." (or the "login" key) > Info >
Access Control > Allow all applications**.

**The app quits when I close the window**
That is intentional (`applicationShouldTerminateAfterLastWindowClosed`), matching
normal macOS behaviour. Your tabs are saved and restored on the next launch.

---

## 8. Source layout

```
PDFViewer/
├── Sources/
│   ├── App/
│   │   ├── PDFViewerApp.swift      @main, WindowGroup, all menu commands
│   │   ├── AppDelegate.swift       Dock drops, session save on quit
│   │   └── MainMenuTweaks.swift    frees ⌘W from SwiftUI's built-in "Close"
│   ├── Model/
│   │   ├── PDFDocumentTab.swift    one open PDF: PDFView, zoom, search, restore
│   │   └── Session.swift           Codable shapes written to disk
│   ├── Store/
│   │   ├── LibraryStore.swift      tab list, open/close, debounced session save
│   │   ├── SessionStore.swift      reads/writes session.json, file bookmarks
│   │   ├── AgentChatModel.swift    agent panel state, server lifecycle, settings
│   │   └── OpenCodeClient.swift    HTTP client for the opencode server
│   └── Views/
│       ├── ContentView.swift       root layout, window drop target, toolbar
│       ├── DocumentTabBar.swift    the tab strip
│       ├── PDFViewerPane.swift     sidebar + PDFView + find bar
│       ├── FitWidthPDFView.swift   PDFView that reports width changes
│       ├── ThumbnailSidebar.swift  PDFThumbnailView bridge
│       ├── FindBar.swift           ⌘F search field and match counter
│       ├── AgentChatPanel.swift    opencode chat sidebar
│       └── WelcomeView.swift       empty state
└── Resources/
    ├── Info.plist                  declares the app as a PDF handler
    └── Assets.xcassets             app icon and accent colour slots
```

### How a few things work

**Tabs.** `PDFDocumentTab` owns its own `PDFView` instance. Switching tabs just
changes which one SwiftUI puts on screen, so scroll position and zoom are kept
in memory rather than re-derived.

**Fit to width.** `FitWidthPDFView` overrides `setFrameSize` and reports every
width change to the tab, which recomputes `scaleFactor` from the current page's
width. A 0.5% dead zone stops the resize from feeding back into itself.

**Restoring the page.** A freshly created `PDFView` has no frame, and `go(to:)`
is a no-op without one. So `restore(pageIndex:…)` stores the target page and the
real scroll is deferred to the first layout pass, after fit-to-width has run.

**⌘W.** AppKit checks the menu bar for key equivalents before the window sees
them, so SwiftUI's built-in "Close" item would win. `MainMenuTweaks` clears its
key equivalent at launch, leaving the app's own "Close Tab" as the only ⌘W.

**Session saving.** Writes are debounced by 0.75 s and forced on quit, so
scrolling does not hammer the disk.