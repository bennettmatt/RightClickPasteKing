# RightClickPasteKing

A macOS menu bar app that makes **right-click in Apple's Terminal.app** behave
like it does on Windows/Linux:

- **If something is selected** → right-click **copies** the selection —
  always, regardless of what's on the clipboard.
- **If nothing is selected and the clipboard has text** → right-click
  **pastes** the clipboard.
- **If nothing is selected and the clipboard is empty** → Terminal's
  normal contextual menu appears (a fraction of a second late — the cost
  of probing for a selection), so you're never left with a dead click.

Optionally, **Clear Clipboard After Paste** (a menu toggle, **on by
default**) empties the system clipboard after a paste — turning right-click
paste into a "consume once" action. Turn it off if you'd rather the
clipboard keep its contents after a paste.

Terminal.app only. Other terminals (iTerm2, Ghostty, etc.) are deliberately
out of scope for this build.

---

## How it works

The app installs a session-level `CGEventTap` that watches for
right-mouse-down events. It acts only when **both** Terminal is the
frontmost app **and** the click actually landed on a Terminal window
(verified against the on-screen window stack at the click point). The two
conditions cover each other's blind spots: the window check stops the app
from reacting to clicks on other apps' windows while Terminal happens to be
focused, and the frontmost check guarantees the synthesized keystrokes go
to Terminal and never to another app. When the gate passes:

**The click is always swallowed**, because whether a selection exists can
only be discovered by trying — then this logic decides the outcome:

1. Record `NSPasteboard.general.changeCount`.
2. Synthesize **Cmd+C**. If Terminal has a selection, this copies it and the
   change count increments. If not, it's a no-op.
3. After a 60 ms settle delay, re-check the change count:
   - **Changed** → a selection existed and was copied. Done — clipboard
     state never mattered.
   - **Unchanged and the clipboard has text** → no selection. Synthesize
     **Cmd+V** to paste.
   - **Unchanged and the clipboard is empty** → no selection, nothing to
     paste. The originally swallowed right-click is re-posted (stamped so
     the tap ignores it), and Terminal's own contextual menu appears.
4. If **Clear Clipboard After Paste** is on and step 3 pasted, the system
   clipboard is cleared a short delay later (after the paste has landed).
   This never happens after a copy.

### Why this indirect approach?

Terminal.app does not expose its text selection reliably through the
Accessibility API — `AXSelectedText` on Terminal's text area is frequently
empty even when text is visibly highlighted. So "ask Terminal whether there's
a selection" can't be done with confidence.

Leaning on Terminal's *own* Copy command and watching the pasteboard's change
count sidesteps that entirely. The only side effect is the expected one:
copying a selection replaces the clipboard contents.

This rationale is also documented at the top of `EventTapController.swift`.

---

## Requirements

