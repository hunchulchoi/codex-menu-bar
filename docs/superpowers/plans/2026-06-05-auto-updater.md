# Codex Menu Bar Auto-Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a self-update checker and automatic installer in the macOS companion app that checks GitHub Releases for new updates, alerts the user, downloads the `.dmg`, and auto-installs it.

**Architecture:** 
1. Add a "Check for Updates..." menu item to `NSMenu`.
2. Periodic background check (every 12 hours) and manual check.
3. Compare local version with remote version via numeric comparison.
4. Download the latest `.dmg` using `URLSession` if an update is approved.
5. Launch a detached shell script to detach/mount/copy/unmount/relaunch the new `.app` bundle, then terminate the running process.

**Tech Stack:** Swift, AppKit, Foundation (`URLSession`, `Process`), GitHub Releases API.

---

### Task 1: Add Auto-Updater to `main.swift`

**Files:**
- Modify: [main.swift](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/Sources/CodexMenuBar/main.swift)

- [ ] **Step 1: Define GitHub Release models and helper state**
  Add the helper structs and properties to `CodexMenuBarApp`:
  ```swift
  // Place this at file scope (e.g., above or inside CodexMenuBarApp)
  private struct GitHubRelease: Decodable {
      let tag_name: String
      let assets: [GitHubAsset]
  }

  private struct GitHubAsset: Decodable {
      let name: String
      let browser_download_url: String
  }
  ```
  And add these properties to `CodexMenuBarApp`:
  ```swift
  private var isCheckingForUpdates = false
  private var isDownloadingUpdate = false
  private var availableUpdateVersion: String?
  private var availableUpdateURL: URL?
  private var updateCheckTimer: Timer?
  ```

- [ ] **Step 2: Add menu items in `configureMenu()`**
  Modify `configureMenu()` (around line 1578) to add the update item:
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

- [ ] **Step 3: Implement update check and install logic**
  Add the following helper methods to `CodexMenuBarApp`:
  ```swift
      @objc private func checkForUpdatesManually() {
          checkForUpdates(isUserInitiated: true)
      }

      private func checkForUpdates(isUserInitiated: Bool) {
          guard !isCheckingForUpdates && !isDownloadingUpdate else { return }
          isCheckingForUpdates = true

          if isUserInitiated {
              updateMenuItemTitle("Checking for Updates...")
          }

          let url = URL(string: "https://api.github.com/repos/hunchulchoi/codex-menu-bar/releases/latest")!
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
                      // Find DMG asset
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

                  // Copy to a stable path in cache/temp directory
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

- [ ] **Step 4: Schedule background checks**
  In `applicationDidFinishLaunching` (around line 1485):
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

- [ ] **Step 5: Clean up timer on exit**
  In `applicationWillTerminate()`:
  ```swift
      func applicationWillTerminate(_ notification: Notification) {
          updateCheckTimer?.invalidate()
          NSWorkspace.shared.notificationCenter.removeObserver(self)
          releaseSingleInstanceLock()
      }
  ```

- [ ] **Step 6: Build locally and test compile**
  Run: `swift build`
  Expected: Compile completes with no syntax errors.

- [ ] **Step 7: Commit changes**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "feat: implement automatic update check and self-installer"
  ```

---

## Verification Plan

### Automated Tests
* None.

### Manual Verification
* Build and launch the app.
* Click the menu bar and verify that the "Check for Updates..." menu item is present.
* Click "Check for Updates..." and verify it shows either "Up to Date" (if version matches) or "Update Available" (if we temporarily modify local version to `0.9.0`).
