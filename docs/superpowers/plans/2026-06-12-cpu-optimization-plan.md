# CPU and WindowServer Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optimize CPU and WindowServer usage of CodexMenuBar by targeting specific directories, moving I/O to background tasks, throttling updates, and skipping redrawing when the visual state has not changed.

**Architecture:** Avoid recursive searches, use background queues for I/O, apply a 3-second throttle on disk operations, and check visual state changes before resetting the menu bar button.

**Tech Stack:** Swift, AppKit, GCD (Grand Central Dispatch)

---

### Task 1: Optimize Cursor Logs Directory Scan

**Files:**
- Modify: `Sources/CodexMenuBar/CursorActivityReader.swift`

- [ ] **Step 1: Write/Update CursorActivityReader tests to verify activity reading works**
  Verify that we have tests for `CursorActivityReader` and run them.
  Run: `swift test`

- [ ] **Step 2: Replace recursive enumeration in CursorActivityReader**
  Replace `findLatestAgentActivityDate()` in `Sources/CodexMenuBar/CursorActivityReader.swift` with the targeted shallow check algorithm.
  
  Replace lines 54-122 with:
  ```swift
      private func findLatestAgentActivityDate() -> Date? {
          guard fileManager.fileExists(atPath: logsURL.path) else { return nil }
          
          // Shallow scan logs directory to find session subdirectories
          guard let contents = try? fileManager.contentsOfDirectory(
              at: logsURL,
              includingPropertiesForKeys: [.contentModificationDateKey],
              options: [.skipsHiddenFiles]
          ) else {
              return nil
          }
          
          let now = Date()
          // Filter to directories modified in the last 1 hour
          var dirsToScan = contents
              .compactMap { url -> (URL, Date)? in
                  guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                        let modDate = values.contentModificationDate else {
                      return nil
                  }
                  return (url, modDate)
              }
              .filter { _, modDate in
                  now.timeIntervalSince(modDate) <= 3600.0
              }
              .sorted { $0.1 > $1.1 }
              .map { $0.0 }
          
          // Fallback to the single most recently modified directory if none modified in the last hour
          if dirsToScan.isEmpty {
              if let latestDir = contents
                  .compactMap({ url -> (URL, Date)? in
                      guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                            let modDate = values.contentModificationDate else {
                          return nil
                      }
                      return (url, modDate)
                  })
                  .sorted(by: { $0.1 > $1.1 })
                  .first?.0 {
                  dirsToScan = [latestDir]
              }
          }
          
          var latestDate: Date? = nil
          for dir in dirsToScan {
              // Shallow scan the session directory to find window subdirectories
              guard let windowContents = try? fileManager.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
                  continue
              }
              
              for windowURL in windowContents {
                  guard windowURL.lastPathComponent.hasPrefix("window") else {
                      continue
                  }
                  
                  let agentExecURL = windowURL.appendingPathComponent("exthost/anysphere.cursor-agent-exec")
                  var isDir: ObjCBool = false
                  guard fileManager.fileExists(atPath: agentExecURL.path, isDirectory: &isDir), isDir.boolValue else {
                      continue
                  }
                  
                  // Shallow scan the agent exec directory
                  guard let files = try? fileManager.contentsOfDirectory(
                      at: agentExecURL,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                      continue
                  }
                  
                  for fileURL in files {
                      if fileURL.lastPathComponent.hasPrefix("Cursor Agent Exec") {
                          if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                             let modDate = values.contentModificationDate {
                              if latestDate == nil || modDate > latestDate! {
                                  latestDate = modDate
                              }
                          }
                      }
                  }
              }
          }
          
          return latestDate
      }
  ```

- [ ] **Step 3: Run the Swift tests to verify the optimized traversal passes**
  Run: `swift test`
  Expected: PASS

- [ ] **Step 4: Commit the change**
  ```bash
  git add Sources/CodexMenuBar/CursorActivityReader.swift
  git commit -m "perf: optimize cursor log scan to use targeted shallow directory reads"
  ```

---

### Task 2: Implement File Mod-Date Caching for Status Payload

**Files:**
- Modify: `Sources/CodexMenuBar/main.swift`

- [ ] **Step 1: Add caching variables to CodexMenuBarApp in main.swift**
  Add these private variables to `CodexMenuBarApp`:
  ```swift
      private var cachedPayloadDate: Date?
      private var cachedPayload: StatusPayload?
  ```