- macOS 13 (Ventura) or later
- Xcode (full Xcode, for building and archiving)
- [XcodeGen](https://github.com/yonyz/XcodeGen) — `brew install xcodegen`.
  The Xcode project is generated from `project.yml`; it isn't committed.

## Build

The `.xcodeproj` is generated, not checked in. After a fresh checkout, or
any time `VERSION` / `project.yml` / the source file list changes:

```sh
./regenerate.sh
open RightClickPasteKing.xcodeproj
```

Then build and run the `RightClickPasteKing` scheme in Xcode as normal.

`regenerate.sh` reads the `VERSION` file, generates a build number, injects
both into a version-stamped copy of `project.yml`, and runs XcodeGen. The
signing settings (Developer ID, Hardened Runtime, Team ID, App Sandbox off)
all come from `project.yml`, so a normal Xcode build is already configured
correctly for distribution.

For a fully automated signed + notarized release, see **Distribution** below.

## Install & enable

1. Move `RightClickPasteKing.app` to `/Applications`.
2. Launch it. A menu bar icon appears (no Dock icon).
3. The first-run Setup Guide window appears — follow it to grant
   Accessibility permission (or use the menu's **Open Accessibility
   Settings…**).
4. Enable **RightClickPasteKing** under
   System Settings → Privacy & Security → Accessibility.
   The menu bar icon goes from dimmed to active within ~2 seconds.
5. **Launch at Login** is on by default after first launch — turn it off
   in the menu if you'd rather the app not auto-start.

A global mouse-event tap requires Accessibility permission — there is no way
around this, and it's the same permission tools like Rectangle or BetterTouchTool
use. The app cannot run inside the App Sandbox for the same reason
(see comments in `RightClickPasteKing.entitlements`).

---

## App icon

The icon used by the build is the **asset catalog** at
`Resources/Assets.xcassets/AppIcon.appiconset/` — Xcode compiles it into the
app bundle automatically (wired up by `ASSETCATALOG_COMPILER_APPICON_NAME`
in `project.yml`).

The `icon/` folder holds the editable source material:

- `icon/icon-1024.png` — the 1024×1024 PNG master (source of truth)
- `icon/icon-512.png`, `icon-256.png`, `icon-128.png` — standalone sizes for
  READMEs, web, etc.
- `icon/AppIcon.icns`, `icon/AppIcon.iconset/` — a compiled `.icns` and its
  iconset, kept for convenience / non-Xcode use; not used by the Xcode build.

**To use different artwork:** replace `icon/icon-1024.png` with any
1024×1024 RGBA PNG (it must be square — macOS app icons cannot be
rectangular), then run:

```sh
./make-appicon.sh
```

That regenerates every PNG in the asset catalog from the master, and the
next Xcode build picks them up. No need to re-run `regenerate.sh` — the
asset catalog path is unchanged, only its contents.

---

## Distribution (signed + notarized)

For public distribution with a paid Apple Developer account, `notarize.sh`
runs the whole pipeline — archive → export → notarize → staple → DMG — and
produces a notarized, stapled DMG that opens with no Gatekeeper warning on
anyone's Mac.

**You need a "Developer ID Application" certificate.** This is *not* the
same as an "Apple Development" certificate — that one is for local testing
on your own devices and Gatekeeper won't trust it elsewhere; notarization
rejects it. Check what you have with `security find-identity -v -p
codesigning`. If you only see "Apple Development", create a Developer ID
Application certificate at developer.apple.com (Certificates → + →
Developer ID Application) or via Xcode → Settings → Accounts → Manage
Certificates. The certificate (with its private key) must be in your local
keychain for Xcode to sign with it. `notarize.sh` checks for this and stops
early with a clear message if it's missing.

**One-time setup** (see the header comment in `notarize.sh` for the exact
commands): create an app-specific password and store it as a notarytool
keychain profile named `RCPK-notary`.

**Every release:**

```sh
./regenerate.sh      # only if VERSION / project.yml / sources changed
./notarize.sh
```

Output: `dist/RightClickPasteKing-<version>.dmg` — this is the file you
distribute. Recipients drag the app to `/Applications` and it opens cleanly;
they grant Accessibility permission once on first launch (the in-app Setup
Guide walks them through it — a per-user choice, unrelated to signing).

For local testing you don't need any of this — just build and run the
scheme in Xcode.

---

## Menu

| Item | Behavior |
|---|---|
| **Enabled** | Master on/off toggle. Persists across launches. Defaults to on. |
| **Clear Clipboard After Paste** | When checked, the system clipboard is emptied after a right-click paste, making paste a "consume once" action. **This affects all apps, not just Terminal.** Persists across launches. Defaults to on. |
| **Purple Icon When Clipboard Has Text** | When checked, the menu bar icon turns purple while the clipboard holds text — a glanceable "right-click will paste" indicator (with clear-after-paste on, it visibly resets after each paste). Persists across launches. Defaults to on. |
| **Recent Copies →** | The last 10 text copies, newest first. Selecting one puts it back on the clipboard — the recovery path for consumed pastes. **Memory only** (gone on quit, never written to disk); content marked concealed or transient by the source app (password managers) is never recorded. Includes a Clear History item. |
| **Accessibility: …** | Live status of the required permission. |
| **Open Accessibility Settings…** | Jumps to the right System Settings pane and triggers the system prompt. Hidden once permission is granted. |
| **Setup Guide…** | Reopens the guided first-run window (see below). Useful if it was dismissed before granting permission, or if permission was later revoked. |
| **Launch at Login** | Registers/unregisters the app as a login item via `SMAppService`. Defaults to **on** — enabled automatically on first launch ever. Once you disable it, it stays disabled (no re-enabling on subsequent launches). |
| **Quit** | Quits. |

The menu bar icon is dimmed whenever the feature isn't actively running
(disabled, or permission missing).

---

## First-run experience

The Setup Guide is a two-page window that appears on launch until
Accessibility permission is granted.

**Page 1 — What it does.** The three right-click rules (copy / paste /
pass-through), a note that the app only ever acts inside Terminal, and
plain disclosure of the two on-by-default behaviors — clipboard cleared
after each paste, and launch at login — with a pointer to the menu bar
icon where both can be turned off.

**Page 2 — Grant permission.** The app icon, a short explanation, and an
**Open Accessibility Settings** button. Pressing it opens the System
Settings Accessibility pane *and* fires Apple's own trust prompt, then the
window slides itself alongside System Settings so the two read as one
flow. The app icon in the window is a **drag source** — the user can
either flip the switch in the Accessibility list or drag the icon straight
into it (the same gesture as dragging the `.app` from Finder). A small
spinner with "Waiting for permission…" shows the app is actively watching;
the instant the grant lands, the window moves to the success page. (macOS
has no public API to detect the intermediate "in the list but unchecked"
state — `AXIsProcessTrusted` is strictly granted/not-granted — so this is
as granular as an honest indicator can be.)

Once permission is detected, the window shows a "You're all set" page with
a concrete *try it* suggestion, then closes itself after a few seconds.

The guide reappears on every launch until permission is granted, after
which it never shows on its own again. It can always be reopened from the
**Setup Guide…** menu item — in that case (permission already granted) it
shows just the "What it does" page, acting as an in-app reference card.

A note on the limitation: macOS does not allow an app to draw on top of, or
inject UI into, System Settings — it's a separate sandboxed process. So the
setup window is a *companion* panel positioned beside System Settings, not
an overlay on it. If the System Settings window can't be located (a future
macOS layout change, say), the panel simply stays centered — still fully
usable. Locating the window uses only public window *geometry*, which needs
no Screen Recording permission and triggers no prompt.

