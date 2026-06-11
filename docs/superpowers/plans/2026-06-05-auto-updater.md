# Codex Menu Bar Auto-Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a self-update checker and automatic installer in the macOS companion app that checks GitHub Releases for new updates, alerts the user, downloads the `.dmg`, and auto-installs it. Users can configure this in Settings, with the setting defaulting to enabled.

**Architecture:** 
1. Add an optional `autoUpdateEnabled` property to `AppSettings` (defaulting to `true` for backward compatibility).
2. Update the Settings window UI (adjust size to 420x380) to include a checkbox for "Auto check for updates".
3. Add a "Check for Updates..." menu item to `NSMenu`.
4. Periodic background check (every 12 hours) only if `autoUpdateEnabled` is `true`. Manual check is always available.
5. Download the latest `.dmg` using `URLSession` if an update is approved.
6. Launch a detached shell script to detach/mount/copy/unmount/relaunch the new `.app` bundle, then terminate the running process.

**Tech Stack:** Swift, AppKit, Foundation (`URLSession`, `Process`), GitHub Releases API.

---

### Task 1: Add Auto-Updater and Settings UI to `main.swift`

**Files:**
- Modify: [main.swift](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/Sources/CodexMenuBar/main.swift)

- [ ] **Step 1: Update `AppSettings` struct definition**
  Modify the `AppSettings` struct at the top of `main.swift` to add `autoUpdateEnabled` and default it:
  ```swift
  struct AppSettings: Codable {
      var autoWatchEnabled: Bool
      var antigravityWatchEnabled: Bool
      var activeWindowSeconds: TimeInterval
      var pollIntervalSeconds: TimeInterval
      var weeklyLimitText: String?
      var fiveHourLimitText: String?
      var autoUpdateEnabled: Bool? // Backward compatibility

      static func defaults() -> AppSettings {
          AppSettings(
              autoWatchEnabled: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_AUTO_WATCH"] != "0",
              antigravityWatchEnabled: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_AGY_WATCH"] != "0",
              activeWindowSeconds: envTimeInterval("CODEX_MENU_BAR_ACTIVE_WINDOW_SECONDS", defaultValue: 4, minimum: 1),
              pollIntervalSeconds: envTimeInterval("CODEX_MENU_BAR_POLL_INTERVAL_SECONDS", defaultValue: 0.8, minimum: 0.25),
              weeklyLimitText: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_WEEKLY_LIMIT"],
              fiveHourLimitText: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_FIVE_HOUR_LIMIT"],
              autoUpdateEnabled: true
          )
      }

      func sanitized() -> AppSettings {
          AppSettings(
              autoWatchEnabled: autoWatchEnabled,
              antigravityWatchEnabled: antigravityWatchEnabled,
              activeWindowSeconds: max(1, activeWindowSeconds),
              pollIntervalSeconds: max(0.25, pollIntervalSeconds),
              weeklyLimitText: cleanText(weeklyLimitText),
              fiveHourLimitText: cleanText(fiveHourLimitText),
              autoUpdateEnabled: autoUpdateEnabled ?? true
          )
      }
      // ...
  ```

- [ ] **Step 2: Add state variables and models to `CodexMenuBarApp`**
  Add these structures at file level or inside `main.swift`:
  ```swift
  private struct GitHubRelease: Decodable {
      let tag_name: String
      let assets: [GitHubAsset]
  }

  private struct GitHubAsset: Decodable {
      let name: String
      let browser_download_url: String
  }
  ```
  Add these properties inside `CodexMenuBarApp`:
  ```swift
      private var isCheckingForUpdates = false
      private var isDownloadingUpdate = false
      private var availableUpdateVersion: String?
      private var availableUpdateURL: URL?
      private var updateCheckTimer: Timer?
      private var autoUpdateCheckbox: NSButton?
  ```

- [ ] **Step 3: Modify `configureMenu()`**
  Update `configureMenu()` to add the update checker option (index `21`):
  ```swift
          menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))         // 17
          menu.addItem(NSMenuItem(title: "Open Status File", action: #selector(openStatusFile), keyEquivalent: "o")) // 18
          menu.addItem(NSMenuItem(title: "Reveal Status Folder", action: #selector(revealStatusFolder), keyEquivalent: "r")) // 19
          menu.addItem(NSMenuItem.separator())                                                         // 20
          menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesManually), keyEquivalent: "")) // 21
          menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "R")) // 22
          menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))       // 23
          statusItem.menu = menu
  ```

