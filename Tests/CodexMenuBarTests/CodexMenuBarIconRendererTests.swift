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
