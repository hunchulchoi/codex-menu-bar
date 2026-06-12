# Status Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce Codex Menu Bar status representation to strictly `running`, `idle`, and `update`.

**Architecture:** Simplify CodexStatusKind and CodexMenuBarIconKind to only represent running and idle. Map all intermediate states to idle at the source in transition hooks and normalizers. Remove completed, waiting, error, and approval states and their associated animations/popovers.

**Tech Stack:** Swift, AppKit, XCTest/Testing Library

---

### Task 1: Simplify CodexStatusTransitionHooks

**Files:**
- Modify: `Sources/CodexMenuBar/CodexStatusTransitionHooks.swift`
- Test: `Tests/CodexMenuBarTests/CodexStatusTransitionHooksTests.swift`

- [ ] **Step 1: Write/Update tests for CodexStatusTransitionHooks**
  Modify `Tests/CodexMenuBarTests/CodexStatusTransitionHooksTests.swift` to align with the simplified statuses.
  ```swift
  import Foundation
  import Testing
  @testable import CodexMenuBar

  @Suite("Codex status transition hooks")
  struct CodexStatusTransitionHooksTests {
      @Test("Completed status suppresses auto running briefly")
      func completedStatusSuppressesAutoRunningBriefly() {
          let hooks = CodexStatusTransitionHooks(completedCooldown: 10)
          let start = Date(timeIntervalSince1970: 1_715_866_800)

          #expect(hooks.recordResolvedStatus("running", at: start) == .onRunning)
          #expect(hooks.recordResolvedStatus("idle", at: start.addingTimeInterval(1)) == .onCompleted)

          #expect(hooks.shouldSuppressAutoActive(at: start.addingTimeInterval(5)))
          #expect(!hooks.shouldSuppressAutoActive(at: start.addingTimeInterval(11)))
      }

      @Test("Thinking and running command statuses expose the running hook")
      func thinkingAndRunningCommandExposeRunningHook() {
          let hooks = CodexStatusTransitionHooks(completedCooldown: 10)
          let start = Date(timeIntervalSince1970: 1_715_866_800)

          #expect(hooks.recordResolvedStatus("thinking", at: start) == .onRunning)
          #expect(hooks.recordResolvedStatus("running_command", at: start.addingTimeInterval(1)) == nil)
      }

      @Test("Latest runtime signal resolves to the newest meaningful status")
      func latestRuntimeSignalResolvesToNewestMeaningfulStatus() {
          let start = Date(timeIntervalSince1970: 1_715_866_800)
          let snapshot = CodexRuntimeSignalSnapshot(
              runningAt: start,
              approvalAt: start.addingTimeInterval(2),
              completedAt: start.addingTimeInterval(1),
              waitingAt: nil,
              messageAt: nil,
              errorAt: nil
          )

          #expect(codexResolvedRuntimeStatus(from: snapshot) == .idle)
      }

      @Test("Runtime signal parser recognizes output item events")
      func runtimeSignalParserRecognizesOutputItemEvents() {
          let reader = LimitStateReader(codexHome: URL(fileURLWithPath: "/tmp/codex-menu-bar-tests"))
          var snapshot = CodexRuntimeSignalSnapshot(
              runningAt: nil,
              approvalAt: nil,
              completedAt: nil,
              waitingAt: nil,
              messageAt: nil,
              errorAt: nil
          )
          let start = Date(timeIntervalSince1970: 1_715_866_800)

          reader.codexRecordRuntimeSignal(
              from: #"Received message {"type":"response.output_item.added","item":{"status":"in_progress"}}"#,
              at: start,
              into: &snapshot
          )
          reader.codexRecordRuntimeSignal(
              from: #"Received message {"type":"response.output_item.done","item":{"status":"completed"}}"#,
              at: start.addingTimeInterval(1),
              into: &snapshot
          )
          reader.codexRecordRuntimeSignal(
              from: #"Received message {"approval_required":true}"#,
              at: start.addingTimeInterval(2),
              into: &snapshot
          )

          #expect(snapshot.runningAt == start)
          #expect(snapshot.completedAt == start.addingTimeInterval(1))
          #expect(snapshot.approvalAt == start.addingTimeInterval(2))
          #expect(codexResolvedRuntimeStatus(from: snapshot) == .idle)
      }

      @Test("Runtime signal dates preserve nanosecond ordering")
      func runtimeSignalDatesPreserveNanosecondOrdering() {
          let running = codexLogDate(seconds: 1_779_027_986, nanoseconds: 789_105_000)
          let completed = codexLogDate(seconds: 1_779_027_986, nanoseconds: 793_344_000)
          let snapshot = CodexRuntimeSignalSnapshot(
              runningAt: running,
              approvalAt: nil,
              completedAt: completed,
              waitingAt: nil,
              messageAt: nil,
              errorAt: nil
          )

          #expect(completed > running)
          #expect(codexResolvedRuntimeStatus(from: snapshot) == .idle)
      }

      @Test("Codex app activation can acknowledge older attention statuses")
      func codexAppActivationCanAcknowledgeOlderAttentionStatuses() {
          let statusAt = Date(timeIntervalSince1970: 1_779_027_986)
          let acknowledgedAt = statusAt.addingTimeInterval(1)

          #expect(!codexMenuBarStatusCanBeAcknowledged(.completed))
          #expect(!codexMenuBarStatusCanBeAcknowledged(.idle))
          #expect(!codexMenuBarStatusCanBeAcknowledged(.running))
          #expect(codexMenuBarAttentionStatusIsAcknowledged(statusAt: statusAt, acknowledgedAt: acknowledgedAt))
          #expect(!codexMenuBarAttentionStatusIsAcknowledged(statusAt: acknowledgedAt, acknowledgedAt: statusAt))
      }

      @Test("Acknowledgement suppresses recent idle completion indicator")
      func acknowledgementSuppressesRecentIdleCompletionIndicator() {
          let referenceDate = Date(timeIntervalSince1970: 1_779_027_986)
          let acknowledgedAt = referenceDate.addingTimeInterval(1)
          let now = referenceDate.addingTimeInterval(10)

          #expect(!codexMenuBarShouldShowRecentCompletion(
              status: .idle,
              referenceDate: referenceDate,
              acknowledgedAt: nil,
              now: now
          ))
      }

      @Test("Codex app detection excludes the menu bar helper")
      func codexAppDetectionExcludesTheMenuBarHelper() {
          #expect(codexMenuBarIsCodexApplication(bundleIdentifier: "com.openai.codex", localizedName: "Codex"))
          #expect(!codexMenuBarIsCodexApplication(bundleIdentifier: "dev.local.CodexMenuBar", localizedName: "Codex Menu Bar"))
      }
  }
  ```