- [ ] **Step 2: Update readPayload() in main.swift**
  Replace `readPayload()` with:
  ```swift
      private func readPayload() -> StatusPayload? {
          guard let values = try? statusFile.resourceValues(forKeys: [.contentModificationDateKey]),
                let modDate = values.contentModificationDate else {
              cachedPayloadDate = nil
              cachedPayload = nil
              return nil
          }
          
          if let cachedDate = cachedPayloadDate, let cached = cachedPayload, modDate == cachedDate {
              return cached
          }
          
          guard let data = try? Data(contentsOf: statusFile),
                let decoded = try? decoder.decode(StatusPayload.self, from: data) else {
              return nil
          }
          
          cachedPayloadDate = modDate
          cachedPayload = decoded
          return decoded
      }
  ```

- [ ] **Step 3: Verify build**
  Run: `swift build`
  Expected: Build successfully

- [ ] **Step 4: Commit the change**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "perf: cache status.json reading using file modification date"
  ```

---

### Task 3: Asynchronous Background checking & Throttling (3.0s)

**Files:**
- Modify: `Sources/CodexMenuBar/main.swift`

- [ ] **Step 1: Expose getLogsModificationDate() in LimitStateReader**
  Change `private func getLogsModificationDate()` to `func getLogsModificationDate()` (internal) in `LimitStateReader` within `Sources/CodexMenuBar/main.swift`.

- [ ] **Step 2: Add throttling and background-state variables to CodexMenuBarApp**
  Add these variables to `CodexMenuBarApp`:
  ```swift
      // Throttling tracking
      private var lastAntigravityCheck = Date.distantPast
      private var lastCursorCheck = Date.distantPast
      private var lastRuntimeSignalCheck = Date.distantPast
      private var lastRuntimeSignalModDate: Date?
      
      // Async state locks
      private var isRefreshingAntigravity = false
      private var isRefreshingCursorSnapshot = false
      private var isRefreshingRuntimeSignal = false
      
      // Cached background state
      private var currentRuntimeSignalSnapshot: CodexRuntimeSignalSnapshot?
  ```

- [ ] **Step 3: Make snapshot updates asynchronous and throttled**
  Modify `refreshAntigravitySnapshot()`, `refreshCursorSnapshot()`, and `refresh()` in `main.swift`.
  
  Replace `refreshAntigravitySnapshot()`:
  ```swift
      private func refreshAntigravitySnapshot() {
          guard settings.antigravityWatchEnabled else {
              if currentAntigravitySnapshot.lastActivityDate != nil {
                  currentAntigravitySnapshot = .empty
                  latestAntigravityActivity = nil
              }
              return
          }
          
          let now = Date()
          guard now.timeIntervalSince(lastAntigravityCheck) >= 3.0 else {
              return
          }
          guard !isRefreshingAntigravity else { return }
          isRefreshingAntigravity = true
          lastAntigravityCheck = now
          
          let reader = antigravityActivityReader
          let activeWindow = settings.activeWindowSeconds
          
          DispatchQueue.global(qos: .background).async {
              let snapshot = reader.readSnapshot(activeWindowSeconds: activeWindow)
              Task { @MainActor [weak self] in
                  guard let self else { return }
                  self.currentAntigravitySnapshot = snapshot
                  self.latestAntigravityActivity = snapshot.lastActivityDate
                  self.isRefreshingAntigravity = false
                  self.manualPayload = self.readPayload()
                  self.currentPayload = self.resolvePayload(self.manualPayload)
                  self.updateMenuBarIcon()
                  self.updateMenu()
              }
          }
      }
  ```
  
  Replace `refreshCursorSnapshot()`:
  ```swift
      private func refreshCursorSnapshot() {
          guard settings.cursorWatchEnabled else {
              if currentCursorSnapshot.lastUserActivityDate != nil {
                  currentCursorSnapshot = .empty
                  latestCursorActivity = nil
              }
              return
          }
          
          let now = Date()
          guard now.timeIntervalSince(lastCursorCheck) >= 3.0 else {
              return
          }
          guard !isRefreshingCursorSnapshot else { return }
          isRefreshingCursorSnapshot = true
          lastCursorCheck = now
          
          let reader = cursorActivityReader
          let activeWindow = settings.activeWindowSeconds
          
          DispatchQueue.global(qos: .background).async {
              let snapshot = reader.readSnapshot(activeWindowSeconds: activeWindow)
              Task { @MainActor [weak self] in
                  guard let self else { return }
                  self.currentCursorSnapshot = snapshot
                  self.latestCursorActivity = [snapshot.lastUserActivityDate, snapshot.lastAgentActivityDate].compactMap { $0 }.max()
                  self.isRefreshingCursorSnapshot = false
                  self.manualPayload = self.readPayload()
                  self.currentPayload = self.resolvePayload(self.manualPayload)
                  self.updateMenuBarIcon()
                  self.updateMenu()
              }
          }
      }
  ```

  Add a new method `refreshRuntimeSignalSnapshot()` to `CodexMenuBarApp`:
  ```swift
      private func refreshRuntimeSignalSnapshot() {
          guard settings.autoWatchEnabled else {
              currentRuntimeSignalSnapshot = nil
              return
          }
          
          let now = Date()
          let modDate = limitStateReader.getLogsModificationDate()
          
          guard modDate != lastRuntimeSignalModDate else {
              return
          }
          
          guard now.timeIntervalSince(lastRuntimeSignalCheck) >= 3.0 else {
              return
          }
          
          guard !isRefreshingRuntimeSignal else { return }
          isRefreshingRuntimeSignal = true
          lastRuntimeSignalCheck = now
          
          let reader = limitStateReader
          DispatchQueue.global(qos: .background).async {
              let snapshot = reader.readRuntimeSignalSnapshot()
              Task { @MainActor [weak self] in
                  guard let self else { return }
                  self.currentRuntimeSignalSnapshot = snapshot
                  self.lastRuntimeSignalModDate = modDate
                  self.isRefreshingRuntimeSignal = false
                  self.manualPayload = self.readPayload()
                  self.currentPayload = self.resolvePayload(self.manualPayload)
                  self.updateMenuBarIcon()
                  self.updateMenu()
              }
          }
      }
  ```

  Update `resolvePayload()` in `main.swift` to use the cached `currentRuntimeSignalSnapshot`:
  Replace:
  ```swift
          if settings.autoWatchEnabled {
              if let runtimeSnapshot = limitStateReader.readRuntimeSignalSnapshot(),
  ```
  With:
  ```swift
          if settings.autoWatchEnabled {
              if let runtimeSnapshot = currentRuntimeSignalSnapshot,
  ```

  Update `refresh()` to call the new methods:
  ```swift
      private func refresh() {
          manualPayload = readPayload()
          currentPayload = resolvePayload(manualPayload)
          refreshLimitStateIfNeeded()
          refreshAntigravitySnapshot()
          refreshCursorSnapshot()
          refreshRuntimeSignalSnapshot()
          refreshCursorLimitStateIfNeeded()
          frameIndex = (frameIndex + 1) % frames.count
          updateMenuBarIcon()
          updateMenu()
      }
  ```

- [ ] **Step 4: Verify build and tests**
  Run: `swift test`
  Expected: Build successfully and tests pass.

- [ ] **Step 5: Commit the change**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "perf: run scans asynchronously on background queue with 3s throttling"
  ```

---

### Task 4: Prevent Unnecessary Drawing (WindowServer Optimization)

**Files:**
- Modify: `Sources/CodexMenuBar/main.swift`

- [ ] **Step 1: Add last drawn state variables to CodexMenuBarApp**
  Add these state tracking variables to `CodexMenuBarApp`:
  ```swift
      // Last drawn state cache
      private var lastDrawnStatus: String?
      private var lastDrawnIsRecentlyCompleted: Bool?
      private var lastDrawnFrameIndex: Int?
      private var lastDrawnFiveHourUsagePercent: Double?
      private var lastDrawnWeeklyUsagePercent: Double?
      private var lastDrawnAgActive: Bool?
      private var lastDrawnAgStatus: String?
      private var lastDrawnCursorActive: Bool?
      private var lastDrawnCursorStatus: String?
      private var lastDrawnHasUpdate: Bool?
  ```

- [ ] **Step 2: Add dirty-state checking in updateMenuBarIcon()**
  Modify `updateMenuBarIcon()` to return early if none of the parameters changed.
  
  Replace:
  ```swift
      private func updateMenuBarIcon() {
          let status = currentPayload?.status?.lowercased() ?? "idle"
          let now = Date()
          let agActive = settings.antigravityWatchEnabled
              && currentAntigravitySnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
          let agStatus = settings.antigravityWatchEnabled ? currentPayload?.antigravity?.status : nil
          let cursorActive = settings.cursorWatchEnabled
              && currentCursorSnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
  
          // AGY & Cursor 상태를 렌더러에 전달 → 이미지 안에 보라색/청록색 점으로 표시
          let iconImage = menuIconRenderer.image(
              status: status,
              isRecentlyCompleted: isRecentlyCompleted(),
              frameIndex: frameIndex,
              fiveHourUsagePercent: currentLimitState.primary?.usedPercent,
              weeklyUsagePercent: currentLimitState.secondary?.usedPercent,
              agActive: agActive,
              agStatus: agStatus,
              cursorActive: cursorActive,
              cursorStatus: cursorActive ? "running" : nil,
              hasUpdate: availableUpdateVersion != nil
          )
          if let button = statusItem.button {
              button.image = iconImage
              button.imagePosition = .imageOnly
              button.title = ""
              button.attributedTitle = NSAttributedString(string: "")
              button.toolTip = tooltipText(for: status, agActive: agActive)
          }
          updateStatusPopover(for: status)
          scheduleAnimationTimerIfNeeded()
      }
  ```
  
  With:
  ```swift
      private func updateMenuBarIcon() {
          let status = currentPayload?.status?.lowercased() ?? "idle"
          let now = Date()
          let agActive = settings.antigravityWatchEnabled
              && currentAntigravitySnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
          let agStatus = settings.antigravityWatchEnabled ? currentPayload?.antigravity?.status : nil
          let cursorActive = settings.cursorWatchEnabled
              && currentCursorSnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
          let isCompleted = isRecentlyCompleted()
          let fiveHourPercent = currentLimitState.primary?.usedPercent
          let weeklyPercent = currentLimitState.secondary?.usedPercent
          let cursorStatus = cursorActive ? "running" : nil
          let hasUpdate = availableUpdateVersion != nil
  
          // Check if visual state has changed
          if lastDrawnStatus == status,
             lastDrawnIsRecentlyCompleted == isCompleted,
             lastDrawnFrameIndex == frameIndex,
             lastDrawnFiveHourUsagePercent == fiveHourPercent,
             lastDrawnWeeklyUsagePercent == weeklyPercent,
             lastDrawnAgActive == agActive,
             lastDrawnAgStatus == agStatus,
             lastDrawnCursorActive == cursorActive,
             lastDrawnCursorStatus == cursorStatus,
             lastDrawnHasUpdate == hasUpdate {
              // No change in visual state, skip redraw!
              return
          }
          
          // Cache the new visual state
          lastDrawnStatus = status
          lastDrawnIsRecentlyCompleted = isCompleted
          lastDrawnFrameIndex = frameIndex
          lastDrawnFiveHourUsagePercent = fiveHourPercent
          lastDrawnWeeklyUsagePercent = weeklyPercent
          lastDrawnAgActive = agActive
          lastDrawnAgStatus = agStatus
          lastDrawnCursorActive = cursorActive
          lastDrawnCursorStatus = cursorStatus
          lastDrawnHasUpdate = hasUpdate
  
          let iconImage = menuIconRenderer.image(
              status: status,
              isRecentlyCompleted: isCompleted,
              frameIndex: frameIndex,
              fiveHourUsagePercent: fiveHourPercent,
              weeklyUsagePercent: weeklyPercent,
              agActive: agActive,
              agStatus: agStatus,
              cursorActive: cursorActive,
              cursorStatus: cursorStatus,
              hasUpdate: hasUpdate
          )
          if let button = statusItem.button {
              button.image = iconImage
              button.imagePosition = .imageOnly
              button.title = ""
              button.attributedTitle = NSAttributedString(string: "")
              button.toolTip = tooltipText(for: status, agActive: agActive)
          }
          updateStatusPopover(for: status)
          scheduleAnimationTimerIfNeeded()
      }
  ```

- [ ] **Step 3: Run build and verify correctness**
  Run: `swift build`
  Expected: Build successfully.

- [ ] **Step 4: Commit the change**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "perf: prevent unnecessary redrawing of menu bar icon if visual state is unchanged"
  ```