---

## Localization

All user-facing text goes through `Sources/L10n.swift`
(`NSLocalizedString`), with translations in
`Resources/<lang>.lproj/Localizable.strings`. Shipped languages: English
(development language), Spanish, French, German, Portuguese (Brazil),
Japanese, and Simplified Chinese. The app name itself is a brand and is
not localized. To add a language: copy `en.lproj` to `<code>.lproj`,
translate the values, run `./regenerate.sh`.

---

## Auto-updates (Sparkle) & releasing

The app updates itself via [Sparkle](https://sparkle-project.org). The
"server" is just static files: GitHub Releases hosts the DMGs, and GitHub
Pages serves `docs/appcast.xml` — the signed feed the app polls. The feed
URL is baked into shipped builds (`SUFeedURL`); the appcast is signed with
an ed25519 key whose private half lives only in the developer's keychain
(`generate_keys`, from `brew install --cask sparkle` — back it up with
`generate_keys -x <file>`).

**One-time setup:**

```sh
./configure-github.sh <your-github-username>   # stamps the feed URL
brew install gh && gh auth login               # GitHub CLI
# Repo Settings → Pages → branch main, folder /docs
```

**Every release:**

```sh
# edit VERSION (e.g. 1.1.1), then:
./release.sh
```

That regenerates the project, notarizes, creates the GitHub release with
the DMG attached, signs and regenerates `docs/appcast.xml` for the new
version, and pushes — after Pages redeploys (a minute or two), installed
apps see the update. The appcast intentionally carries only the newest
version; Sparkle needs nothing more, and delta updates are pointless for
a download this small.

A **Check for Updates…** menu item triggers a manual check; scheduled
background checks use Sparkle's defaults (consent prompt on first run).

---

## Versioning

The `VERSION` file at the project root is the single source of truth for
the app's version (e.g. `1.0.0`). To release a new version, edit that file
and run `./regenerate.sh`.

`regenerate.sh` reads `VERSION`, generates a build number, and injects both
into the project as build settings:
- `MARKETING_VERSION` ← the contents of `VERSION`
- `CURRENT_PROJECT_VERSION` ← a monotonic build number, a UTC timestamp
  (`YYYYMMDDHHMM`), so it always increases without manual bumping

`Info.plist` references these as `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)`, which Xcode expands at build time into
`CFBundleShortVersionString` and `CFBundleVersion`.

The committed `project.yml` keeps placeholder version values and stays
diff-clean; `regenerate.sh` writes the real values into a temporary,
git-ignored copy before running XcodeGen. This matters because notarization
and update tooling reject re-used build numbers.

---

## File layout

```
RightClickPasteKing/
├── project.yml                           XcodeGen spec — the project source of truth
├── regenerate.sh                         Generates the .xcodeproj (version-stamped)
├── notarize.sh                           archive → export → notarize → staple → DMG
├── make-appicon.sh                       Regenerates the asset catalog from a 1024px PNG
├── VERSION                               Single source of truth for the app version
├── .gitignore                            Ignores the generated .xcodeproj and build output
├── README.md                             This file
├── Sources/
│   ├── main.swift                        Entry point; sets .accessory policy
│   ├── AppDelegate.swift                 Status item, menu, state, permission polling
│   ├── EventTapController.swift          The CGEventTap + copy/paste decision logic
│   ├── FirstRunWindowController.swift     Guided setup window + drag-to-grant icon
│   ├── AccessibilityPermission.swift     AXIsProcessTrusted wrapper
│   ├── LoginItem.swift                   SMAppService launch-at-login wrapper
│   ├── Info.plist                        Bundle metadata; version via build settings
│   └── RightClickPasteKing.entitlements  Sandbox disabled (required), with rationale
├── Resources/
│   └── Assets.xcassets/
│       └── AppIcon.appiconset/           The app icon used by the build
└── icon/
    ├── icon-1024.png                     1024×1024 PNG master (source of truth)
    ├── icon-512/256/128.png              Standalone convenience sizes
    └── AppIcon.icns                      Compiled .icns — convenience, not used by build
```

The generated `RightClickPasteKing.xcodeproj` is not in this list because
it is not committed — run `./regenerate.sh` to produce it.

## Notes & edge cases handled

- **Tap auto-recovery**: macOS can silently disable an event tap after a
  timeout or sleep/wake. The callback handles `tapDisabledByTimeout` /
  `tapDisabledByUserInput`, and a 2-second poll re-arms the tap if needed.
- **Permission changes at runtime**: granting or revoking Accessibility
  permission while the app runs is picked up by the poll timer; the tap and
  menu update automatically without a relaunch.
- **No recursion**: synthesized keystrokes are stamped with a magic
  `eventSourceUserData` value and ignored if they're ever seen by the tap.
- **Empty clipboard**: the right-click is passed through untouched, so
  Terminal's own contextual menu appears — the user never gets a dead click.
  Non-text clipboard contents (images, files) are treated the same as empty.
