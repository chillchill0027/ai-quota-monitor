import Foundation

/// Pure screen-coordinate checks: no windows, account readers or network sessions.
enum StatusBarPanelTests {
    private static let dashboardSize = NSSize(width: 390, height: 650)

    static func run() {
        testPanelCentersBelowAnchorWhenThereIsRoom()
        testRightEdgeStaysOnTheClickedScreen()
        testNegativeCoordinateScreenDoesNotJumpToPrimaryDisplay()
        testVerticallyOffsetDisplayRetainsItsCoordinateSystem()
        testNarrowScreenReducesWidthWithoutOverflow()
        testShortScreenReducesHeightWithoutOverflow()
        testOffscreenAnchorIsConstrainedToTargetDisplay()
        testPlacementIsTranslationInvariantAcrossDisplays()
        print("PASS: 8 status-bar panel screen-position and small-display regressions")
    }

    private static func testPanelCentersBelowAnchorWhenThereIsRoom() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 700, y: 876, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.size, dashboardSize)
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, anchor.minY - 6)
        assertContained(frame, within: screen)
    }

    private static func testRightEdgeStaysOnTheClickedScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 1420, y: 876, width: 20, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.size, dashboardSize)
        XCTAssertEqual(frame.maxX, screen.maxX - 8)
        XCTAssertEqual(frame.maxY, anchor.minY - 6)
        assertContained(frame, within: screen)
    }

    private static func testNegativeCoordinateScreenDoesNotJumpToPrimaryDisplay() {
        // A second display to the left of the primary display has negative X.
        let screen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let anchor = NSRect(x: -1880, y: 1056, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.minX, screen.minX + 8)
        XCTAssertEqual(frame.maxX < 0, true)
        XCTAssertEqual(frame.maxY, anchor.minY - 6)
        assertContained(frame, within: screen)
    }

    private static func testVerticallyOffsetDisplayRetainsItsCoordinateSystem() {
        let screen = NSRect(x: 1440, y: -900, width: 1600, height: 900)
        let anchor = NSRect(x: 2800, y: -24, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, -30)
        XCTAssertEqual(frame.minY < 0, true)
        assertContained(frame, within: screen)
    }

    private static func testNarrowScreenReducesWidthWithoutOverflow() {
        let screen = NSRect(x: 100, y: -200, width: 320, height: 900)
        let anchor = NSRect(x: 250, y: 676, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.width, 304)
        XCTAssertEqual(frame.height, dashboardSize.height)
        XCTAssertEqual(frame.minX, 108)
        assertContained(frame, within: screen)
    }

    private static func testShortScreenReducesHeightWithoutOverflow() {
        let screen = NSRect(x: 0, y: 0, width: 1024, height: 600)
        let anchor = NSRect(x: 800, y: 576, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.width, dashboardSize.width)
        XCTAssertEqual(frame.height, 584)
        XCTAssertEqual(frame.minY, 8)
        assertContained(frame, within: screen)
    }

    private static func testOffscreenAnchorIsConstrainedToTargetDisplay() {
        // A full-screen menu-bar proxy may briefly report an old anchor location.
        let screen = NSRect(x: -1600, y: -300, width: 1600, height: 1000)
        let anchor = NSRect(x: 1800, y: 1400, width: 24, height: 24)
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        XCTAssertEqual(frame.maxX, screen.maxX - 8)
        XCTAssertEqual(frame.maxY, screen.maxY - 8)
        assertContained(frame, within: screen)
    }

    private static func testPlacementIsTranslationInvariantAcrossDisplays() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 1300, y: 876, width: 24, height: 24)
        let original = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen, size: dashboardSize)
        let dx: CGFloat = -2100
        let dy: CGFloat = -1200
        let translated = StatusBarPanelGeometry.frame(
            anchoredTo: anchor.offsetBy(dx: dx, dy: dy),
            within: screen.offsetBy(dx: dx, dy: dy),
            size: dashboardSize)
        XCTAssertEqual(translated, original.offsetBy(dx: dx, dy: dy))
    }

    private static func assertContained(_ frame: NSRect, within screen: NSRect) {
        precondition(frame.minX >= screen.minX + 8 && frame.maxX <= screen.maxX - 8,
                     "Panel overflowed target screen horizontally: \(frame) in \(screen)")
        precondition(frame.minY >= screen.minY + 8 && frame.maxY <= screen.maxY - 8,
                     "Panel overflowed target screen vertically: \(frame) in \(screen)")
    }
}