- [ ] **Step 2: Run tests to verify failure**
  Run: `swift test`
  Expected: Failures in transition hooks tests due to missing case definitions and types in production code.

- [ ] **Step 3: Simplify CodexStatusTransitionHooks production code**
  Modify `Sources/CodexMenuBar/CodexStatusTransitionHooks.swift` to reduce cases to `running` and `idle`.
  ```swift
  import Foundation

  struct CodexRuntimeSignalSnapshot {
      var runningAt: Date?
      var approvalAt: Date?
      var completedAt: Date?
      var waitingAt: Date?
      var messageAt: Date?
      var errorAt: Date?
  }

  func codexNormalizedStatus(_ status: String) -> String {
      let normalized = status
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
          .replacingOccurrences(of: "-", with: "_")

      if normalized.contains("thinking")
          || normalized.contains("running_command")
          || normalized.contains("running command")
          || normalized.contains("working")
          || normalized == "running"
      {
          return "running"
      }

      return "idle"
  }

  func codexResolvedRuntimeStatus(from snapshot: CodexRuntimeSignalSnapshot) -> CodexStatusKind? {
      let candidates: [(CodexStatusKind, Date)] = [
          snapshot.runningAt.map { (.running, $0) },
          snapshot.approvalAt.map { (.idle, $0) },
          snapshot.completedAt.map { (.idle, $0) },
          snapshot.waitingAt.map { (.idle, $0) },
          snapshot.messageAt.map { (.idle, $0) },
          snapshot.errorAt.map { (.idle, $0) }
      ].compactMap { $0 }

      return candidates.max(by: { $0.1 < $1.1 })?.0
  }

  enum CodexStatusKind: String {
      case running
      case idle

      init(status: String) {
          self = CodexStatusKind(rawValue: codexNormalizedStatus(status)) ?? .idle
      }
  }

  enum CodexStatusHookName: String, CaseIterable {
      case onRunning
      case onCompleted
  }

  final class CodexStatusTransitionHooks {
      private let completedCooldown: TimeInterval
      private var lastStatus: CodexStatusKind?
      private var suppressAutoActiveUntil: Date?

      init(completedCooldown: TimeInterval = 8) {
          self.completedCooldown = max(0, completedCooldown)
      }

      func shouldSuppressAutoActive(at now: Date) -> Bool {
          guard let suppressAutoActiveUntil else {
              return false
          }
          return now < suppressAutoActiveUntil
      }

      func recordResolvedStatus(_ status: String, at now: Date) -> CodexStatusHookName? {
          let current = CodexStatusKind(status: status)
          defer {
              lastStatus = current
          }

          guard lastStatus != current else {
              return nil
          }

          if lastStatus == .running, current == .idle {
              suppressAutoActiveUntil = now.addingTimeInterval(completedCooldown)
          }

          switch current {
          case .running:
              return .onRunning
          case .idle:
              return .onCompleted
          }
      }
  }
  ```