- [ ] **Step 4: Update Settings Window UI and Bindings**
  Update `openSettings()`, `saveSettingsFromWindow()`, and `resetSettingsWindow()` to include the auto-update checkbox and adjust window height to `380`:
  ```swift
      @objc private func openSettings() {
          if let settingsWindow {
              settingsWindow.makeKeyAndOrderFront(nil)
              NSApp.activate(ignoringOtherApps: true)
              return
          }

          let window = NSWindow(
              contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
              styleMask: [.titled, .closable],
              backing: .buffered,
              defer: false
          )
          window.title = "Codex Menu Bar Settings"
          window.isReleasedWhenClosed = false
          window.center()

          let view = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 420, height: 380))

          let checkbox = NSButton(checkboxWithTitle: "Auto watch Codex activity", target: nil, action: nil)
          checkbox.frame = NSRect(x: 24, y: 326, width: 280, height: 24)
          checkbox.state = settings.autoWatchEnabled ? .on : .off
          view.addSubview(checkbox)
          autoWatchCheckbox = checkbox

          let agCheckbox = NSButton(checkboxWithTitle: "Auto watch Antigravity activity", target: nil, action: nil)
          agCheckbox.frame = NSRect(x: 24, y: 296, width: 280, height: 24)
          agCheckbox.state = settings.antigravityWatchEnabled ? .on : .off
          view.addSubview(agCheckbox)
          agWatchCheckbox = agCheckbox

          let updateCheckbox = NSButton(checkboxWithTitle: "Auto check for updates", target: nil, action: nil)
          updateCheckbox.frame = NSRect(x: 24, y: 266, width: 280, height: 24)
          updateCheckbox.state = (settings.autoUpdateEnabled ?? true) ? .on : .off
          view.addSubview(updateCheckbox)
          autoUpdateCheckbox = updateCheckbox

          let activeLabel = NSTextField(labelWithString: "Active window seconds")
          activeLabel.frame = NSRect(x: 24, y: 218, width: 170, height: 20)
          view.addSubview(activeLabel)

          let activeField = NSTextField(string: formatSeconds(settings.activeWindowSeconds))
          activeField.frame = NSRect(x: 260, y: 214, width: 110, height: 26)
          activeField.alignment = .right
          view.addSubview(activeField)
          activeWindowField = activeField

          let pollLabel = NSTextField(labelWithString: "Poll interval seconds")
          pollLabel.frame = NSRect(x: 24, y: 180, width: 170, height: 20)
          view.addSubview(pollLabel)

          let pollField = NSTextField(string: formatSeconds(settings.pollIntervalSeconds))
          pollField.frame = NSRect(x: 260, y: 176, width: 110, height: 26)
          pollField.alignment = .right
          view.addSubview(pollField)
          pollIntervalField = pollField

          let weeklyLabel = NSTextField(labelWithString: "Weekly limit")
          weeklyLabel.frame = NSRect(x: 24, y: 140, width: 170, height: 20)
          view.addSubview(weeklyLabel)

          let weeklyField = NSTextField(string: settings.weeklyLimitText ?? "")
          weeklyField.placeholderString = "ex: 42% used, resets Mon"
          weeklyField.frame = NSRect(x: 150, y: 136, width: 220, height: 26)
          view.addSubview(weeklyField)
          weeklyLimitField = weeklyField

          let fiveHourLabel = NSTextField(labelWithString: "5-hour limit")
          fiveHourLabel.frame = NSRect(x: 24, y: 102, width: 170, height: 20)
          view.addSubview(fiveHourLabel)

          let fiveHourField = NSTextField(string: settings.fiveHourLimitText ?? "")
          fiveHourField.placeholderString = "ex: 12 left, resets 17:30"
          fiveHourField.frame = NSRect(x: 150, y: 98, width: 220, height: 26)
          view.addSubview(fiveHourField)
          fiveHourLimitField = fiveHourField

          let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettingsFromWindow))
          saveButton.bezelStyle = .rounded
          saveButton.frame = NSRect(x: 306, y: 24, width: 80, height: 32)
          view.addSubview(saveButton)

          let resetButton = NSButton(title: "Defaults", target: self, action: #selector(resetSettingsWindow))
          resetButton.bezelStyle = .rounded
          resetButton.frame = NSRect(x: 210, y: 24, width: 86, height: 32)
          view.addSubview(resetButton)

          window.contentView = view
          window.delegate = self
          settingsWindow = window
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
      }
  ```
  And updates to `saveSettingsFromWindow()` and `resetSettingsWindow()`:
  ```swift
      @objc private func saveSettingsFromWindow() {
          guard
              let activeRaw = activeWindowField?.stringValue,
              let pollRaw = pollIntervalField?.stringValue,
              let active = TimeInterval(activeRaw),
              let poll = TimeInterval(pollRaw)
          else {
              NSSound.beep()
              return
          }

          settings = AppSettings(
              autoWatchEnabled: autoWatchCheckbox?.state == .on,
              antigravityWatchEnabled: agWatchCheckbox?.state == .on,
              activeWindowSeconds: active,
              pollIntervalSeconds: poll,
              weeklyLimitText: weeklyLimitField?.stringValue,
              fiveHourLimitText: fiveHourLimitField?.stringValue,
              autoUpdateEnabled: autoUpdateCheckbox?.state == .on
          ).sanitized()
          writeSettings()
          scheduleTimer()
          refresh()
          settingsWindow?.close()
      }

      @objc private func resetSettingsWindow() {
          settings = AppSettings.defaults()
          autoWatchCheckbox?.state = settings.autoWatchEnabled ? .on : .off
          agWatchCheckbox?.state = settings.antigravityWatchEnabled ? .on : .off
          autoUpdateCheckbox?.state = (settings.autoUpdateEnabled ?? true) ? .on : .off
          activeWindowField?.stringValue = formatSeconds(settings.activeWindowSeconds)
          pollIntervalField?.stringValue = formatSeconds(settings.pollIntervalSeconds)
          weeklyLimitField?.stringValue = settings.weeklyLimitText ?? ""
          fiveHourLimitField?.stringValue = settings.fiveHourLimitText ?? ""
      }
  ```

