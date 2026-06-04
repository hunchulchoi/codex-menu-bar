import AppKit
import Foundation

enum CodexMenuBarIconKind {
    case idle
    case running
    case waiting
    case complete
}

func codexMenuBarIconKind(status: String, isRecentlyCompleted: Bool) -> CodexMenuBarIconKind {
    if isRecentlyCompleted {
        return .complete
    }

    switch CodexStatusKind(status: status) {
    case .running:
        return .running
    case .waiting, .message, .error, .awaitingApproval:
        return .waiting
    case .completed:
        return .complete
    case .idle:
        return .idle
    }
}

func codexMenuBarTopRightSparkleShouldBlink(status: String, isRecentlyCompleted: Bool) -> Bool {
    if isRecentlyCompleted {
        return true
    }

    switch CodexStatusKind(status: status) {
    case .completed, .awaitingApproval, .error:
        return true
    case .running, .idle, .waiting, .message:
        return false
    }
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
        agStatus: String? = nil
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
        
        let hasAgDot = (effectiveAgStatus != nil)
        let image = NSImage(size: Self.size)
        image.isTemplate = !hasAgDot
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.shouldAntialias = true
        draw(
            kind: kind,
            color: hasAgDot ? NSColor.labelColor : color,
            frameIndex: frameIndex,
            fiveHourUsagePercent: fiveHourUsagePercent,
            weeklyUsagePercent: weeklyUsagePercent,
            showTopRightSparkle: codexMenuBarTopRightSparkleShouldBlink(
                status: status,
                isRecentlyCompleted: isRecentlyCompleted
            )
        )

        if let effectiveAgStatus {
            drawAgStatusDot(agStatus: effectiveAgStatus, frameIndex: frameIndex)
        }

        return image
    }

    /// AGY 상태에 따른 LED 인디케이터 점을 이미지 우하단에 그립니다.
    private func drawAgStatusDot(agStatus: String, frameIndex: Int) {
        // Determine color and blinking behavior
        let dotColor: NSColor
        var shouldBlink = false

        switch agStatus.lowercased() {
        case "awaiting approval", "approval_required":
            dotColor = NSColor.systemOrange // Amber/Yellow
            shouldBlink = true
        case "completed", "complete", "done":
            dotColor = NSColor.systemGreen
        case "running", "thinking", "working":
            dotColor = NSColor.systemPurple
        case "error", "failed":
            dotColor = NSColor.systemRed
        default:
            dotColor = NSColor.systemPurple
        }

        if shouldBlink && (frameIndex % 2 == 0) {
            return // Skip drawing the dot on even frames to create a blinking effect
        }

        let dotRadius: CGFloat = 2.5
        let dotCenter = CGPoint(x: Self.size.width - dotRadius - 0.5, y: dotRadius + 0.5)
        let rect = CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        // 배경 테두리 (흰색 링) — 다크/라이트 모두 명확하게 보이도록
        let ringPath = NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1))
        NSColor.controlBackgroundColor.setFill()
        ringPath.fill()

        // 컬러 점
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
        showTopRightSparkle: Bool
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
        case .waiting:
            drawBaseSpaceship(color: color, dotFrameIndex: frameIndex)
        case .complete:
            drawBaseSpaceship(color: color, dotFrameIndex: nil, blinkingDotIndex: nil, verticalOffset: 0)
        }

        if showTopRightSparkle {
            drawCompleteSparkle(color: color, frameIndex: frameIndex)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBaseSpaceship(
        color: NSColor,
        dotFrameIndex: Int? = nil,
        blinkingDotIndex: Int? = nil,
        verticalOffset: CGFloat = 0
    ) {
        color.setStroke()
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: 2, y: 13 + verticalOffset))
        outline.curve(
            to: CGPoint(x: 7, y: 10 + verticalOffset),
            controlPoint1: CGPoint(x: 2, y: 11 + verticalOffset),
            controlPoint2: CGPoint(x: 7, y: 10 + verticalOffset)
        )
        outline.curve(
            to: CGPoint(x: 17, y: 10 + verticalOffset),
            controlPoint1: CGPoint(x: 7, y: 5 + verticalOffset),
            controlPoint2: CGPoint(x: 17, y: 5 + verticalOffset)
        )
        outline.curve(
            to: CGPoint(x: 22, y: 13 + verticalOffset),
            controlPoint1: CGPoint(x: 17, y: 10 + verticalOffset),
            controlPoint2: CGPoint(x: 22, y: 11 + verticalOffset)
        )
        outline.curve(
            to: CGPoint(x: 2, y: 13 + verticalOffset),
            controlPoint1: CGPoint(x: 22, y: 16.5 + verticalOffset),
            controlPoint2: CGPoint(x: 2, y: 16.5 + verticalOffset)
        )
        outline.close()
        outline.lineWidth = strokeWidth
        outline.stroke()

        let earLine = NSBezierPath()
        earLine.move(to: CGPoint(x: 7, y: 10 + verticalOffset))
        earLine.curve(
            to: CGPoint(x: 17, y: 10 + verticalOffset),
            controlPoint1: CGPoint(x: 9, y: 11.5 + verticalOffset),
            controlPoint2: CGPoint(x: 15, y: 11.5 + verticalOffset)
        )
        earLine.lineWidth = strokeWidth
        earLine.stroke()

        var dotOpacities: [CGFloat]
        if let dotFrameIndex {
            dotOpacities = [1, 1, 1]
            if let blinkingDotIndex {
                dotOpacities[blinkingDotIndex] = codexMenuBarBlinkOpacity(frameIndex: dotFrameIndex, phase: blinkingDotIndex)
            } else {
                dotOpacities = [
                    codexMenuBarBlinkOpacity(frameIndex: dotFrameIndex, phase: 0),
                    codexMenuBarBlinkOpacity(frameIndex: dotFrameIndex, phase: 1),
                    codexMenuBarBlinkOpacity(frameIndex: dotFrameIndex, phase: 2)
                ]
            }
        } else {
            dotOpacities = [1, 1, 1]
        }

        drawCircle(center: CGPoint(x: 7, y: 14 + verticalOffset), radius: 1, color: color, opacity: dotOpacities[0])
        drawCircle(center: CGPoint(x: 12, y: 14.5 + verticalOffset), radius: 1, color: color, opacity: dotOpacities[1])
        drawCircle(center: CGPoint(x: 17, y: 14 + verticalOffset), radius: 1, color: color, opacity: dotOpacities[2])
    }

    private func drawCircle(center: CGPoint, radius: CGFloat, color: NSColor, opacity: CGFloat = 1) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        color.withAlphaComponent(opacity).setFill()
        path.fill()
    }

    private func drawCompleteSparkle(color: NSColor, frameIndex: Int) {
        let sparkleOpacity = codexMenuBarBlinkOpacity(frameIndex: frameIndex, phase: 0)
        drawCircle(center: codexMenuBarTopRightSparkleCenter(), radius: 1.6, color: color, opacity: sparkleOpacity)
    }

    private func drawRunningMotionStreaks(color: NSColor, frameIndex: Int) {
        for streak in codexMenuBarRunningMotionStreaks(frameIndex: frameIndex) {
            let rect = CGRect(x: streak.x, y: streak.y, width: streak.width, height: 0.75)
            color.withAlphaComponent(streak.opacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.38, yRadius: 0.38).fill()
        }
    }

    private func drawUsageBars(
        color: NSColor,
        fiveHourUsagePercent: Double?,
        weeklyUsagePercent: Double?
    ) {
        guard fiveHourUsagePercent != nil || weeklyUsagePercent != nil else {
            return
        }

        let barX: CGFloat = 3.8
        let barWidth: CGFloat = 14.4
        let barHeight: CGFloat = 0.85
        let firstBarY: CGFloat = 18.6
        let secondBarY: CGFloat = 20.8
        let trackOpacity: CGFloat = 0.16
        let fillOpacity: CGFloat = 1.0

        if let fiveHourUsagePercent {
            drawMiniBar(
                x: barX,
                y: secondBarY,
                width: barWidth,
                height: barHeight,
                usedPercent: fiveHourUsagePercent,
                color: color,
                trackOpacity: trackOpacity,
                fillOpacity: fillOpacity
            )
        }

        if let weeklyUsagePercent {
            drawMiniBar(
                x: barX,
                y: firstBarY,
                width: barWidth,
                height: barHeight,
                usedPercent: weeklyUsagePercent,
                color: color,
                trackOpacity: trackOpacity,
                fillOpacity: fillOpacity
            )
        }
    }

    private func drawMiniBar(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        usedPercent: Double,
        color: NSColor,
        trackOpacity: CGFloat,
        fillOpacity: CGFloat
    ) {
        let clampedPercent = CGFloat(min(max(usedPercent, 0), 100)) / 100.0
        let trackRect = CGRect(x: x, y: y, width: width, height: height)
        let fillWidth = max(0.5, min(trackRect.width, trackRect.width * clampedPercent))
        let fillRect = CGRect(x: x, y: y, width: fillWidth, height: height)

        color.withAlphaComponent(trackOpacity).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: height / 2, yRadius: height / 2).fill()

        color.withAlphaComponent(fillOpacity).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: height / 2, yRadius: height / 2).fill()
    }
}