- [ ] **Step 4: Run tests to verify compilation and passing**
  Run: `swift test`
  Expected: Success for transition hooks tests.

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/CodexMenuBar/CodexStatusTransitionHooks.swift Tests/CodexMenuBarTests/CodexStatusTransitionHooksTests.swift
  git commit -m "refactor: simplify status definitions and hook transitions"
  ```

---

### Task 2: Simplify CodexMenuBarIconRenderer and Popover Presentation

**Files:**
- Modify: `Sources/CodexMenuBar/CodexMenuBarIconRenderer.swift`
- Modify: `Sources/CodexMenuBar/StatusPopoverPresentation.swift`
- Test: `Tests/CodexMenuBarTests/CodexMenuBarIconRendererTests.swift`
- Test: `Tests/CodexMenuBarTests/StatusPopoverPresentationTests.swift`

- [ ] **Step 1: Write/Update tests for Renderer and Popover**
  Update `Tests/CodexMenuBarTests/CodexMenuBarIconRendererTests.swift`:
  ```swift
  import Foundation
  import Testing
  @testable import CodexMenuBar

  @Suite("Codex menu bar icon rendering")
  struct CodexMenuBarIconRendererTests {
      @Test("Running status uses the running icon")
      func runningUsesRunningIcon() {
          #expect(codexMenuBarIconKind(status: "running", isRecentlyCompleted: false) == .running)
      }

      @Test("Thinking status uses the running icon")
      func thinkingUsesRunningIcon() {
          #expect(codexMenuBarIconKind(status: "thinking", isRecentlyCompleted: false) == .running)
          #expect(codexMenuBarIconKind(status: "running_command", isRecentlyCompleted: false) == .running)
      }

      @Test("Completion and attention states sparkle in the top right")
      func topRightSparkleStates() {
          #expect(!codexMenuBarTopRightSparkleShouldBlink(status: "completed", isRecentlyCompleted: false))
          #expect(!codexMenuBarTopRightSparkleShouldBlink(status: "running", isRecentlyCompleted: false))
      }

      @Test("Completion sparkle sits in the upper right")
      func completionSparkleSitsInTheUpperRight() {
          let center = codexMenuBarTopRightSparkleCenter()
          #expect(center.x > 19)
          #expect(center.y < 7)
      }

      @Test("Running animation varies across frames")
      func runningAnimationVariesAcrossFrames() {
          #expect(codexMenuBarRunningFloatOffset(frameIndex: 0) != codexMenuBarRunningFloatOffset(frameIndex: 1))
          #expect(codexMenuBarBlinkOpacity(frameIndex: 0, phase: 0) != codexMenuBarBlinkOpacity(frameIndex: 1, phase: 0))
      }

      @Test("Running motion streaks move across frames")
      func runningMotionStreaksMoveAcrossFrames() {
          let first = codexMenuBarRunningMotionStreaks(frameIndex: 0)
          let second = codexMenuBarRunningMotionStreaks(frameIndex: 1)

          #expect(first.count == 3)
          #expect(first[0].x != second[0].x)
          #expect(first.allSatisfy { $0.opacity > 0 && $0.opacity < 1 })
      }

      @Test("agActive or agStatus triggers colored rendering and sets isTemplate to false")
      func agActiveOrStatusSetsTemplateMode() {
          let renderer = CodexMenuBarIconRenderer()
          
          let imageNormal = renderer.image(
              status: "idle",
              isRecentlyCompleted: false,
              frameIndex: 0,
              fiveHourUsagePercent: nil,
              weeklyUsagePercent: nil,
              agActive: false
          )
          #expect(imageNormal.isTemplate == true)

          let imageActive = renderer.image(
              status: "idle",
              isRecentlyCompleted: false,
              frameIndex: 0,
              fiveHourUsagePercent: nil,
              weeklyUsagePercent: nil,
              agActive: true
          )
          #expect(imageActive.isTemplate == false)
      }
  }
  ```
  Update `Tests/CodexMenuBarTests/StatusPopoverPresentationTests.swift`:
  ```swift
  import Foundation
  import Testing
  @testable import CodexMenuBar

  @Suite("Status popover presentation")
  struct StatusPopoverPresentationTests {
      @Test("Idle status does not show the popover")
      func idleDoesNotShowPopover() {
          #expect(statusPopoverPresentation(status: "idle", detail: "Ready") == nil)
      }
  }
  ```

- [ ] **Step 2: Run tests to verify failure**
  Run: `swift test`
  Expected: Failures on waiting/completed renderer tests and popover tests due to outdated logic in production renderer and popover.

- [ ] **Step 3: Modify CodexMenuBarIconRenderer.swift production code**
  Update `Sources/CodexMenuBar/CodexMenuBarIconRenderer.swift` to only define `idle` and `running` kinds, and remove custom sparkle blink states.
  ```swift
  import AppKit
  import Foundation

  enum CodexMenuBarIconKind {
      case idle
      case running
  }

  func codexMenuBarIconKind(status: String, isRecentlyCompleted: Bool) -> CodexMenuBarIconKind {
      switch CodexStatusKind(status: status) {
      case .running:
          return .running
      case .idle:
          return .idle
      }
  }

  func codexMenuBarTopRightSparkleShouldBlink(status: String, isRecentlyCompleted: Bool) -> Bool {
      return false
  }

  func codexMenuBarIconColor(status: String, isRecentlyCompleted: Bool) -> NSColor {
      _ = status
      _ = isRecentlyCompleted
      return .black
  }

  func codexMenuBarRunningFloatOffset(frameIndex: Int) -> CGFloat {
      [0.2, 0.7, 1.1, 0.7][frameIndex % 4]
  }

  func codexMenuBarBlinkOpacity(frameIndex: Int, phase: Int = 0) -> CGFloat {
      let sequence: [CGFloat] = [0.25, 1.0, 0.5, 0.85]
      return sequence[(frameIndex + phase) % sequence.count]
  }

  func codexMenuBarTopRightSparkleCenter() -> CGPoint {
      CGPoint(x: 20.2, y: 4.8)
  }

  struct CodexMenuBarMotionStreak {
      var x: CGFloat
      var y: CGFloat
      var width: CGFloat
      var opacity: CGFloat
  }

  func codexMenuBarRunningMotionStreaks(frameIndex: Int) -> [CodexMenuBarMotionStreak] {
      let phase = CGFloat(frameIndex % 4)
      return [
          CodexMenuBarMotionStreak(x: 3.0 - phase * 0.7, y: 9.0, width: 3.8, opacity: 0.18),
          CodexMenuBarMotionStreak(x: 1.4 - phase * 0.55, y: 12.0, width: 2.8, opacity: 0.14),
          CodexMenuBarMotionStreak(x: 4.6 - phase * 0.85, y: 16.2, width: 3.2, opacity: 0.12)
      ]
  }

  final class CodexMenuBarIconRenderer {
      static let size = NSSize(width: 22, height: 22)
      private let strokeWidth: CGFloat = 1.6

      func image(
          status: String,
          isRecentlyCompleted: Bool,
          frameIndex: Int,
          fiveHourUsagePercent: Double?,
          weeklyUsagePercent: Double?,
          agActive: Bool = false,
          agStatus: String? = nil,
          cursorActive: Bool = false,
          cursorStatus: String? = nil,
          hasUpdate: Bool = false
      ) -> NSImage {
          let kind = codexMenuBarIconKind(status: status, isRecentlyCompleted: isRecentlyCompleted)
          let color = codexMenuBarIconColor(status: status, isRecentlyCompleted: isRecentlyCompleted)
          
          let effectiveAgStatus: String?
          if let agStatus = agStatus, agStatus != "idle" {
              effectiveAgStatus = agStatus
          } else if agActive {
              effectiveAgStatus = "running"
          } else {
              effectiveAgStatus = nil
          }
          
          let effectiveCursorStatus: String?
          if let cursorStatus = cursorStatus, cursorStatus != "idle" {
              effectiveCursorStatus = cursorStatus
          } else if cursorActive {
              effectiveCursorStatus = "running"
          } else {
              effectiveCursorStatus = nil
          }
          
          let hasAgDot = (effectiveAgStatus != nil)
          let hasCursorDot = (effectiveCursorStatus != nil)
          
          let image = NSImage(size: Self.size, flipped: false) { [weak self] rect in
              guard let self = self else { return false }
              NSGraphicsContext.current?.shouldAntialias = true
              self.draw(
                  kind: kind,
                  color: (hasAgDot || hasCursorDot || hasUpdate) ? NSColor.labelColor : color,
                  frameIndex: frameIndex,
                  fiveHourUsagePercent: fiveHourUsagePercent,
                  weeklyUsagePercent: weeklyUsagePercent,
                  showTopRightSparkle: codexMenuBarTopRightSparkleShouldBlink(
                      status: status,
                      isRecentlyCompleted: isRecentlyCompleted
                  ),
                  hasUpdate: hasUpdate
              )

              if let effectiveAgStatus {
                  self.drawAgStatusDot(agStatus: effectiveAgStatus, frameIndex: frameIndex)
              }
              
              if let effectiveCursorStatus {
                  self.drawCursorStatusDot(cursorStatus: effectiveCursorStatus, frameIndex: frameIndex)
              }
              return true
          }
          
          image.isTemplate = !hasAgDot && !hasCursorDot && !hasUpdate
          return image
      }

      private func drawAgStatusDot(agStatus: String, frameIndex: Int) {
          drawDot(status: agStatus, frameIndex: frameIndex, defaultColor: .systemPurple, offset: 0)
      }
      
      private func drawCursorStatusDot(cursorStatus: String, frameIndex: Int) {
          drawDot(status: cursorStatus, frameIndex: frameIndex, defaultColor: .systemBlue, offset: 6)
      }
      
      private func drawDot(status: String, frameIndex: Int, defaultColor: NSColor, offset: CGFloat) {
          let dotColor: NSColor
          if status == "running" {
              let alpha = codexMenuBarBlinkOpacity(frameIndex: frameIndex)
              dotColor = defaultColor.withAlphaComponent(alpha)
          } else {
              dotColor = defaultColor
          }
          
          let dotSize: CGFloat = 4.0
          let rect = NSRect(
              x: Self.size.width - dotSize - 1.0 - offset,
              y: 1.0,
              width: dotSize,
              height: dotSize
          )
          let dotPath = NSBezierPath(ovalIn: rect)
          dotColor.setFill()
          dotPath.fill()
      }

      private func draw(
          kind: CodexMenuBarIconKind,
          color: NSColor,
          frameIndex: Int,
          fiveHourUsagePercent: Double?,
          weeklyUsagePercent: Double?,
          showTopRightSparkle: Bool,
          hasUpdate: Bool
      ) {
          let contextRect = CGRect(origin: .zero, size: Self.size)
          let viewBoxWidth: CGFloat = 24
          let viewBoxHeight: CGFloat = 24
          let scale = min(contextRect.width / viewBoxWidth, contextRect.height / viewBoxHeight)
          let drawSize = CGSize(width: viewBoxWidth * scale, height: viewBoxHeight * scale)
          let origin = CGPoint(x: (contextRect.width - drawSize.width) / 2, y: (contextRect.height - drawSize.height) / 2)

          NSGraphicsContext.saveGraphicsState()
          let transform = NSAffineTransform()
          transform.translateX(by: origin.x, yBy: origin.y + drawSize.height)
          transform.scaleX(by: scale, yBy: -scale)
          transform.concat()

          drawUsageBars(
              color: color,
              fiveHourUsagePercent: fiveHourUsagePercent,
              weeklyUsagePercent: weeklyUsagePercent
          )

          switch kind {
          case .idle:
              drawBaseSpaceship(color: color, dotFrameIndex: nil, blinkingDotIndex: nil, verticalOffset: 0)
          case .running:
              drawRunningMotionStreaks(color: color, frameIndex: frameIndex)
              drawBaseSpaceship(color: color, dotFrameIndex: frameIndex, verticalOffset: codexMenuBarRunningFloatOffset(frameIndex: frameIndex))
          }

          if showTopRightSparkle {
              drawCompleteSparkle(color: color, frameIndex: frameIndex)
          }

          if hasUpdate {
              drawExclamationMark()
          }

          NSGraphicsContext.restoreGraphicsState()
      }

      private func drawExclamationMark() {
          let markColor = NSColor.systemOrange
          markColor.setStroke()
          
          let path = NSBezierPath()
          path.lineWidth = 1.6
          path.lineCapStyle = .roundLineCap
          
          path.move(to: CGPoint(x: 20.2, y: 3.5))
          path.lineTo(to: CGPoint(x: 20.2, y: 7.0))
          path.stroke()
          
          let dotPath = NSBezierPath(ovalIn: NSRect(x: 19.3, y: 9.2, width: 1.8, height: 1.8))
          markColor.setFill()
          dotPath.fill()
      }

      private func drawUsageBars(color: NSColor, fiveHourUsagePercent: Double?, weeklyUsagePercent: Double?) {
          let heightMax: CGFloat = 16.0
          let xFiveHour: CGFloat = 2.0
          let xWeekly: CGFloat = 21.0
          let yStart: CGFloat = 19.0
          
          if let fiveHour = fiveHourUsagePercent {
              drawUsageBar(x: xFiveHour, yStart: yStart, height: heightMax, percent: fiveHour, color: color)
          }
          if let weekly = weeklyPercent {
              drawUsageBar(x: xWeekly, yStart: yStart, height: heightMax, percent: weekly, color: color)
          }
      }

      private func drawUsageBar(x: CGFloat, yStart: CGFloat, height: CGFloat, percent: Double, color: NSColor) {
          let barHeight = height * CGFloat(min(max(percent, 0.0), 100.0) / 100.0)
          if barHeight <= 0 { return }
          
          let path = NSBezierPath()
          path.lineWidth = strokeWidth
          path.lineCapStyle = .roundLineCap
          
          let opacity = min(max(percent / 100.0, 0.15), 0.85)
          let strokeColor = color.withAlphaComponent(CGFloat(opacity))
          strokeColor.setStroke()
          
          path.move(to: CGPoint(x: x, y: yStart))
          path.lineTo(to: CGPoint(x: x, y: yStart - barHeight))
          path.stroke()
      }

      private func drawRunningMotionStreaks(color: NSColor, frameIndex: Int) {
          let streaks = codexMenuBarRunningMotionStreaks(frameIndex: frameIndex)
          for streak in streaks {
              let path = NSBezierPath()
              path.lineWidth = strokeWidth
              path.lineCapStyle = .roundLineCap
              
              let streakColor = color.withAlphaComponent(streak.opacity)
              streakColor.setStroke()
              
              path.move(to: CGPoint(x: streak.x, y: streak.y))
              path.lineTo(to: CGPoint(x: streak.x + streak.width, y: streak.y))
              path.stroke()
          }
      }

      private func drawCompleteSparkle(color: NSColor, frameIndex: Int) {
          let center = codexMenuBarTopRightSparkleCenter()
          let opacity = codexMenuBarBlinkOpacity(frameIndex: frameIndex)
          let sparkleColor = color.withAlphaComponent(opacity)
          sparkleColor.setStroke()
          
          let path = NSBezierPath()
          path.lineWidth = 1.0
          path.lineCapStyle = .roundLineCap
          
          let radius: CGFloat = 2.0
          path.move(to: CGPoint(x: center.x - radius, y: center.y))
          path.lineTo(to: CGPoint(x: center.x + radius, y: center.y))
          path.move(to: CGPoint(x: center.x, y: center.y - radius))
          path.lineTo(to: CGPoint(x: center.x, y: center.y + radius))
          path.stroke()
      }

      private func drawBaseSpaceship(
          color: NSColor,
          dotFrameIndex: Int?,
          blinkingDotIndex: Int? = nil,
          verticalOffset: CGFloat = 0.0
      ) {
          color.setStroke()
          let path = NSBezierPath()
          path.lineWidth = strokeWidth
          path.lineJoinStyle = .roundLineJoinStyle
          path.lineCapStyle = .roundLineCap
          
          path.move(to: CGPoint(x: 12.0, y: 4.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 17.0, y: 15.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 14.0, y: 15.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 13.0, y: 18.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 11.0, y: 18.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 10.0, y: 15.0 + verticalOffset))
          path.lineTo(to: CGPoint(x: 7.0, y: 15.0 + verticalOffset))
          path.close()
          path.stroke()
          
          if let frame = dotFrameIndex {
              let dotColor: NSColor
              if let blink = blinkingDotIndex {
                  let alpha = codexMenuBarBlinkOpacity(frameIndex: frame, phase: blink)
                  dotColor = color.withAlphaComponent(alpha)
              } else {
                  dotColor = color
              }
              dotColor.setFill()
              
              let dotRect = NSRect(
                  x: 11.2,
                  y: 10.5 + verticalOffset,
                  width: 1.6,
                  height: 1.6
              )
              let dotPath = NSBezierPath(ovalIn: dotRect)
              dotPath.fill()
          }
      }
  }
  ```

- [ ] **Step 4: Modify StatusPopoverPresentation.swift production code**
  Update `Sources/CodexMenuBar/StatusPopoverPresentation.swift` to always return `nil`.
  ```swift
  import AppKit
  import Foundation

  struct StatusPopoverPresentation {
      var badge: String
      var title: String
      var body: String
      var contentSize: NSSize
  }

  func statusPopoverPresentation(status: String, detail: String) -> StatusPopoverPresentation? {
      return nil
  }
  ```

- [ ] **Step 5: Run tests to verify compilation and passing**
  Run: `swift test`
  Expected: Success for renderer and popover tests.

- [ ] **Step 6: Commit**
  ```bash
  git add Sources/CodexMenuBar/CodexMenuBarIconRenderer.swift Sources/CodexMenuBar/StatusPopoverPresentation.swift Tests/CodexMenuBarTests/CodexMenuBarIconRendererTests.swift Tests/CodexMenuBarTests/StatusPopoverPresentationTests.swift
  git commit -m "refactor: simplify menu bar icon renderer and stub status popover"
  ```

---

### Task 3: Simplify main.swift and Menu Presentation

**Files:**
- Modify: `Sources/CodexMenuBar/main.swift`

- [ ] **Step 1: Simplify app logic in main.swift**
  Modify the following methods in `Sources/CodexMenuBar/main.swift` to simplify status routing:
  - Update `codexMenuBarStatusCanBeAcknowledged` and `codexMenuBarShouldShowRecentCompletion` at the top of `main.swift` (lines 131-163):
    ```swift
    func codexMenuBarStatusCanBeAcknowledged(_ kind: CodexStatusKind) -> Bool {
        return false
    }

    func codexMenuBarShouldShowRecentCompletion(
        status: CodexStatusKind,
        referenceDate: Date?,
        acknowledgedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        return false
    }
    ```
  - Simplify `canonicalStatusText(for:)` (lines 2428-2445) and `defaultDetail(for:)` (lines 2447-2464):
    ```swift
        private func canonicalStatusText(for kind: CodexStatusKind) -> String {
            switch kind {
            case .running:
                return "running"
            case .idle:
                return "idle"
            }
        }

        private func defaultDetail(for status: String) -> String {
            switch status {
            case "running":
                return "Codex is working"
            default:
                return "Codex is idle"
            }
        }
    ```
  - Simplify `shouldAnimateMenuBarIcon()` (lines 2557-2579) to only animate on running status:
    ```swift
        private func shouldAnimateMenuBarIcon() -> Bool {
            let status = currentPayload?.status?.lowercased() ?? "idle"
            let iconKind = codexMenuBarIconKind(status: status, isRecentlyCompleted: isRecentlyCompleted())
            
            // Spaceship floats/streaks when running
            if iconKind == .running {
                return true
            }

            return false
        }
    ```
  - Normalize AGY Status output to `Running` or `Idle` inside `updateMenu()` (lines 2667-2700):
    ```swift
            if showAGY {
                let agStatusText: String
                let agPayload = currentPayload?.antigravity
                let agStatus = agPayload?.status?.lowercased() ?? "idle"
                
                let normalizedAgStatus: String
                if agStatus.contains("thinking")
                    || agStatus.contains("running_command")
                    || agStatus.contains("running command")
                    || agStatus.contains("working")
                    || agStatus == "running"
                {
                    normalizedAgStatus = "running"
                } else {
                    normalizedAgStatus = "idle"
                }
                
                if normalizedAgStatus == "running" || agActive {
                    let count = currentAntigravitySnapshot.activeConversationCount
                    agStatusText = "● Running (\(count) active)"
                } else if let lastDate = currentAntigravitySnapshot.lastActivityDate {
                    let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
                    agStatusText = "Idle (\(seconds)s ago)"
                } else {
                    agStatusText = "Idle"
                }
                menu.item(at: 15)?.title = "AGY Status: \(agStatusText)"
    ```
  - Simplify popover helper `updateStatusPopover(for:)` (lines 2839-2862):
    ```swift
        private func updateStatusPopover(for status: String) {
            if statusPopover.isShown {
                statusPopover.performClose(nil)
            }
            lastPopupStatus = nil
        }
    ```

- [ ] **Step 2: Run tests to verify compilation and passing**
  Run: `swift test`
  Expected: All 37 tests compile and pass successfully.

- [ ] **Step 3: Commit**
  ```bash
  git add Sources/CodexMenuBar/main.swift
  git commit -m "refactor: simplify app status routing, popover handling, and AGY menu display"
  ```