- [ ] **Step 5: Implement update check and install logic**
  Add these logic methods:
  ```swift
      @objc private func checkForUpdatesManually() {
          checkForUpdates(isUserInitiated: true)
      }

      private func checkForUpdates(isUserInitiated: Bool) {
          // If in background, only check if auto-update setting is enabled
          if !isUserInitiated && !(settings.autoUpdateEnabled ?? true) {
              return
          }

          guard !isCheckingForUpdates && !isDownloadingUpdate else { return }
          isCheckingForUpdates = true

          if isUserInitiated {
              updateMenuItemTitle("Checking for Updates...")
          }

          let url = URL(string: "https://api.github.com/repos/choihunchul/codex-menu-bar/releases/latest")!
          var request = URLRequest(url: url)
          request.setValue("CodexMenuBar", forHTTPHeaderField: "User-Agent")
          request.timeoutInterval = 10.0

          URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
              guard let self else { return }
              DispatchQueue.main.async {
                  self.isCheckingForUpdates = false
                  
                  guard let data, error == nil,
                        let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                      self.updateMenuItemTitle("Check for Updates...")
                      if isUserInitiated {
                          self.showAlert(title: "Connection Failed", message: "Could not connect to GitHub to check for updates.")
                      }
                      return
                  }

                  let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                  let tagVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name

                  if tagVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                      if let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                         let downloadURL = URL(string: dmgAsset.browser_download_url) {
                          self.availableUpdateVersion = release.tag_name
                          self.availableUpdateURL = downloadURL
                          self.updateMenuItemTitle("Update to \(release.tag_name) (Available)")
                          
                          if isUserInitiated {
                              self.promptToUpdate(version: release.tag_name, url: downloadURL)
                          }
                          return
                      }
                  }

                  self.updateMenuItemTitle("Check for Updates...")
                  if isUserInitiated {
                      self.showAlert(title: "Up to Date", message: "You are running the latest version (\(currentVersion)).")
                  }
              }
          }.resume()
      }

      private func updateMenuItemTitle(_ title: String) {
          guard let menu = statusItem.menu, menu.numberOfItems > 21 else { return }
          menu.item(at: 21)?.title = title
      }

      private func showAlert(title: String, message: String) {
          let alert = NSAlert()
          alert.messageText = title
          alert.informativeText = message
          alert.alertStyle = .informational
          alert.runModal()
      }

      private func promptToUpdate(version: String, url: URL) {
          let alert = NSAlert()
          alert.messageText = "Update Available"
          alert.informativeText = "A new version (\(version)) is available. Would you like to download and install it now?"
          alert.alertStyle = .informational
          alert.addButton(withTitle: "Download & Install")
          alert.addButton(withTitle: "Cancel")
          
          if alert.runModal() == .alertFirstButtonReturn {
              downloadAndInstallUpdate(url: url)
          }
      }

      private func downloadAndInstallUpdate(url: URL) {
          isDownloadingUpdate = true
          updateMenuItemTitle("Downloading Update...")

          URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
              guard let self else { return }
              DispatchQueue.main.async {
                  self.isDownloadingUpdate = false
                  self.updateMenuItemTitle("Check for Updates...")

                  guard let tempURL, error == nil else {
                      self.showAlert(title: "Download Failed", message: "Failed to download the update package.")
                      return
                  }

                  let fileManager = FileManager.default
                  let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                  let destinationURL = cacheDir.appendingPathComponent("CodexMenuBarUpdate.dmg")
                  
                  try? fileManager.removeItem(at: destinationURL)
                  do {
                      try fileManager.moveItem(at: tempURL, to: destinationURL)
                      self.installUpdate(dmgURL: destinationURL)
                  } catch {
                      self.showAlert(title: "Installation Failed", message: "Failed to prepare the downloaded update for installation.")
                  }
              }
          }.resume()
      }

      private func installUpdate(dmgURL: URL) {
          let targetAppPath = Bundle.main.bundlePath
          let dmgPath = dmgURL.path
          let mountPoint = "/tmp/CodexMenuBarMount"
          
          let installScript = """
          (
            sleep 1.0
            hdiutil detach -force "\(mountPoint)" 2>/dev/null || true
            hdiutil attach -nobrowse -readonly -mountpoint "\(mountPoint)" "\(dmgPath)"
            if [ -d "\(mountPoint)/CodexMenuBar.app" ]; then
              rm -rf "\(targetAppPath)"
              cp -R "\(mountPoint)/CodexMenuBar.app" "\(targetAppPath)"
            fi
            hdiutil detach "\(mountPoint)"
            rm -f "\(dmgPath)"
            open "\(targetAppPath)"
          ) &
          """
          
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/bin/sh")
          process.arguments = ["-c", installScript]
          
          do {
              try process.run()
              releaseSingleInstanceLock()
              NSApp.terminate(nil)
          } catch {
              showAlert(title: "Update Failed", message: "Could not launch the auto-updater installer script.")
          }
      }
  ```

