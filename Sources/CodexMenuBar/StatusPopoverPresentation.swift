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
