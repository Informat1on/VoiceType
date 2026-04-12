import AppKit
import ApplicationServices

final class CursorTracker {
    static func getPosition() -> NSPoint {
        let event = CGEvent(source: nil)
        let location = event?.location
        return location ?? NSPoint(x: 0, y: 0)
    }

    static func getScreenPoint() -> NSPoint {
        let cgPoint = getPosition()
        let nsPoint = NSPoint(x: cgPoint.x, y: cgPoint.y)

        guard let screen = NSScreen.screens.first(where: {
            NSPointInRect(nsPoint, $0.frame)
        }) else {
            return nsPoint
        }

        let screenFrame = screen.frame
        return NSPoint(
            x: nsPoint.x - screenFrame.origin.x,
            y: nsPoint.y - screenFrame.origin.y
        )
    }
}