- [ ] **Step 6: Schedule background checks**
  In `applicationDidFinishLaunching()`:
  ```swift
          // Schedule background update check 5 seconds after launch
          DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
              self?.checkForUpdates(isUserInitiated: false)
          }
          // Schedule background update check every 12 hours
          updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
              self?.checkForUpdates(isUserInitiated: false)
          }
  ```

- [ ] **Step 7: Clean up timer on exit**
  In `applicationWillTerminate()`:
  ```swift
      func applicationWillTerminate(_ notification: Notification) {
          updateCheckTimer?.invalidate()
          NSWorkspace.shared.notificationCenter.removeObserver(self)
          releaseSingleInstanceLock()
      }
  ```

- [ ] **Step 8: Build locally and test compile**
  Run: `swift build`
  Expected: Compile completes with no syntax errors.

- [ ] **Step 9: Commit changes**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "feat: implement automatic update check and self-installer with settings UI toggle"
  ```

---

## Verification Plan

### Automated Tests
* None.

### Manual Verification
* Build and launch the app.
* Click settings and verify that the "Auto check for updates" checkbox is present and checked by default.
* Toggle settings and click "Save", verify that settings are written to `~/.codex-menu-bar/settings.json` and contain `"autoUpdateEnabled": true/false`.
* Verify that clicking "Check for Updates..." manually still functions as expected.
