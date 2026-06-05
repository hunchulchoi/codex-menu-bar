import AppKit
import Darwin
import Foundation
import SQLite3

struct TokenUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
}

struct AntigravityStatusPayload: Decodable {
    var status: String?
    var detail: String?
    var updatedAt: String?
}

struct StatusPayload: Decodable {
    var status: String?
    var detail: String?
    var thread: String?
    var progress: Double?
    var updatedAt: String?
    var startedAt: String?
    var model: String?
    var contextWindow: Int?
    var tokenUsage: TokenUsage?
    var antigravity: AntigravityStatusPayload?
}

struct AppSettings: Codable {
    var autoWatchEnabled: Bool
    var antigravityWatchEnabled: Bool
    var cursorWatchEnabled: Bool
    var activeWindowSeconds: TimeInterval
    var pollIntervalSeconds: TimeInterval
    var weeklyLimitText: String?
    var fiveHourLimitText: String?
    var autoUpdateEnabled: Bool?

    static func defaults() -> AppSettings {
        AppSettings(
            autoWatchEnabled: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_AUTO_WATCH"] != "0",
            antigravityWatchEnabled: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_AGY_WATCH"] != "0",
            cursorWatchEnabled: ProcessInfo.processInfo.environment["CODEX_MENU_BAR_CURSOR_WATCH"] != "0",
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
            cursorWatchEnabled: cursorWatchEnabled,
            activeWindowSeconds: max(1, activeWindowSeconds),
            pollIntervalSeconds: max(0.25, pollIntervalSeconds),
            weeklyLimitText: cleanText(weeklyLimitText),
            fiveHourLimitText: cleanText(fiveHourLimitText),
            autoUpdateEnabled: autoUpdateEnabled ?? true
        )
    }

    private func cleanText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func envTimeInterval(
        _ name: String,
        defaultValue: TimeInterval,
        minimum: TimeInterval
    ) -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[name],
            let value = TimeInterval(raw)
        else {
            return defaultValue
        }
        return max(minimum, value)
    }
}

func codexMenuBarExecutableURL(
    bundleExecutableURL: URL?,
    processArguments: [String]
) -> URL? {
    if let bundleExecutableURL {
        return bundleExecutableURL
    }
    guard let firstArgument = processArguments.first, !firstArgument.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: NSString(string: firstArgument).expandingTildeInPath)
}

func codexMenuBarShellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func codexMenuBarRelaunchShellCommand(executableURL: URL, delaySeconds: Double = 0.35) -> String {
    "sleep \(String(format: "%.2f", delaySeconds)); exec \(codexMenuBarShellQuoted(executableURL.path))"
}

func codexLogDate(seconds: TimeInterval, nanoseconds: Int64) -> Date {
    Date(timeIntervalSince1970: seconds + (Double(nanoseconds) / 1_000_000_000.0))
}

func codexMenuBarIsCodexApplication(bundleIdentifier: String?, localizedName: String?) -> Bool {
    let bundle = bundleIdentifier?.lowercased() ?? ""
    let name = localizedName?.lowercased() ?? ""

    if bundle.contains("codex") && !bundle.contains("codexmenubar") && !bundle.contains("codex-menu-bar") {
        return true
    }
    if name.contains("codex") && !name.contains("codex menu bar") && !name.contains("codexmenubar") {
        return true
    }
    if bundle.contains("com.todesktop.230313mzl4w4u92") || bundle.contains("cursor") {
        return true
    }
    if name.contains("cursor") {
        return true
    }
    return false
}

func codexMenuBarStatusCanBeAcknowledged(_ kind: CodexStatusKind) -> Bool {
    switch kind {
    case .completed, .awaitingApproval, .error:
        return true
    case .running, .idle, .waiting, .message:
        return false
    }
}

func codexMenuBarAttentionStatusIsAcknowledged(statusAt: Date?, acknowledgedAt: Date?) -> Bool {
    guard let statusAt, let acknowledgedAt else {
        return false
    }
    return statusAt <= acknowledgedAt
}

func codexMenuBarShouldShowRecentCompletion(
    status: CodexStatusKind,
    referenceDate: Date?,
    acknowledgedAt: Date?,
    now: Date = Date()
) -> Bool {
    if status == .completed {
        return !codexMenuBarAttentionStatusIsAcknowledged(statusAt: referenceDate ?? now, acknowledgedAt: acknowledgedAt)
    }
    guard status == .idle, let referenceDate else {
        return false
    }
    if codexMenuBarAttentionStatusIsAcknowledged(statusAt: referenceDate, acknowledgedAt: acknowledgedAt) {
        return false
    }
    return now.timeIntervalSince(referenceDate) <= 300
}

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

struct LimitState {
    var planType: String?
    var primary: LimitBucket?
    var secondary: LimitBucket?
    var observedAt: Date
    var source: String

    static let empty = LimitState(
        planType: nil,
        primary: nil,
        secondary: nil,
        observedAt: Date(),
        source: "none"
    )
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
}

private struct AuthPayload: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var access_token: String?
}

private struct UsagePayload: Decodable {
    var plan_type: String?
    var rate_limit: RatePayload?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_after_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else {
            return nil
        }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        let reset = reset_at ?? reset_after_seconds.map { Date().timeIntervalSince1970 + $0 }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset)
    }
}

final class URLResultBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
}

final class LimitStateReader: @unchecked Sendable {
    private let logsPath: URL
    private let authPath: URL
    private let modelsCacheFile: URL
    private let liveUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let decoder = JSONDecoder()

    init(codexHome: URL) {
        logsPath = codexHome.appendingPathComponent("logs_2.sqlite")
        authPath = codexHome.appendingPathComponent("auth.json")
        modelsCacheFile = codexHome.appendingPathComponent("models_cache.json")
    }

    func readLatest() -> LimitState {
        if let live = readLiveUsage() {
            return live
        }
        return readLatestLog()
    }

    func readCurrentModelName() -> String? {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%model=%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return nil
        }

