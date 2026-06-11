# Header Metadata & GitHub Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the app version, release date, developer credit (`by choihunchul`), and a clickable GitHub repository link to the status menu header of the Codex Menu Bar app.

**Architecture:** Inject `CFBuildDate` during build/packaging script execution into the app's `Info.plist`, read both version and build date keys dynamically in Swift, and configure target-action on the header menu item and a dedicated menu item to launch the browser using `NSWorkspace.shared.open`.

**Tech Stack:** Swift (AppKit), JavaScript (Node.js)

---

### Task 1: Plist Injection Scripts Update

**Files:**
- Modify: [package-app.mjs](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/scripts/package-app.mjs)
- Modify: [install-app.mjs](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/scripts/install-app.mjs)

- [ ] **Step 1: Update `scripts/package-app.mjs` plist generation**

Modify `scripts/package-app.mjs` around lines 78-105:
```javascript
  const buildDate = new Date().toISOString().slice(0, 10);
  // Write Info.plist
  const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexMenuBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.codex.menubar</string>
    <key>CFBundleName</key>
    <string>CodexMenuBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBuildDate</key>
    <string>${buildDate}</string>
</dict>
</plist>
`;
```

- [ ] **Step 2: Update `scripts/install-app.mjs` argument reading and plist generation**

Modify `scripts/install-app.mjs` around lines 35-116:
```javascript
async function main() {
  const version = process.argv[2] || "1.0.5";
  const buildDate = new Date().toISOString().slice(0, 10);
  console.log(`Building version ${version} with build date ${buildDate}...`);
  // (existing lines 36-90)
  
  // Write Info.plist
  const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexMenuBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.codex.menubar</string>
    <key>CFBundleName</key>
    <string>CodexMenuBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBuildDate</key>
    <string>${buildDate}</string>
</dict>
</plist>
`;
```

- [ ] **Step 3: Run package test command**

Run: `node scripts/package-app.mjs 1.0.5`
Expected: Successfully generates `dist/CodexMenuBar.app/Contents/Info.plist` with `CFBuildDate` set to today's date and `CFBundleShortVersionString` set to `1.0.5`.

- [ ] **Step 4: Commit task 1**

```bash
git add scripts/package-app.mjs scripts/install-app.mjs
git commit -m "build: inject build date and dynamic version into Info.plist"
```

---

### Task 2: Swift Integration in main.swift

**Files:**
- Modify: [main.swift](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/Sources/CodexMenuBar/main.swift)

- [ ] **Step 1: Add version/date properties and openGitHub action to `CodexMenuBarApp`**

Add these methods to the class `CodexMenuBarApp`:
```swift
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.5"
    }

    private var buildDate: String {
        if let plistDate = Bundle.main.infoDictionary?["CFBuildDate"] as? String {
            return plistDate
        }
        if let executableURL = Bundle.main.executableURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: modificationDate)
        }
        return "2026-06-05"
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/choihunchul/codex-menu-bar") {
            NSWorkspace.shared.open(url)
        }
    }
```

- [ ] **Step 2: Update `configureMenu()` to register actions and add GitHub Repository menu item**

Update `configureMenu()` to assign the action to item 0 and insert the new menu item. Because adding a menu item shifts the indices of later items, we must update target indices. Here is the updated code mapping:
```swift
    // 0: "Codex Menu Bar" (header, clickable)
    // 1: separator
    // 2: Usage summary view
    // 3: "Codex Status: -"
    // 4: "Detail: -"
    // 5: "Source: -"
    // 6: "Last Activity: -"
    // 7: "Updated: -"
    // 8: separator
    // 9: "5-hour limit: -"
    // 10: "Weekly limit: -"
    // 11: "Limit source: -"
    // 12: separator
    // 13: "AGY: -"
    // 14: "AGY Activity: -"
    // 15: "AGY Conversations: -"
    // 16: separator
    // 17: "GitHub Repository..." (clickable)
    // 18: Settings...
    // 19: Open Status File
    // 20: Reveal Status Folder
    // 21: separator
    // 22: Check for Updates...
    // 23: Restart
    // 24: Quit
    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        let headerItem = NSMenuItem(title: "Codex Menu Bar", action: #selector(openGitHub), keyEquivalent: "")
        headerItem.isEnabled = true
        menu.addItem(headerItem)                                                                     // 0
        menu.addItem(NSMenuItem.separator())                                                         // 1
        
        let summaryItem = NSMenuItem()
        summaryItem.isEnabled = false
        summaryItem.view = usageSummaryView
        menu.addItem(summaryItem)                                                                    // 2
        
        menu.addItem(NSMenuItem(title: "Codex Status: -", action: nil, keyEquivalent: ""))         // 3
        menu.addItem(NSMenuItem(title: "Detail: -", action: nil, keyEquivalent: ""))               // 4
        menu.addItem(NSMenuItem(title: "Source: -", action: nil, keyEquivalent: ""))               // 5
        menu.addItem(NSMenuItem(title: "Last Activity: -", action: nil, keyEquivalent: ""))        // 6
        menu.addItem(NSMenuItem(title: "Updated: -", action: nil, keyEquivalent: ""))              // 7
        menu.addItem(NSMenuItem.separator())                                                         // 8
        menu.addItem(NSMenuItem(title: "5-hour limit: -", action: nil, keyEquivalent: ""))         // 9
        menu.addItem(NSMenuItem(title: "Weekly limit: -", action: nil, keyEquivalent: ""))         // 10
        menu.addItem(NSMenuItem(title: "Limit source: -", action: nil, keyEquivalent: ""))         // 11
        menu.addItem(NSMenuItem.separator())                                                         // 12
        menu.addItem(NSMenuItem(title: "AGY: -", action: nil, keyEquivalent: ""))                  // 13
        menu.addItem(NSMenuItem(title: "AGY Activity: -", action: nil, keyEquivalent: ""))         // 14
        menu.addItem(NSMenuItem(title: "AGY Conversations: -", action: nil, keyEquivalent: ""))    // 15
        menu.addItem(NSMenuItem.separator())                                                         // 16
        
        menu.addItem(NSMenuItem(title: "GitHub Repository...", action: #selector(openGitHub), keyEquivalent: "")) // 17
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))         // 18
        menu.addItem(NSMenuItem(title: "Open Status File", action: #selector(openStatusFile), keyEquivalent: "o")) // 19
        menu.addItem(NSMenuItem(title: "Reveal Status Folder", action: #selector(revealStatusFolder), keyEquivalent: "r")) // 20
        menu.addItem(NSMenuItem.separator())                                                         // 21
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesManually), keyEquivalent: "")) // 22
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "R")) // 23
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))       // 24
        statusItem.menu = menu
    }
```

- [ ] **Step 3: Update `updateMenuItemTitle(_:)` and updateMenu indices**

Since adding the menu item shifts the indices of later items:
* `updateMenuItemTitle` targets the "Check for Updates..." item. It was item `21`. Now it must be item `22`.
Update:
```swift
    private func updateMenuItemTitle(_ title: String) {
        guard let menu = statusItem.menu, menu.numberOfItems > 22 else { return }
        menu.item(at: 22)?.title = title
    }
```

* Update `updateMenu()` to target indices correctly and apply dynamic header metadata:
```swift
        // Update header to reflect combined state
        let agActive = currentAntigravitySnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
        let baseHeaderTitle: String
        if agActive && status != "idle" {
            baseHeaderTitle = "Codex + AGY"
        } else if agActive {
            baseHeaderTitle = "AGY Running"
        } else {
            baseHeaderTitle = "Codex Menu Bar"
        }
        
        let headerTitle = "\(baseHeaderTitle) v\(currentVersion) (\(buildDate)) by choihunchul"
        menu.item(at: 0)?.title = headerTitle

        if let summaryItem = menu.item(at: 2) {
            summaryItem.view = usageSummaryView
        }
        
        // Update menu items below summary:
        menu.item(at: 3)?.title = "Codex Status: \(completionText)"
        menu.item(at: 4)?.title = "Detail: \(detail)"
        menu.item(at: 5)?.title = "Source: \(effectiveSource)"
        menu.item(at: 6)?.title = "Last Activity: \(activity)"
        menu.item(at: 7)?.title = "Updated: \(updated)"
        menu.item(at: 9)?.title = "5-hour limit: \(limitDetailText(currentLimitState.primary, fallback: settings.fiveHourLimitText))"
        menu.item(at: 10)?.title = "Weekly limit: \(limitDetailText(currentLimitState.secondary, fallback: settings.weeklyLimitText))"
        menu.item(at: 11)?.title = "Limit source: \(currentLimitState.source)"
```

- [ ] **Step 4: Verify local compilation**

Run: `swift build`
Expected: Compilation completes with no errors.

- [ ] **Step 5: Commit task 2**

```bash
git add Sources/CodexMenuBar/main.swift
git commit -m "feat: display version, build date, author and integrate GitHub links"
```

---

### Task 3: Local Installation & Verification

**Files:**
- Run: [install-app.mjs](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/scripts/install-app.mjs)

- [ ] **Step 1: Install and launch local build**

Run: `node scripts/install-app.mjs 1.0.5`
Expected: Success! CodexMenuBar installed and registered to start on login, and application launches.

- [ ] **Step 2: Verify Menu Title**

Open the status item and verify the top item displays:
`Codex Menu Bar v1.0.5 (2026-06-05) by choihunchul`

- [ ] **Step 3: Verify Actions**

* Click the top menu header item. Verify the browser opens to `https://github.com/hunchulchoi/codex-menu-bar`.
* Open the menu again, click `GitHub Repository...`. Verify the browser opens to the same URL.
