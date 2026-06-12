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
            acknowledgedAt: acknowledgedAt,
            now: now
        ))
    }

    @Test("Codex app detection excludes the menu bar helper")
    func codexAppDetectionExcludesTheMenuBarHelper() {
        #expect(codexMenuBarIsCodexApplication(bundleIdentifier: "com.openai.codex", localizedName: "Codex"))
        #expect(!codexMenuBarIsCodexApplication(bundleIdentifier: "dev.local.CodexMenuBar", localizedName: "Codex Menu Bar"))
    }
}