        let body = String(cString: cText)
        return parseModelName(from: body)
    }

    func readCurrentContextWindow(for modelName: String?) -> Int? {
        guard let modelName, let cacheData = try? Data(contentsOf: modelsCacheFile) else {
            return nil
        }
        return contextWindow(forModelNamed: modelName, cacheData: cacheData)
    }

    func readTokenUsageStats() -> TokenUsageSummary {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        var samples: [TokenUsageSample] = []

        let sql = """
        SELECT ts, feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%post sampling token usage%'
          AND feedback_log_body LIKE '%total_usage_tokens=%'
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let ts = sqlite3_column_double(statement, 0)
            guard let cText = sqlite3_column_text(statement, 1) else {
                continue
            }
            let body = String(cString: cText)
            guard let sample = parseTokenUsageSample(timestamp: ts, body: body) else {
                continue
            }
            samples.append(sample)
        }

        return TokenUsageSummary.build(
            samples: samples,
            now: Date(),
            calendar: Calendar.current,
            fiveHourBucketCount: 30
        )
    }

    func readRuntimeSignalSnapshot() -> CodexRuntimeSignalSnapshot? {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ts, ts_nanos, feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"status":"in_progress"%'
           OR feedback_log_body LIKE '%"status":"completed"%'
           OR feedback_log_body LIKE '%"status":"failed"%'
           OR feedback_log_body LIKE '%"status":"error"%'
           OR feedback_log_body LIKE '%response.created%'
           OR feedback_log_body LIKE '%response.completed%'
           OR feedback_log_body LIKE '%response.output_item.added%'
           OR feedback_log_body LIKE '%response.output_item.done%'
           OR feedback_log_body LIKE '%approval_required%'
           OR feedback_log_body LIKE '%awaiting approval%'
           OR feedback_log_body LIKE '%waiting for input%'
           OR feedback_log_body LIKE '%new message%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 500
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var snapshot = CodexRuntimeSignalSnapshot(runningAt: nil, approvalAt: nil, completedAt: nil, waitingAt: nil, messageAt: nil, errorAt: nil)

        while sqlite3_step(statement) == SQLITE_ROW {
            let ts = sqlite3_column_double(statement, 0)
            let tsNanos = sqlite3_column_int64(statement, 1)
            let date = codexLogDate(seconds: ts, nanoseconds: tsNanos)
            guard let cText = sqlite3_column_text(statement, 2) else {
                continue
            }
            let body = String(cString: cText)

            codexRecordRuntimeSignal(from: body, at: date, into: &snapshot)

            if snapshot.runningAt != nil
                && snapshot.completedAt != nil
                && snapshot.approvalAt != nil
                && snapshot.waitingAt != nil
                && snapshot.messageAt != nil
                && snapshot.errorAt != nil
            {
                break
            }
        }

        return (snapshot.runningAt != nil || snapshot.approvalAt != nil || snapshot.completedAt != nil || snapshot.waitingAt != nil || snapshot.messageAt != nil || snapshot.errorAt != nil) ? snapshot : nil
    }

    func codexRecordRuntimeSignal(from body: String, at date: Date, into snapshot: inout CodexRuntimeSignalSnapshot) {
        if (body.contains("\"status\":\"in_progress\"")
            || body.contains("response.created")
            || body.contains("response.output_item.added"))
            && snapshot.runningAt == nil
        {
            snapshot.runningAt = date
        }
        if (body.contains("\"status\":\"completed\"")
            || body.contains("response.completed")
            || body.contains("response.output_item.done"))
            && snapshot.completedAt == nil
        {
            snapshot.completedAt = date
        }
        if (body.contains("approval_required")
            || body.contains("awaiting approval")
            || body.contains("waiting for input"))
            && snapshot.approvalAt == nil
        {
            snapshot.approvalAt = date
        }
        if body.contains("new message"), snapshot.messageAt == nil {
            snapshot.messageAt = date
        }
        if (body.contains("\"status\":\"failed\"")
            || body.contains("\"status\":\"error\"")
            || body.contains("failed"))
            && snapshot.errorAt == nil
        {
            snapshot.errorAt = date
        }
        if body.contains("waiting") && snapshot.waitingAt == nil {
            snapshot.waitingAt = date
        }
    }

    private func readLiveUsage() -> LimitState? {
        guard let token = readAccessToken() else {
            return nil
        }
        var request = URLRequest(url: liveUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        let result = URLResultBox()

        URLSession.shared.dataTask(with: request) { data, response, _ in
            result.data = data
            result.response = response
            semaphore.signal()
        }.resume()

        guard
            semaphore.wait(timeout: .now() + 7.0) == .success,
            let http = result.response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let data = result.data,
            let payload = try? decoder.decode(UsagePayload.self, from: data)
        else {
            return nil
        }

        return LimitState(
            planType: payload.plan_type,
            primary: (payload.rate_limit?.primary ?? payload.rate_limit?.primary_window)?.toBucket(),
            secondary: (payload.rate_limit?.secondary ?? payload.rate_limit?.secondary_window)?.toBucket(),
            observedAt: Date(),
            source: "live"
        )
    }

    private func readAccessToken() -> String? {
        guard
            let data = try? Data(contentsOf: authPath),
            let payload = try? decoder.decode(AuthPayload.self, from: data),
            let token = payload.tokens?.access_token,
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return .empty
        }

        let body = String(cString: cText)
        guard
            let json = extractRateLimitJSON(from: body),
            let data = json.data(using: .utf8),
            let payload = try? decoder.decode(EventPayload.self, from: data)
        else {
            return .empty
        }

        return LimitState(
            planType: payload.plan_type,
            primary: (payload.rate_limits?.primary ?? payload.rate_limits?.primary_window)?.toBucket(),
            secondary: (payload.rate_limits?.secondary ?? payload.rate_limits?.secondary_window)?.toBucket(),
            observedAt: Date(),
            source: "cached"
        )
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(body[start...index])
                    }
                }
            }
            index = body.index(after: index)
        }
        return nil
    }

    private func parseTokenUsageSample(timestamp: TimeInterval, body: String) -> TokenUsageSample? {
        guard
            body.contains(":run_turn: post sampling token usage"),
            !body.hasPrefix("Received message "),
            !body.contains("function_call_arguments"),
            let threadID = valueAfter("thread.id=", in: body),
            let totalRaw = valueAfter("total_usage_tokens=", in: body),
            let totalTokens = Int(totalRaw)
        else {
            return nil
        }

        return TokenUsageSample(
            timestamp: timestamp,
            threadID: threadID,
            totalTokens: totalTokens
        )
    }

    private func valueAfter(_ marker: String, in body: String) -> String? {
        guard let range = body.range(of: marker) else {
            return nil
        }

        var value = ""
        var index = range.upperBound
        while index < body.endIndex {
            let char = body[index]
            if char.isWhitespace || char == "}" || char == "," {
                break
            }
            value.append(char)
            index = body.index(after: index)
        }

        return value.isEmpty ? nil : value
    }
}

private final class UsageSummaryCardView: NSView {
    // MARK: - Tab state
    private enum Tab: Int {
        case codex = 0
        case cursor = 1
        case antigravity = 2
    }
    private var selectedTab: Tab = .codex
    private var activeTabs: [Tab] = [.codex, .cursor, .antigravity]

    // MARK: - Container
    private let surfaceView = NSView(frame: .zero)
    private let tabControl = NSSegmentedControl()

    // MARK: - Codex panel
    private let codexPanel = NSView(frame: .zero)
    private let titleLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let elapsedLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let tokensLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let contextWindowLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
    private let graphCaptionLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
    private let graphView = TokenUsageGraphView()
    private let fiveHourLimitView = LimitUsageBarView()
    private let weeklyLimitView = LimitUsageBarView()
    private let todayUsageView = UsageMetricBlockView()
    private let weekUsageView = UsageMetricBlockView()

    // MARK: - Cursor panel
    private let cursorPanel = NSView(frame: .zero)
    private let cursorTitleLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let cursorStatusLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let cursorLastActivityLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
    private let cursorAPILimitView = LimitUsageBarView()
    private let cursorTotalLimitView = LimitUsageBarView()
    private let cursorSpendLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .regular), color: .labelColor)
    private let cursorTokensLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .regular), color: .labelColor)

    // MARK: - Antigravity panel
    private let agPanel = NSView(frame: .zero)
    private let agTitleLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let agStatusLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let agLastActivityLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
    private let agActiveConvLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 13, weight: .regular), color: .labelColor)
    private let agTotalConvLabel = UsageSummaryCardView.makeLabel(font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
    private let agActivityBar = LimitUsageBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 268))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        surfaceView.wantsLayer = true
        surfaceView.layer?.cornerRadius = 12
        surfaceView.layer?.borderWidth = 1
        surfaceView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        surfaceView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor

        // Tab control
        tabControl.segmentCount = 3
        tabControl.setLabel("Codex", forSegment: 0)
        tabControl.setLabel("Cursor", forSegment: 1)
        tabControl.setLabel("AGY", forSegment: 2)
        tabControl.selectedSegment = 0
        tabControl.segmentStyle = .rounded
        tabControl.controlSize = .small
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))

        // Codex panel setup
        titleLabel.stringValue = "Token Usage"
        elapsedLabel.stringValue = "Elapsed: -"
        tokensLabel.stringValue = "Tokens: -"
        contextWindowLabel.stringValue = ""
        graphCaptionLabel.stringValue = "5-hour token graph"

        codexPanel.addSubview(titleLabel)
        codexPanel.addSubview(contextWindowLabel)
        codexPanel.addSubview(elapsedLabel)
        codexPanel.addSubview(tokensLabel)
        codexPanel.addSubview(graphCaptionLabel)
        codexPanel.addSubview(graphView)
        codexPanel.addSubview(fiveHourLimitView)
        codexPanel.addSubview(weeklyLimitView)
        codexPanel.addSubview(todayUsageView)
        codexPanel.addSubview(weekUsageView)

        // Cursor panel setup
        cursorTitleLabel.stringValue = "Cursor Usage"
        cursorStatusLabel.stringValue = "Status: idle"
        cursorLastActivityLabel.stringValue = "Last activity: -"
        cursorSpendLabel.stringValue = "Spend: -"
        cursorTokensLabel.stringValue = "Tokens: -"

        cursorPanel.addSubview(cursorTitleLabel)
        cursorPanel.addSubview(cursorStatusLabel)
        cursorPanel.addSubview(cursorLastActivityLabel)
        cursorPanel.addSubview(cursorSpendLabel)
        cursorPanel.addSubview(cursorTokensLabel)
        cursorPanel.addSubview(cursorAPILimitView)
        cursorPanel.addSubview(cursorTotalLimitView)
        cursorPanel.isHidden = true

        // AGY panel setup
        agTitleLabel.stringValue = "Antigravity"
        agStatusLabel.stringValue = "Status: idle"
        agLastActivityLabel.stringValue = "Last activity: -"
        agActiveConvLabel.stringValue = "Active conversations: -"
        agTotalConvLabel.stringValue = "Total conversations: -"

        agPanel.addSubview(agTitleLabel)
        agPanel.addSubview(agStatusLabel)
        agPanel.addSubview(agLastActivityLabel)
        agPanel.addSubview(agActiveConvLabel)
        agPanel.addSubview(agTotalConvLabel)
        agPanel.addSubview(agActivityBar)
        agPanel.isHidden = true

        addSubview(surfaceView)
        surfaceView.addSubview(tabControl)
        surfaceView.addSubview(codexPanel)
        surfaceView.addSubview(cursorPanel)
        surfaceView.addSubview(agPanel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        if index >= 0 && index < activeTabs.count {
            selectedTab = activeTabs[index]
        } else {
            selectedTab = .codex
        }
        
        let cursorEnabled = activeTabs.contains(.cursor)
        let antigravityEnabled = activeTabs.contains(.antigravity)
        
        codexPanel.isHidden = selectedTab != .codex
        cursorPanel.isHidden = selectedTab != .cursor || !cursorEnabled
        agPanel.isHidden = selectedTab != .antigravity || !antigravityEnabled
        needsLayout = true
    }

    func configureTabs(antigravityEnabled: Bool, cursorEnabled: Bool) {
        var segments: [(String, Tab)] = [("Codex", .codex)]
        if cursorEnabled {
            segments.append(("Cursor", .cursor))
        }
        if antigravityEnabled {
            segments.append(("AGY", .antigravity))
        }
        
        self.activeTabs = segments.map { $0.1 }
        
        tabControl.segmentCount = segments.count
        for (index, (label, _)) in segments.enumerated() {
            tabControl.setLabel(label, forSegment: index)
        }
        
        if !activeTabs.contains(selectedTab) {
            selectedTab = .codex
        }
        
        if let newIndex = activeTabs.firstIndex(of: selectedTab) {
            tabControl.selectedSegment = newIndex
        } else {
            tabControl.selectedSegment = 0
            selectedTab = .codex
        }
        
        codexPanel.isHidden = selectedTab != .codex
        cursorPanel.isHidden = selectedTab != .cursor || !cursorEnabled
        agPanel.isHidden = selectedTab != .antigravity || !antigravityEnabled
        
        tabControl.isHidden = (segments.count <= 1)
        
        needsLayout = true
    }

    // MARK: - Codex update

    func update(
        elapsed: String,
        tokens: String,
        buckets: [Int],
        todayTokens: Int,
        weekTokens: Int,
        fiveHourTokens: Int,
        weeklyTokens: Int,
        contextWindow: Int?
    ) {
        update(
            elapsed: elapsed,
            tokens: tokens,
            buckets: buckets,
            todayTokens: todayTokens,
            weekTokens: weekTokens,
            fiveHourTokens: fiveHourTokens,
            weeklyTokens: weeklyTokens,
            fiveHourLimit: nil,
            weeklyLimit: nil,
            bucketWindowEnd: Date(),
            modelName: nil,
            contextWindow: contextWindow,
            isCompleted: false
        )
    }

    func update(
        elapsed: String,
        tokens: String,
        buckets: [Int],
        todayTokens: Int,
        weekTokens: Int,
        fiveHourTokens: Int,
        weeklyTokens: Int,
        fiveHourLimit: LimitBucket?,
        weeklyLimit: LimitBucket?,
        bucketWindowEnd: Date,
        modelName: String?,
        contextWindow: Int?,
        isCompleted: Bool
    ) {
        titleLabel.stringValue = Self.formattedCodexTitle(isCompleted: isCompleted, modelName: modelName)
        contextWindowLabel.stringValue = formatContextWindow(contextWindow).map { "Context: \($0)" } ?? ""
        elapsedLabel.stringValue = "Elapsed: \(elapsed)"
        tokensLabel.stringValue = "Tokens: \(tokens)"
        graphView.update(buckets: buckets, windowEnd: bucketWindowEnd)
        let reference = max(todayTokens, weekTokens, 1)
        todayUsageView.update(
            title: "Today",
            value: "\(formatTokenCount(todayTokens)) tokens",
            subtitle: "calendar day",
            fillRatio: Double(todayTokens) / Double(reference),
            fillColor: .systemBlue
        )
        weekUsageView.update(
            title: "This week",
            value: "\(formatTokenCount(weekTokens)) tokens",
            subtitle: "calendar week",
            fillRatio: Double(weekTokens) / Double(reference),
            fillColor: .systemGreen
        )
        fiveHourLimitView.update(
            title: "5h limit",
            bucket: fiveHourLimit,
            tokenText: formatTokenCount(fiveHourTokens)
        )
        weeklyLimitView.update(
            title: "Weekly limit",
            bucket: weeklyLimit,
            tokenText: formatTokenCount(weeklyTokens)
        )
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Antigravity update

    func updateAntigravity(
        snapshot: AntigravityActivitySnapshot,
        activeWindowSeconds: TimeInterval,
        now: Date = Date()
    ) {
        let isActive = snapshot.isActive(activeWindowSeconds: activeWindowSeconds, now: now)
        let statusText: String
        let statusColor: NSColor
        if isActive {
            let count = snapshot.activeConversationCount
            statusText = "● Running (\(count) active)"
            statusColor = .systemGreen
        } else {
            statusText = "○ Idle"
            statusColor = .secondaryLabelColor
        }
        agTitleLabel.stringValue = "Antigravity"
        agStatusLabel.stringValue = "Status: \(statusText)"
        agStatusLabel.textColor = statusColor

        if let lastDate = snapshot.lastActivityDate {
            let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
            agLastActivityLabel.stringValue = "Last activity: \(formatActivityAge(seconds))"
        } else {
            agLastActivityLabel.stringValue = "Last activity: -"
        }

        agActiveConvLabel.stringValue = "Active conversations: \(snapshot.activeConversationCount)"
        agTotalConvLabel.stringValue = "Total conversations: \(snapshot.totalConversationCount)"

        // Activity bar: ratio of active to total, capped at 1
        let ratio = snapshot.totalConversationCount > 0
            ? Double(snapshot.activeConversationCount) / Double(max(snapshot.totalConversationCount, 1))
            : 0.0
        agActivityBar.updateRaw(
            title: "Recent activity ratio",
            usedPercent: ratio * 100.0,
            color: isActive ? .systemGreen : .systemGray
        )

        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Cursor update

    func updateCursor(
        snapshot: CursorActivitySnapshot,
        limitState: CursorLimitState,
        activeWindowSeconds: TimeInterval,
        now: Date = Date()
    ) {
        let isActive = snapshot.isActive(activeWindowSeconds: activeWindowSeconds, now: now)
        let statusText: String
        let statusColor: NSColor
        if isActive {
            statusText = "● Running"
            statusColor = .systemCyan
        } else {
            statusText = "○ Idle"
            statusColor = .secondaryLabelColor
        }
        cursorTitleLabel.stringValue = "Cursor Usage"
        cursorStatusLabel.stringValue = "Status: \(statusText)"
        cursorStatusLabel.textColor = statusColor

        let latestActivity = [snapshot.lastUserActivityDate, snapshot.lastAgentActivityDate].compactMap { $0 }.max()
        if let lastDate = latestActivity {
            let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
            cursorLastActivityLabel.stringValue = "Last activity: \(formatActivityAge(seconds))"
        } else {
            cursorLastActivityLabel.stringValue = "Last activity: -"
        }

        if limitState.source == "live" {
            let apiPercent = limitState.apiPercentUsed ?? 0.0
            let totalPercent = limitState.totalPercentUsed ?? 0.0
            
            cursorAPILimitView.updateRaw(
                title: String(format: "API Limit: %.1f%% used", apiPercent),
                usedPercent: apiPercent,
                color: apiPercent >= 80.0 ? .systemRed : (apiPercent >= 50.0 ? .systemOrange : .systemCyan)
            )
            
            cursorTotalLimitView.updateRaw(
                title: String(format: "Total Limit: %.1f%% used", totalPercent),
                usedPercent: totalPercent,
                color: totalPercent >= 80.0 ? .systemRed : (totalPercent >= 50.0 ? .systemOrange : .systemGreen)
            )
            
            let spend = limitState.totalSpendUSD.map { String(format: "$%.2f", $0) } ?? "-"
            let limit = limitState.limitUSD.map { String(format: "$%.2f", $0) } ?? "-"
            let included = limitState.includedSpendUSD.map { String(format: "$%.2f", $0) } ?? "-"
            cursorSpendLabel.stringValue = "Spend: \(spend) / \(limit) (Included: \(included))"
            
            let tokens = limitState.totalTokens.map { formatTokenCount($0) } ?? "-"
            let requests = limitState.totalRequests.map { "\($0) reqs" } ?? "-"
            cursorTokensLabel.stringValue = "Tokens: \(tokens) (\(requests))"
        } else {
            cursorAPILimitView.updateRaw(title: "API Limit: -", usedPercent: 0.0, color: .secondaryLabelColor)
            cursorTotalLimitView.updateRaw(title: "Total Limit: -", usedPercent: 0.0, color: .secondaryLabelColor)
            cursorSpendLabel.stringValue = "Spend: -"
            cursorTokensLabel.stringValue = "Tokens: -"
        }
        
        needsLayout = true
        needsDisplay = true
    }

    private func formatActivityAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remainingMins = minutes % 60
        return "\(hours)h \(remainingMins)m ago"
    }

    // MARK: - Layout

    private static func formattedCodexTitle(isCompleted: Bool, modelName: String?) -> String {
        let base = isCompleted ? "Token Usage ✓" : "Token Usage"
        guard let modelName, !modelName.isEmpty else {
            return base
        }
        return "\(base) · \(modelName)"
    }

    override func layout() {
        super.layout()
        let outerInset: CGFloat = 14
        surfaceView.frame = NSRect(x: outerInset, y: 0, width: bounds.width - outerInset * 2, height: bounds.height)

        let inset: CGFloat = 20
        let tabHeight: CGFloat = 22
        let tabY = surfaceView.bounds.height - inset - tabHeight
        tabControl.frame = NSRect(x: inset, y: tabY, width: surfaceView.bounds.width - inset * 2, height: tabHeight)

        let panelTop: CGFloat
        if tabControl.isHidden {
            panelTop = surfaceView.bounds.height - 8
        } else {
            panelTop = tabY - 8
        }
        let panelHeight = panelTop
        let panelFrame = NSRect(x: 0, y: 0, width: surfaceView.bounds.width, height: panelHeight)
        codexPanel.frame = panelFrame
        cursorPanel.frame = panelFrame
        agPanel.frame = panelFrame

        layoutCodexPanel(inset: inset, panelHeight: panelHeight)
        layoutCursorPanel(inset: inset, panelHeight: panelHeight)
        layoutAGPanel(inset: inset, panelHeight: panelHeight)
    }

    private func layoutCodexPanel(inset: CGFloat, panelHeight: CGFloat) {
        let contentWidth = codexPanel.bounds.width - inset * 2
        let leftWidth = min(300, max(250, contentWidth * 0.63))
        let rightWidth = contentWidth - leftWidth - 18
        let leftX = inset
        let rightX = leftX + leftWidth + 18
        var leftTop = panelHeight - 4
        var rightTop = panelHeight - 4

        titleLabel.frame = NSRect(x: leftX, y: leftTop - 20, width: contentWidth, height: 20)
        leftTop -= 18
        contextWindowLabel.frame = NSRect(x: leftX, y: leftTop - 14, width: leftWidth, height: 14)
        leftTop -= 22
        rightTop -= 34

        elapsedLabel.frame = NSRect(x: leftX, y: leftTop - 16, width: leftWidth, height: 16)
        leftTop -= 20
        tokensLabel.frame = NSRect(x: leftX, y: leftTop - 16, width: leftWidth, height: 16)
        leftTop -= 24
        graphCaptionLabel.frame = NSRect(x: leftX, y: leftTop - 14, width: leftWidth, height: 14)
        leftTop -= 20
        graphView.frame = NSRect(x: leftX, y: leftTop - 24, width: leftWidth, height: 24)
        leftTop -= 36
        fiveHourLimitView.frame = NSRect(x: leftX, y: leftTop - 22, width: leftWidth, height: 22)
        leftTop -= 28
        weeklyLimitView.frame = NSRect(x: leftX, y: leftTop - 22, width: leftWidth, height: 22)

        todayUsageView.frame = NSRect(x: rightX, y: rightTop - 70, width: rightWidth, height: 64)
        rightTop -= 84
        weekUsageView.frame = NSRect(x: rightX, y: rightTop - 70, width: rightWidth, height: 64)
    }

    private func layoutCursorPanel(inset: CGFloat, panelHeight: CGFloat) {
        let contentWidth = cursorPanel.bounds.width - inset * 2
        var top = panelHeight - 4

        cursorTitleLabel.frame = NSRect(x: inset, y: top - 20, width: contentWidth, height: 20)
        top -= 28
        cursorStatusLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        cursorLastActivityLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        cursorSpendLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        cursorTokensLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        cursorAPILimitView.frame = NSRect(x: inset, y: top - 22, width: contentWidth, height: 22)
        top -= 28
        cursorTotalLimitView.frame = NSRect(x: inset, y: top - 22, width: contentWidth, height: 22)
    }

    private func layoutAGPanel(inset: CGFloat, panelHeight: CGFloat) {
        let contentWidth = agPanel.bounds.width - inset * 2
        var top = panelHeight - 4

        agTitleLabel.frame = NSRect(x: inset, y: top - 20, width: contentWidth, height: 20)
        top -= 28
        agStatusLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        agLastActivityLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        agActiveConvLabel.frame = NSRect(x: inset, y: top - 16, width: contentWidth, height: 16)
        top -= 22
        agTotalConvLabel.frame = NSRect(x: inset, y: top - 14, width: contentWidth, height: 14)
        top -= 22
        agActivityBar.frame = NSRect(x: inset, y: top - 22, width: contentWidth, height: 22)
    }

    private static func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }
}

private final class UsageMetricBlockView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var fillRatio: Double = 0
    private var fillColor = NSColor.systemBlue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        [titleLabel, valueLabel, subtitleLabel].forEach { label in
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, value: String, subtitle: String, fillRatio: Double, fillColor: NSColor) {
        titleLabel.stringValue = title
        valueLabel.stringValue = value
        subtitleLabel.stringValue = subtitle
        self.fillRatio = min(max(fillRatio, 0), 1)
        self.fillColor = fillColor
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 14, width: bounds.width, height: 14)
        valueLabel.frame = NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 16)
        subtitleLabel.frame = NSRect(x: 0, y: 18, width: bounds.width, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let trackRect = CGRect(x: 0, y: 2, width: bounds.width, height: 6)
        context.setFillColor(NSColor.separatorColor.withAlphaComponent(0.28).cgColor)
        context.addPath(CGPath(roundedRect: trackRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()

        let fillWidth = max(0, min(trackRect.width, trackRect.width * CGFloat(fillRatio)))
        let fillRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
        context.setFillColor(fillColor.cgColor)
        context.addPath(CGPath(roundedRect: fillRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }
}

private final class LimitUsageBarView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var usedPercent: Double?
    private var fillColor = NSColor.systemGreen

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, bucket: LimitBucket?, tokenText: String?) {
        guard let bucket else {
            titleLabel.stringValue = "\(title): -"
            usedPercent = nil
            needsDisplay = true
            return
        }

        let used = min(max(bucket.usedPercent, 0), 100)
        usedPercent = used
        fillColor = colorForRemaining(bucket.remainingPercent)
        if let tokenText, !tokenText.isEmpty {
            titleLabel.stringValue = "\(title): \(Int(round(bucket.remainingPercent)))% left, \(Int(round(used)))% used • \(tokenText)"
        } else {
            titleLabel.stringValue = "\(title): \(Int(round(bucket.remainingPercent)))% left, \(Int(round(used)))% used"
        }
        needsLayout = true
        needsDisplay = true
    }

    /// LimitBucket 없이 직접 percent 값과 색상으로 바를 업데이트합니다 (AGY 활동 바용).
    func updateRaw(title: String, usedPercent: Double, color: NSColor) {
        titleLabel.stringValue = title
        self.usedPercent = min(max(usedPercent, 0), 100)
        fillColor = color
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 13, width: bounds.width, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let trackRect = CGRect(x: 0, y: 1, width: bounds.width, height: 6)
        context.setFillColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        context.addPath(CGPath(roundedRect: trackRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()

        guard let usedPercent else {
            return
        }

        let fillWidth = max(0, min(trackRect.width, trackRect.width * CGFloat(usedPercent / 100.0)))
        let fillRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
        context.setFillColor(fillColor.cgColor)
        context.addPath(CGPath(roundedRect: fillRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }

    private func colorForRemaining(_ remaining: Double) -> NSColor {
        switch remaining {
        case 50...:
            return .systemGreen
        case 20..<50:
            return .systemOrange
        default:
            return .systemRed
        }
    }
}

private final class TokenUsageGraphView: NSView {
    private var buckets: [Int] = Array(repeating: 0, count: 30)
    private var windowEnd: Date = Date()
    private var trackingAreaRef: NSTrackingArea?
    private let tooltipPopover = NSPopover()
    private let tooltipViewController = GraphTooltipViewController()
    private var lastHoveredIndex: Int?

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.18).cgColor
        tooltipPopover.behavior = .transient
        tooltipPopover.contentSize = NSSize(width: 180, height: 56)
        tooltipPopover.contentViewController = tooltipViewController
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    func update(buckets: [Int], windowEnd: Date) {
        self.buckets = buckets
        self.windowEnd = windowEnd
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastHoveredIndex = nil
        tooltipPopover.performClose(nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = bucketIndex(at: point) else {
            if lastHoveredIndex != nil {
                lastHoveredIndex = nil
                tooltipPopover.performClose(nil)
                needsDisplay = true
            }
            return
        }

        guard index != lastHoveredIndex else {
            return
        }
        lastHoveredIndex = index
        let tooltip = tooltipText(for: index)
        tooltipViewController.update(title: tooltip.title, body: tooltip.body)
        let anchor = barRect(for: index).insetBy(dx: -1, dy: -1)
        if tooltipPopover.isShown {
            tooltipPopover.performClose(nil)
        }
        tooltipPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let rect = bounds.insetBy(dx: 1, dy: 2)
        let maxValue = buckets.max() ?? 0

        context.setFillColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 1))

        for (index, _) in buckets.enumerated() {
            let barRect = barRect(for: index)
            let color: NSColor = maxValue > 0 ? (index == lastHoveredIndex ? .systemTeal : .systemBlue) : .secondaryLabelColor
            context.setFillColor(color.cgColor)
            let path = CGPath(roundedRect: barRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
    }

    private func bucketIndex(at point: NSPoint) -> Int? {
        let rect = plotRect()
        guard rect.contains(point), !buckets.isEmpty else {
            return nil
        }

        let count = buckets.count
        let gap: CGFloat = 1.0
        let barWidth = max(1.0, (rect.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let localX = point.x - rect.minX
        let step = barWidth + gap
        let index = Int(localX / step)
        guard index >= 0, index < count else {
            return nil
        }

        let barStart = CGFloat(index) * step
        guard localX >= barStart, localX <= barStart + barWidth else {
            return nil
        }
        return index
    }

    private func barRect(for index: Int) -> CGRect {
        let rect = plotRect()
        let count = max(buckets.count, 1)
        let gap: CGFloat = 1.0
        let barWidth = max(1.0, (rect.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let maxValue = buckets.max() ?? 0
        let value = index < buckets.count ? buckets[index] : 0
        let ratio = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
        let height = max(2, rect.height * ratio)
        let x = rect.minX + CGFloat(index) * (barWidth + gap)
        return CGRect(x: x, y: rect.minY, width: barWidth, height: height)
    }

    private func plotRect() -> CGRect {
        bounds.insetBy(dx: 1, dy: 2)
    }

    private func tooltipText(for index: Int) -> (title: String, body: String) {
        let totalCount = buckets.indices.contains(index) ? buckets[index] : 0
        let windowSeconds: TimeInterval = 5 * 60 * 60
        let bucketCount = max(buckets.count, 1)
        let bucketWidth = windowSeconds / Double(bucketCount)
        let windowStart = windowEnd.timeIntervalSince1970 - windowSeconds
        let start = Date(timeIntervalSince1970: windowStart + Double(index) * bucketWidth)
        let end = Date(timeIntervalSince1970: windowStart + Double(index + 1) * bucketWidth)

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)

        return (
            title: "\(startText) - \(endText)",
            body: "\(totalCount) tokens"
        )
    }
}

private final class GraphTooltipViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 56))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.98).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byTruncatingTail

        [titleLabel, bodyLabel].forEach { label in
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            view.addSubview(label)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let inset: CGFloat = 12
        titleLabel.frame = NSRect(x: inset, y: 31, width: view.bounds.width - inset * 2, height: 14)
        bodyLabel.frame = NSRect(x: inset, y: 12, width: view.bounds.width - inset * 2, height: 14)
    }

    func update(title: String, body: String) {
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        view.needsLayout = true
    }
}

private final class StatusPopupViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.98).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .systemOrange
        badgeLabel.stringValue = "WAITING"

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 3

        [badgeLabel, titleLabel, bodyLabel].forEach { label in
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            view.addSubview(label)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let inset: CGFloat = 16
        badgeLabel.frame = NSRect(x: inset, y: view.bounds.height - 28, width: view.bounds.width - inset * 2, height: 14)
        titleLabel.frame = NSRect(x: inset, y: view.bounds.height - 56, width: view.bounds.width - inset * 2, height: 22)
        bodyLabel.frame = NSRect(x: inset, y: 16, width: view.bounds.width - inset * 2, height: view.bounds.height - 72)
    }

    func update(presentation: StatusPopoverPresentation) {
        badgeLabel.stringValue = presentation.badge
        badgeLabel.textColor = presentation.badge == "INPUT REQUIRED" ? .systemOrange : .systemBlue
        titleLabel.stringValue = presentation.title
        bodyLabel.stringValue = presentation.body
        view.setFrameSize(presentation.contentSize)
        preferredContentSize = presentation.contentSize
        view.needsLayout = true
    }

    func update(status: String, detail: String) {
        if let presentation = statusPopoverPresentation(status: status, detail: detail) {
            update(presentation: presentation)
            return
        }
        badgeLabel.stringValue = status.uppercased()
        badgeLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = "Codex"
        bodyLabel.stringValue = detail
        view.needsLayout = true
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}

@MainActor
final class CodexMenuBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let isoFormatter = ISO8601DateFormatter()
    private var settings = AppSettings.defaults()
    private var timer: Timer?
    private var currentPayload: StatusPayload?
    private var currentLimitState = LimitState.empty
    private var currentTokenUsageStats = TokenUsageSummary.empty
    private var currentModelName: String?
    private var currentContextWindow: Int?
    private let statusTransitionHooks = CodexStatusTransitionHooks()
    private let menuIconRenderer = CodexMenuBarIconRenderer()
    private var lastLimitRefresh = Date.distantPast
    private var isRefreshingLimits = false
    private var manualPayload: StatusPayload?
    private var effectiveSource = "auto"
    private var latestCodexActivity: Date?
    private var autoStartedAt: Date?
    private var settingsWindow: NSWindow?
    private var autoWatchCheckbox: NSButton?
    private var agWatchCheckbox: NSButton?
    private var cursorWatchCheckbox: NSButton?
    private var autoUpdateCheckbox: NSButton?
    private var activeWindowField: NSTextField?
    private var pollIntervalField: NSTextField?
    private var weeklyLimitField: NSTextField?
    private var fiveHourLimitField: NSTextField?
    private let usageSummaryView = UsageSummaryCardView()
    private let statusPopover = NSPopover()
    private let statusPopupViewController = StatusPopupViewController()
    private var lastPopupStatus: String?
    private var lockFileDescriptor: Int32 = -1
    private var frameIndex = 0
    private var animationTimer: Timer?
    private var attentionAcknowledgedAt: Date?
    private var isCheckingForUpdates = false
    private var isDownloadingUpdate = false
    private var availableUpdateVersion: String?
    private var availableUpdateURL: URL?
    private var updateCheckTimer: Timer?

    // MARK: - Antigravity
    private var currentAntigravitySnapshot = AntigravityActivitySnapshot.empty
    private var latestAntigravityActivity: Date?

    // MARK: - Cursor
    private var currentCursorSnapshot = CursorActivitySnapshot.empty
    private var latestCursorActivity: Date?
    private var currentCursorLimitState = CursorLimitState.empty
    private var lastCursorLimitRefresh = Date.distantPast
    private var isRefreshingCursorLimits = false
    private let cursorLimitRefreshInterval: TimeInterval = 300 // 5 minutes

    private let frames = ["|", "/", "-", "\\"]
    private let limitRefreshInterval: TimeInterval = 20
    private let animationFrameInterval: TimeInterval = 0.2

    private var statusFile: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_MENU_BAR_STATUS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return appSupportDirectory
            .appendingPathComponent("status.json")
    }

    private var settingsFile: URL {
        appSupportDirectory
            .appendingPathComponent("settings.json")
    }

    private var lockFile: URL {
        appSupportDirectory
            .appendingPathComponent("CodexMenuBar.lock")
    }

    private var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-menu-bar")
    }

    private var codexActivityFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = home.appendingPathComponent(".codex")
        return [
            codex.appendingPathComponent("state_5.sqlite"),
        ]
    }

    private var codexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    private var antigravityHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
            .appendingPathComponent("antigravity")
    }

    private var cursorHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor")
    }

    private var modelsCacheFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("models_cache.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        settings = readSettings()
        statusPopover.behavior = .transient
        statusPopover.contentSize = NSSize(width: 260, height: 110)
        statusPopover.contentViewController = statusPopupViewController
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        configureMenu()
        refresh()
        scheduleTimer()
        scheduleAnimationTimerIfNeeded()

        // Schedule background update check 5 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            Task { @MainActor in
                self?.checkForUpdates(isUserInitiated: false)
            }
        }
        // Schedule background update check every 12 hours
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForUpdates(isUserInitiated: false)
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: settings.pollIntervalSeconds,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    private func scheduleAnimationTimerIfNeeded() {
        if shouldAnimateMenuBarIcon() {
            if animationTimer == nil {
                let timer = Timer.scheduledTimer(
                    timeInterval: animationFrameInterval,
                    target: self,
                    selector: #selector(animationTimerFired(_:)),
                    userInfo: nil,
                    repeats: true
                )
                RunLoop.main.add(timer, forMode: .common)
                animationTimer = timer
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        releaseSingleInstanceLock()
    }

    @objc private func timerFired(_ timer: Timer) {
        refresh()
    }

    @objc private func animationTimerFired(_ timer: Timer) {
        guard shouldAnimateMenuBarIcon() else {
            scheduleAnimationTimerIfNeeded()
            return
        }
        frameIndex = (frameIndex + 1) % frames.count
        updateMenuBarIcon()
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            codexMenuBarIsCodexApplication(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
        else {
            return
        }
        acknowledgeAttentionStatus()
    }

    private func acknowledgeAttentionStatus() {
        let currentKind = CodexStatusKind(status: currentPayload?.status ?? "idle")
        if codexMenuBarStatusCanBeAcknowledged(currentKind) || isRecentlyCompleted() {
            attentionAcknowledgedAt = Date()
            refresh()
        }
    }

    // Menu item index constants
    // 0:  header "Codex Menu Bar"
    // 1:  separator
    // 2:  summary card
    // 3:  "Codex Status: -"
    // 4:  "Detail: -"
    // 5:  "Source: -"
    // 6:  "Last Activity: -"
    // 7:  "Updated: -"
    // 8:  separator
    // 9:  "5-hour limit: -"
    // 10: "Weekly limit: -"
    // 11: "Limit source: -"
    // 12: separator
    // 13: "AGY: -" (header)
    // 14: "AGY Activity: -"
    // 15: "AGY Conversations: -"
    // 16: separator
    // 17: Settings...
    // 18: Open Status File
    // 19: Reveal Status Folder
    // 20: Restart
    // 21: Quit
    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        menu.addItem(NSMenuItem(title: "🔄 Check for Updates...", action: #selector(checkForUpdatesManually), keyEquivalent: "")) // 0
        menu.addItem(NSMenuItem.separator())                                                         // 1
        
        let headerItem = NSMenuItem(title: "Codex Menu Bar", action: #selector(openGitHub), keyEquivalent: "")
        headerItem.isEnabled = true
        menu.addItem(headerItem)                                                                     // 2
        menu.addItem(NSMenuItem.separator())                                                         // 3
        
        let summaryItem = NSMenuItem()
        summaryItem.isEnabled = false
        summaryItem.view = usageSummaryView
        menu.addItem(summaryItem)                                                                    // 4
        
        menu.addItem(NSMenuItem(title: "Codex Status: -", action: nil, keyEquivalent: ""))         // 5
        menu.addItem(NSMenuItem(title: "Detail: -", action: nil, keyEquivalent: ""))               // 6
        menu.addItem(NSMenuItem(title: "Source: -", action: nil, keyEquivalent: ""))               // 7
        menu.addItem(NSMenuItem(title: "Last Activity: -", action: nil, keyEquivalent: ""))        // 8
        menu.addItem(NSMenuItem(title: "Updated: -", action: nil, keyEquivalent: ""))              // 9
        menu.addItem(NSMenuItem.separator())                                                         // 10
        menu.addItem(NSMenuItem(title: "5-hour limit: -", action: nil, keyEquivalent: ""))         // 11
        menu.addItem(NSMenuItem(title: "Weekly limit: -", action: nil, keyEquivalent: ""))         // 12
        menu.addItem(NSMenuItem(title: "Limit source: -", action: nil, keyEquivalent: ""))         // 13
        menu.addItem(NSMenuItem.separator())                                                         // 14
        menu.addItem(NSMenuItem(title: "AGY: -", action: nil, keyEquivalent: ""))                  // 15
        menu.addItem(NSMenuItem(title: "AGY Activity: -", action: nil, keyEquivalent: ""))         // 16
        menu.addItem(NSMenuItem(title: "AGY Conversations: -", action: nil, keyEquivalent: ""))    // 17
        menu.addItem(NSMenuItem.separator())                                                         // 18
        
        menu.addItem(NSMenuItem(title: "Cursor: -", action: nil, keyEquivalent: ""))               // 19
        menu.addItem(NSMenuItem(title: "Cursor Activity: -", action: nil, keyEquivalent: ""))      // 20
        menu.addItem(NSMenuItem(title: "Cursor Quota: -", action: nil, keyEquivalent: ""))         // 21
        menu.addItem(NSMenuItem.separator())                                                         // 22
        
        menu.addItem(NSMenuItem(title: "GitHub Repository...", action: #selector(openGitHub), keyEquivalent: "")) // 23
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))         // 24
        menu.addItem(NSMenuItem(title: "Open Status File", action: #selector(openStatusFile), keyEquivalent: "o")) // 25
        menu.addItem(NSMenuItem(title: "Reveal Status Folder", action: #selector(revealStatusFolder), keyEquivalent: "r")) // 26
        menu.addItem(NSMenuItem.separator())                                                         // 27
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "R")) // 28
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))       // 29
        statusItem.menu = menu
    }

    private func refresh() {
        manualPayload = readPayload()
        currentPayload = resolvePayload(manualPayload)
        refreshLimitStateIfNeeded()
        refreshAntigravitySnapshot()
        refreshCursorSnapshot()
        refreshCursorLimitStateIfNeeded()
        frameIndex = (frameIndex + 1) % frames.count
        updateMenuBarIcon()
        updateMenu()
    }

    private func refreshAntigravitySnapshot() {
        guard settings.antigravityWatchEnabled else {
            if currentAntigravitySnapshot.lastActivityDate != nil {
                currentAntigravitySnapshot = .empty
                latestAntigravityActivity = nil
            }
            return
        }
        let reader = AntigravityActivityReader(antigravityHome: antigravityHome)
        let snapshot = reader.readSnapshot(activeWindowSeconds: settings.activeWindowSeconds)
        currentAntigravitySnapshot = snapshot
        latestAntigravityActivity = snapshot.lastActivityDate
    }

    private func refreshCursorSnapshot() {
        guard settings.cursorWatchEnabled else {
            if currentCursorSnapshot.lastUserActivityDate != nil {
                currentCursorSnapshot = .empty
                latestCursorActivity = nil
            }
            return
        }
        let reader = CursorActivityReader(cursorHome: cursorHome)
        let snapshot = reader.readSnapshot(activeWindowSeconds: settings.activeWindowSeconds)
        currentCursorSnapshot = snapshot
        latestCursorActivity = [snapshot.lastUserActivityDate, snapshot.lastAgentActivityDate].compactMap { $0 }.max()
    }

    private func refreshCursorLimitStateIfNeeded(force: Bool = false) {
        let now = Date()
        let isCursorAppRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").first != nil
        let wasRecentlyActive = latestCursorActivity.map { now.timeIntervalSince($0) <= 300.0 } == true
        
        guard isCursorAppRunning || wasRecentlyActive else {
            return
        }
        
        guard force || now.timeIntervalSince(lastCursorLimitRefresh) >= cursorLimitRefreshInterval else {
            return
        }
        guard !isRefreshingCursorLimits else {
            return
        }

        isRefreshingCursorLimits = true
        lastCursorLimitRefresh = now
        let reader = CursorLimitReader(cursorHome: cursorHome)

        DispatchQueue.global(qos: .utility).async { [reader] in
            let state = reader.readLiveUsage() ?? .empty
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentCursorLimitState = state
                self.isRefreshingCursorLimits = false
                self.updateMenuBarIcon()
                self.updateMenu()
            }
        }
    }

    private func refreshLimitStateIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastLimitRefresh) >= limitRefreshInterval else {
            return
        }
        guard !isRefreshingLimits else {
            return
        }

        isRefreshingLimits = true
        lastLimitRefresh = now
        let reader = LimitStateReader(codexHome: codexHome)
        let modelNameAtRefresh = currentPayload?.model ?? currentModelName

        DispatchQueue.global(qos: .utility).async { [reader] in
            let state = reader.readLatest()
            let tokenUsageStats = reader.readTokenUsageStats()
            let modelName = reader.readCurrentModelName()
            let contextWindow = reader.readCurrentContextWindow(for: modelName ?? modelNameAtRefresh)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentLimitState = state
                self.currentTokenUsageStats = tokenUsageStats
                self.currentModelName = modelName ?? self.currentPayload?.model ?? self.currentModelName
                self.currentContextWindow = contextWindow ?? self.currentPayload?.contextWindow ?? self.currentContextWindow
                self.isRefreshingLimits = false
                self.updateMenuBarIcon()
                self.updateMenu()
            }
        }
    }

    private func readPayload() -> StatusPayload? {
        guard let data = try? Data(contentsOf: statusFile) else {
            return nil
        }
        return try? decoder.decode(StatusPayload.self, from: data)
    }

    private func readSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings.defaults()
        }
        return decoded.sanitized()
    }

    private func writeSettings() {
        ensureStatusDirectory()
        guard let data = try? encoder.encode(settings.sanitized()) else {
            return
        }
        try? data.write(to: settingsFile, options: .atomic)
    }

    private func acquireSingleInstanceLock() -> Bool {
        ensureStatusDirectory()
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let existingPID = existingInstancePID()
            terminateExistingInstance(pid: existingPID, signal: SIGTERM)
            if !waitForLock(fd) {
                terminateExistingInstance(pid: existingPID, signal: SIGKILL)
                if !waitForLock(fd) {
                    close(fd)
                    return false
                }
            }
        }

        lockFileDescriptor = fd
        let pidText = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pidText.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        return true
    }

    private func waitForLock(_ fd: Int32) -> Bool {
        for _ in 0..<30 {
            usleep(100_000)
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return true
            }
        }
        return false
    }

    private func existingInstancePID() -> Int32? {
        guard
            let pidText = try? String(contentsOf: lockFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(pidText),
            pid > 0,
            pid != getpid()
        else {
            return nil
        }
        return pid
    }

    private func terminateExistingInstance(pid: Int32?, signal: Int32) {
        guard let pid else {
            return
        }
        if kill(pid, 0) == 0 {
            kill(pid, signal)
        }
    }

    private func releaseSingleInstanceLock() {
        guard lockFileDescriptor >= 0 else {
            return
        }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func resolvePayload(_ manual: StatusPayload?) -> StatusPayload {
        let now = Date()
        let activity = latestCodexActivityDate()
        latestCodexActivity = activity

        let autoActive = settings.autoWatchEnabled
            && activity.map { now.timeIntervalSince($0) <= settings.activeWindowSeconds } == true
            && !statusTransitionHooks.shouldSuppressAutoActive(at: now)

        if autoActive {
            if autoStartedAt == nil {
                autoStartedAt = activity ?? now
            }
        } else {
            autoStartedAt = nil
        }

        let manualStatus = manual?.status?.lowercased()
        let manualKind = CodexStatusKind(status: manualStatus ?? "idle")
        if let manual {
            switch manualKind {
            case .running, .waiting, .message, .error, .awaitingApproval, .completed:
                if codexMenuBarStatusCanBeAcknowledged(manualKind),
                   codexMenuBarAttentionStatusIsAcknowledged(
                       statusAt: manualUpdatedDate(manual),
                       acknowledgedAt: attentionAcknowledgedAt
                   )
                {
                    effectiveSource = "manual"
                    let resolved = StatusPayload(
                        status: "idle",
                        detail: "Ready",
                        thread: manual.thread,
                        progress: manual.progress,
                        updatedAt: manual.updatedAt ?? isoFormatter.string(from: now),
                        startedAt: nil,
                        model: manual.model,
                        contextWindow: manual.contextWindow,
                        tokenUsage: manual.tokenUsage
                    )
                    _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "idle", at: now)
                    return resolved
                }
                effectiveSource = "manual"
                let resolvedStatus = canonicalStatusText(for: manualKind)
                let manualDetail = manual.detail ?? ""
                let resolved = StatusPayload(
                    status: resolvedStatus,
                    detail: manualDetail.isEmpty ? defaultDetail(for: resolvedStatus) : manualDetail,
                    thread: manual.thread,
                    progress: manual.progress,
                    updatedAt: manual.updatedAt ?? isoFormatter.string(from: now),
                    startedAt: manual.startedAt ?? autoStartedAt.map { isoFormatter.string(from: $0) },
                    model: manual.model,
                    contextWindow: manual.contextWindow,
                    tokenUsage: manual.tokenUsage
                )
                _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "running", at: now)
                return resolved
            case .idle:
                break
            }
        }

        if settings.autoWatchEnabled {
            let runtimeReader = LimitStateReader(codexHome: codexHome)
            if let runtimeSnapshot = runtimeReader.readRuntimeSignalSnapshot(),
               let runtimeKind = codexResolvedRuntimeStatus(from: runtimeSnapshot) {
                let runtimeStatus = canonicalStatusText(for: runtimeKind)
                let runtimeDetail = defaultDetail(for: runtimeStatus)
                let runtimeDate = [
                    runtimeSnapshot.runningAt,
                    runtimeSnapshot.approvalAt,
                    runtimeSnapshot.completedAt,
                    runtimeSnapshot.waitingAt,
                    runtimeSnapshot.messageAt,
                    runtimeSnapshot.errorAt
                ].compactMap { $0 }.max() ?? now

                if codexMenuBarStatusCanBeAcknowledged(runtimeKind),
                   codexMenuBarAttentionStatusIsAcknowledged(
                       statusAt: runtimeDate,
                       acknowledgedAt: attentionAcknowledgedAt
                   )
                {
                    effectiveSource = "auto"
                    let resolved = StatusPayload(
                        status: "idle",
                        detail: "Ready",
                        thread: manual?.thread,
                        progress: manual?.progress,
                        updatedAt: isoFormatter.string(from: runtimeDate),
                        startedAt: nil,
                        model: manual?.model,
                        contextWindow: manual?.contextWindow,
                        tokenUsage: manual?.tokenUsage
                    )
                    _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "idle", at: now)
                    return resolved
                }

                effectiveSource = "auto"
                let resolved = StatusPayload(
                    status: runtimeStatus,
                    detail: runtimeDetail,
                    thread: manual?.thread,
                    progress: manual?.progress,
                    updatedAt: isoFormatter.string(from: runtimeDate),
                    startedAt: runtimeKind == .running ? autoStartedAt.map { isoFormatter.string(from: $0) } : manual?.startedAt,
                    model: manual?.model,
                    contextWindow: manual?.contextWindow,
                    tokenUsage: manual?.tokenUsage
                )
                _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "idle", at: now)
                return resolved
            }
        }

        if autoActive {
            effectiveSource = "auto"
            let resolved = StatusPayload(
                status: "running",
                detail: "Codex activity detected",
                thread: manual?.thread,
                progress: manual?.progress,
                updatedAt: isoFormatter.string(from: activity ?? now),
                startedAt: autoStartedAt.map { isoFormatter.string(from: $0) },
                model: manual?.model,
                contextWindow: manual?.contextWindow,
                tokenUsage: manual?.tokenUsage
            )
            _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "running", at: now)
            return resolved
        }

        effectiveSource = manualStatus == "idle" ? "manual" : "auto"
        let resolved = StatusPayload(
            status: "idle",
            detail: manual?.detail ?? "Ready",
            thread: manual?.thread,
            progress: manual?.progress,
            updatedAt: manual?.updatedAt,
            startedAt: nil,
            model: manual?.model,
            contextWindow: manual?.contextWindow,
            tokenUsage: manual?.tokenUsage
        )
        _ = statusTransitionHooks.recordResolvedStatus(resolved.status ?? "idle", at: now)
        return resolved
    }

    private func canonicalStatusText(for kind: CodexStatusKind) -> String {
        switch kind {
        case .running:
            return "running"
        case .idle:
            return "idle"
        case .waiting:
            return "waiting"
        case .message:
            return "message"
        case .error:
            return "error"
        case .awaitingApproval:
            return "awaiting approval"
        case .completed:
            return "completed"
        }
    }

    private func defaultDetail(for status: String) -> String {
        switch status {
        case "running":
            return "Codex is working"
        case "waiting":
            return "Codex is waiting for input"
        case "message":
            return "Codex has a message"
        case "error":
            return "Codex needs attention"
        case "awaiting approval":
            return "Codex is awaiting approval"
        case "completed":
            return "Codex completed"
        default:
            return "Codex is idle"
        }
    }

    private func latestCodexActivityDate() -> Date? {
        codexActivityFiles
            .compactMap { fileModificationDate($0) }
            .max()
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private func manualUpdatedDate(_ payload: StatusPayload?) -> Date? {
        if let updatedAt = payload?.updatedAt, let parsed = parseISODate(updatedAt) {
            return parsed
        }
        return fileModificationDate(statusFile)
    }

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

    private func shouldAnimateMenuBarIcon() -> Bool {
        let status = currentPayload?.status?.lowercased() ?? "idle"
        if codexMenuBarIconKind(status: status, isRecentlyCompleted: isRecentlyCompleted()) != .idle {
            return true
        }

        let now = Date()
        let agActive = settings.antigravityWatchEnabled
            && currentAntigravitySnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
        if agActive {
            return true
        }

        if settings.antigravityWatchEnabled,
           let agStatus = currentPayload?.antigravity?.status?.lowercased(),
           agStatus == "awaiting approval" || agStatus == "running" {
            return true
        }
        
        let cursorActive = settings.cursorWatchEnabled
            && currentCursorSnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
        if cursorActive {
            return true
        }

        return false
    }

    private func updateMenu() {
        guard let menu = statusItem.menu else { return }
        let status = currentPayload?.status ?? "idle"
        let detail = currentPayload?.detail ?? "Ready"
        let updated = formattedUpdatedAt(currentPayload?.updatedAt)
        let activity = activityText()
        let completionText = isRecentlyCompleted() ? "Completed" : status.capitalized
        let now = Date()

        // Update header to reflect combined state
        let agActive = currentAntigravitySnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
        let cursorActive = currentCursorSnapshot.isActive(activeWindowSeconds: settings.activeWindowSeconds, now: now)
        
        let baseHeaderTitle: String
        if agActive && cursorActive && status != "idle" {
            baseHeaderTitle = "Codex+AGY+Cursor"
        } else if agActive && cursorActive {
            baseHeaderTitle = "AGY + Cursor"
        } else if cursorActive && status != "idle" {
            baseHeaderTitle = "Codex + Cursor"
        } else if cursorActive {
            baseHeaderTitle = "Cursor Running"
        } else if agActive && status != "idle" {
            baseHeaderTitle = "Codex + AGY"
        } else if agActive {
            baseHeaderTitle = "AGY Running"
        } else {
            baseHeaderTitle = "Codex Menu Bar"
        }
        let headerTitle = "\(baseHeaderTitle) v\(currentVersion) (\(buildDate)) by choihunchul"
        menu.item(at: 2)?.title = headerTitle

        if let summaryItem = menu.item(at: 4) {
            summaryItem.view = usageSummaryView
        }

        usageSummaryView.configureTabs(
            antigravityEnabled: settings.antigravityWatchEnabled,
            cursorEnabled: settings.cursorWatchEnabled
        )

        usageSummaryView.update(
            elapsed: elapsedText(),
            tokens: tokenText(),
            buckets: currentTokenUsageStats.buckets,
            todayTokens: currentTokenUsageStats.todayTotal,
            weekTokens: currentTokenUsageStats.weekTotal,
            fiveHourTokens: currentTokenUsageStats.fiveHourTotal,
            weeklyTokens: currentTokenUsageStats.weekTotal,
            fiveHourLimit: currentLimitState.primary,
            weeklyLimit: currentLimitState.secondary,
            bucketWindowEnd: currentTokenUsageStats.observedAt,
            modelName: currentPayload?.model ?? currentModelName,
            contextWindow: currentPayload?.contextWindow ?? currentContextWindow,
            isCompleted: isRecentlyCompleted()
        )

        usageSummaryView.updateAntigravity(
            snapshot: currentAntigravitySnapshot,
            activeWindowSeconds: settings.activeWindowSeconds,
            now: now
        )

        usageSummaryView.updateCursor(
            snapshot: currentCursorSnapshot,
            limitState: currentCursorLimitState,
            activeWindowSeconds: settings.activeWindowSeconds,
            now: now
        )

        menu.item(at: 5)?.title = "Codex Status: \(completionText)"
        menu.item(at: 6)?.title = "Detail: \(detail)"
        menu.item(at: 7)?.title = "Source: \(effectiveSource)"
        menu.item(at: 8)?.title = "Last Activity: \(activity)"
        menu.item(at: 9)?.title = "Updated: \(updated)"
        menu.item(at: 11)?.title = "5-hour limit: \(limitDetailText(currentLimitState.primary, fallback: settings.fiveHourLimitText))"
        menu.item(at: 12)?.title = "Weekly limit: \(limitDetailText(currentLimitState.secondary, fallback: settings.weeklyLimitText))"
        menu.item(at: 13)?.title = "Limit source: \(currentLimitState.source)"

        // AGY section visibility and update
        let showAGY = settings.antigravityWatchEnabled
        menu.item(at: 14)?.isHidden = !showAGY
        menu.item(at: 15)?.isHidden = !showAGY
        menu.item(at: 16)?.isHidden = !showAGY
        menu.item(at: 17)?.isHidden = !showAGY

        if showAGY {
            let agStatusText: String
            let agPayload = currentPayload?.antigravity
            let agStatus = agPayload?.status?.lowercased() ?? "idle"
            
            if agStatus == "running" || (agStatus == "idle" && agActive) {
                let count = currentAntigravitySnapshot.activeConversationCount
                agStatusText = "● Running (\(count) active)"
            } else if agStatus == "awaiting approval" {
                agStatusText = "🟡 Awaiting Approval"
            } else if agStatus == "completed" {
                agStatusText = "🟢 Completed"
            } else if let lastDate = currentAntigravitySnapshot.lastActivityDate {
                let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
                agStatusText = "○ Idle (last: \(formatActivityAgeShort(seconds)))"
            } else {
                agStatusText = "○ No activity detected"
            }
            menu.item(at: 15)?.title = "AGY: \(agStatusText)"
            
            if let detail = agPayload?.detail, !detail.isEmpty, agStatus != "idle" {
                menu.item(at: 16)?.title = "AGY Detail: \(detail)"
            } else {
                let agActivityText: String
                if let lastDate = currentAntigravitySnapshot.lastActivityDate {
                    let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
                    agActivityText = formatActivityAgeShort(seconds)
                } else {
                    agActivityText = "-"
                }
                menu.item(at: 16)?.title = "AGY Activity: \(agActivityText) ago"
            }
            menu.item(at: 17)?.title = "AGY Conversations: \(currentAntigravitySnapshot.totalConversationCount) total"
        }

        // Cursor section visibility and update
        let showCursor = settings.cursorWatchEnabled
        menu.item(at: 18)?.isHidden = !showCursor
        menu.item(at: 19)?.isHidden = !showCursor
        menu.item(at: 20)?.isHidden = !showCursor
        menu.item(at: 21)?.isHidden = !showCursor

        if showCursor {
            let cursorStatusText = cursorActive ? "● Running" : "○ Idle"
            menu.item(at: 19)?.title = "Cursor: \(cursorStatusText)"
            
            let cursorActivityText: String
            if let lastDate = latestCursorActivity {
                let seconds = max(0, Int(now.timeIntervalSince(lastDate)))
                cursorActivityText = "\(formatActivityAgeShort(seconds)) ago"
            } else {
                cursorActivityText = "-"
            }
            menu.item(at: 20)?.title = "Cursor Activity: \(cursorActivityText)"
            
            let quotaText: String
            if currentCursorLimitState.source == "live" {
                let apiUsed = currentCursorLimitState.apiPercentUsed.map { String(format: "%.1f%%", $0) } ?? "-"
                let totalUsed = currentCursorLimitState.totalPercentUsed.map { String(format: "%.1f%%", $0) } ?? "-"
                let spend = currentCursorLimitState.totalSpendUSD.map { String(format: "$%.2f", $0) } ?? "-"
                let limit = currentCursorLimitState.limitUSD.map { String(format: "$%.2f", $0) } ?? "-"
                let tokens = currentCursorLimitState.totalTokens.map { formatTokenCount($0) } ?? "-"
                let requests = currentCursorLimitState.totalRequests.map { "\($0) reqs" } ?? "-"
                
                quotaText = "\(apiUsed) API (\(totalUsed) total) | \(spend)/\(limit) | \(tokens) (\(requests))"
            } else {
                quotaText = "No quota data"
            }
            menu.item(at: 21)?.title = "Cursor Quota: \(quotaText)"
        }
    }

    private func formatActivityAgeShort(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMins = minutes % 60
        return "\(hours)h\(remainingMins)m"
    }

    private func limitDetailText(_ bucket: LimitBucket?, fallback: String?) -> String {
        guard let bucket else {
            return fallback ?? "-"
        }
        var pieces = [
            "\(formatPercent(bucket.remainingPercent)) left",
            "\(formatPercent(bucket.usedPercent)) used"
        ]
        if let reset = bucket.resetAt {
            let includeDate = (bucket.windowMinutes ?? 0) >= 24 * 60
            pieces.append("resets \(formatReset(reset, includeDate: includeDate))")
        }
        return pieces.joined(separator: ", ")
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int(round(value)))%"
    }

    private func formatReset(_ timestamp: TimeInterval, includeDate: Bool) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        if includeDate {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }

        let calendar = Calendar.current
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "today \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "tomorrow \(time)"
        }

        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func formattedUpdatedAt(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "-"
        }
        guard let date = parseISODate(value) else {
            return value
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func parseISODate(_ value: String) -> Date? {
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value)
    }

    private func tooltipText(for status: String, agActive: Bool = false) -> String {
        var parts: [String] = []

        if isRecentlyCompleted() && status == "idle" {
            if let detail = currentPayload?.detail, !detail.isEmpty {
                parts.append("Codex complete: \(detail)")
            } else {
                parts.append("Codex complete")
            }
        } else if let detail = currentPayload?.detail, !detail.isEmpty {
            parts.append("Codex \(status): \(detail)")
        } else {
            parts.append("Codex \(status)")
        }

        if agActive {
            let count = currentAntigravitySnapshot.activeConversationCount
            parts.append("AGY: \(count) active conversation\(count == 1 ? "" : "s")")
        }

        return parts.joined(separator: " · ")
    }

    private func updateStatusPopover(for status: String) {
        let detail = currentPayload?.detail ?? ""
        guard let presentation = statusPopoverPresentation(status: status, detail: detail) else {
            lastPopupStatus = nil
            if statusPopover.isShown {
                statusPopover.performClose(nil)
            }
            return
        }

        guard lastPopupStatus != status || !statusPopover.isShown else {
            return
        }
        lastPopupStatus = status
        statusPopupViewController.update(presentation: presentation)
        guard let button = statusItem.button else {
            return
        }

        statusPopover.contentSize = presentation.contentSize
        if !statusPopover.isShown {
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func isRecentlyCompleted() -> Bool {
        let status = CodexStatusKind(status: currentPayload?.status ?? "idle")
        let referenceDate = currentPayload?.startedAt.flatMap { parseISODate($0) }
            ?? currentTokenUsageStats.latestObservedAt
            ?? latestCodexActivity
        return codexMenuBarShouldShowRecentCompletion(
            status: status,
            referenceDate: referenceDate,
            acknowledgedAt: attentionAcknowledgedAt
        )
    }

    private func elapsedText() -> String {
        if let startedAt = currentPayload?.startedAt,
           let date = parseISODate(startedAt) {
            return formatDuration(since: date)
        }

        if let latestObservedAt = currentTokenUsageStats.latestObservedAt {
            return "latest turn \(formatDuration(since: latestObservedAt)) ago"
        }

        return "-"
    }

    private func formatDuration(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = seconds / 60
        let remainingMinutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainder)s"
        }
        return "\(remainder)s"
    }

    private func tokenText() -> String {
        if let latestDelta = currentTokenUsageStats.latestDelta {
            return "\(formatTokenCount(latestDelta)) latest / \(formatTokenCount(currentTokenUsageStats.fiveHourTotal)) 5h"
        }
        if let latestTotal = currentTokenUsageStats.latestTotal {
            return "\(formatTokenCount(latestTotal)) latest total / \(formatTokenCount(currentTokenUsageStats.fiveHourTotal)) 5h"
        }
        guard let usage = currentPayload?.tokenUsage else {
            return currentTokenUsageStats.fiveHourTotal > 0 ? "\(formatTokenCount(currentTokenUsageStats.fiveHourTotal)) 5h" : "-"
        }
        if let total = usage.totalTokens {
            return "\(formatTokenCount(total)) total"
        }
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        if input == 0 && output == 0 {
            return "-"
        }
        return "\(formatTokenCount(input)) in / \(formatTokenCount(output)) out"
    }

    private func tokenGraphText() -> String {
        let graph = sparkline(for: currentTokenUsageStats.buckets)
        let total = formatTokenCount(currentTokenUsageStats.fiveHourTotal)
        return "\(graph) \(total)"
    }

    private func sparkline(for buckets: [Int]) -> String {
        let levels = Array("▁▂▃▄▅▆▇█")
        guard let maxValue = buckets.max(), maxValue > 0 else {
            return String(repeating: "·", count: max(buckets.count, 30))
        }
        return buckets.map { value in
            if value <= 0 {
                return "▁"
            }
            let scaled = Double(value) / Double(maxValue)
            let index = min(levels.count - 1, max(0, Int(ceil(scaled * Double(levels.count))) - 1))
            return String(levels[index])
        }.joined()
    }

    private func formatTokenCount(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if absolute >= 10_000 {
            return "\(Int(round(Double(value) / 1_000.0)))k"
        }
        if absolute >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private func activityText() -> String {
        guard let latestCodexActivity else {
            return settings.autoWatchEnabled ? "-" : "disabled"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(latestCodexActivity)))
        return "\(seconds)s ago"
    }

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
        if let url = URL(string: "https://github.com/hunchulchoi/codex-menu-bar") {
            NSWorkspace.shared.open(url)
        }
    }

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

        let view = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 420, height: 410))

        let checkbox = NSButton(checkboxWithTitle: "Auto watch Codex activity", target: nil, action: nil)
        checkbox.frame = NSRect(x: 24, y: 356, width: 280, height: 24)
        checkbox.state = settings.autoWatchEnabled ? .on : .off
        view.addSubview(checkbox)
        autoWatchCheckbox = checkbox

        let agCheckbox = NSButton(checkboxWithTitle: "Auto watch Antigravity activity", target: nil, action: nil)
        agCheckbox.frame = NSRect(x: 24, y: 326, width: 280, height: 24)
        agCheckbox.state = settings.antigravityWatchEnabled ? .on : .off
        view.addSubview(agCheckbox)
        agWatchCheckbox = agCheckbox

        let cursorCheckbox = NSButton(checkboxWithTitle: "Auto watch Cursor activity", target: nil, action: nil)
        cursorCheckbox.frame = NSRect(x: 24, y: 296, width: 280, height: 24)
        cursorCheckbox.state = settings.cursorWatchEnabled ? .on : .off
        view.addSubview(cursorCheckbox)
        cursorWatchCheckbox = cursorCheckbox

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
            cursorWatchEnabled: cursorWatchCheckbox?.state == .on,
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
        cursorWatchCheckbox?.state = settings.cursorWatchEnabled ? .on : .off
        autoUpdateCheckbox?.state = (settings.autoUpdateEnabled ?? true) ? .on : .off
        activeWindowField?.stringValue = formatSeconds(settings.activeWindowSeconds)
        pollIntervalField?.stringValue = formatSeconds(settings.pollIntervalSeconds)
        weeklyLimitField?.stringValue = settings.weeklyLimitText ?? ""
        fiveHourLimitField?.stringValue = settings.fiveHourLimitText ?? ""
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    @objc private func openStatusFile() {
        ensureStatusDirectory()
        if !FileManager.default.fileExists(atPath: statusFile.path) {
            let empty = """
            {
              "status": "idle",
              "detail": "Ready",
              "updatedAt": "\(isoFormatter.string(from: Date()))"
            }
            """
            try? empty.write(to: statusFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(statusFile)
    }

    @objc private func revealStatusFolder() {
        ensureStatusDirectory()
        NSWorkspace.shared.open(statusFile.deletingLastPathComponent())
    }

    @objc private func restart() {
        guard relaunchApplication() else {
            showRestartFailureAlert()
            return
        }
        releaseSingleInstanceLock()
        NSApp.terminate(nil)
    }

    private func relaunchApplication() -> Bool {
        guard let executableURL = codexMenuBarExecutableURL(
            bundleExecutableURL: Bundle.main.executableURL,
            processArguments: ProcessInfo.processInfo.arguments
        ) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", codexMenuBarRelaunchShellCommand(executableURL: executableURL)]
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func showRestartFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart Failed"
        alert.informativeText = "Codex Menu Bar could not start a new process."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func checkForUpdatesManually() {
        checkForUpdates(isUserInitiated: true)
    }

    private func checkForUpdates(isUserInitiated: Bool) {
        if !isUserInitiated && !(settings.autoUpdateEnabled ?? true) {
            return
        }

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
                    if let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                       let downloadURL = URL(string: dmgAsset.browser_download_url) {
                        self.availableUpdateVersion = release.tag_name
                        self.availableUpdateURL = downloadURL
                        self.updateMenuItemTitle("Update to \(release.tag_name) (Available)")
                        self.updateMenuBarIcon()
                        
                        if isUserInitiated {
                            self.promptToUpdate(version: release.tag_name, url: downloadURL)
                        }
                        return
                    }
                }

                self.availableUpdateVersion = nil
                self.availableUpdateURL = nil
                self.updateMenuItemTitle("Check for Updates...")
                self.updateMenuBarIcon()
                if isUserInitiated {
                    self.showAlert(title: "Up to Date", message: "You are running the latest version (\(currentVersion)).")
                }
            }
        }.resume()
    }

    private func updateMenuItemTitle(_ title: String) {
        guard let menu = statusItem.menu, menu.numberOfItems > 0 else { return }
        let decoratedTitle: String
        if title.contains("Available") {
            decoratedTitle = "✨ 🚀 \(title) 🚀 ✨"
        } else if title.contains("Check for Updates") {
            decoratedTitle = "🔄 Check for Updates..."
        } else {
            decoratedTitle = title
        }
        menu.item(at: 0)?.title = decoratedTitle
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

    private func ensureStatusDirectory() {
        try? FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    @objc private func quit() {
        releaseSingleInstanceLock()
        NSApp.terminate(nil)
    }
}

extension CodexMenuBarApp: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }
}

let app = NSApplication.shared
let delegate = CodexMenuBarApp()
app.delegate = delegate
app.run()
