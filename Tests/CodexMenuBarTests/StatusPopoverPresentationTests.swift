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
