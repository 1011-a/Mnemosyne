import XCTest
import AppKit

/// Genuine end-to-end UI tests: launch the real app bundle and tap real controls
/// by the accessibility identifiers attached in the views, asserting on what the
/// live UI shows. Run with:
///   xcodebuild test -project Mnemosyne.xcodeproj -scheme Mnemosyne \
///     -destination 'platform=macOS,arch=arm64'
final class MnemosyneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The five top-bar nav controls exist and switching sections by *clicking*
    /// them shows the matching screen.
    @MainActor
    func testNavSwitchingByClickingRealButtons() throws {
        let app = XCUIApplication()
        app.launch()

        // The nav controls are present (addressed by .accessibilityIdentifier).
        XCTAssertTrue(app.buttons["nav.chat"].waitForExistence(timeout: 15),
                      "nav.chat should exist after launch")
        XCTAssertTrue(app.buttons["nav.library"].exists)
        XCTAssertTrue(app.buttons["nav.ingest"].exists)
        XCTAssertTrue(app.buttons["nav.insights"].exists)
        XCTAssertTrue(app.buttons["nav.settings"].exists)

        // Click LIBRARY → the Library header appears.
        app.buttons["nav.library"].click()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5),
                      "Library header should appear after clicking nav.library")

        // Click INGEST → its prompt appears.
        app.buttons["nav.ingest"].click()
        XCTAssertTrue(app.staticTexts["Ready to ingest"].waitForExistence(timeout: 5),
                      "Ingest screen should appear after clicking nav.ingest")

        // Click INSIGHTS → its header appears.
        app.buttons["nav.insights"].click()
        XCTAssertTrue(app.staticTexts["Insights"].waitForExistence(timeout: 5),
                      "Insights header should appear after clicking nav.insights")

        // Click SETTINGS, then back to ASK.
        app.buttons["nav.settings"].click()
        app.buttons["nav.chat"].click()
        XCTAssertTrue(app.buttons["nav.chat"].exists)
    }

    /// Regression for the Settings overflow bug: a section view that wasn't wrapped
    /// in a ScrollView overflowed and shoved the whole shell (nav bar + header) off
    /// the top of the window. After navigating to a content-heavy section, the nav
    /// bar and the section header must still be on-screen (hittable), not just exist.
    @MainActor
    func testSettingsKeepsNavBarAndHeaderOnScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 20))

        app.buttons["nav.settings"].click()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 8))
        // The bug: the un-scrolled Settings content overflowed and shoved these off
        // the top of the window. They still "existed" but were not hittable.
        XCTAssertTrue(app.staticTexts["Settings"].isHittable,
                      "Settings header must be visible, not clipped under the title bar")
        XCTAssertTrue(app.buttons["nav.chat"].isHittable,
                      "Nav bar must stay on-screen on the Settings page")
    }

    /// Regression for "不同页面的 Menu 高度不一样" — the top bar was taller on Chat
    /// (which shows 30pt action icons) than on other pages (no icons), so the nav
    /// shifted vertically between sections. The nav button's vertical center must be
    /// identical on every page.
    @MainActor
    func testTopBarHeightIsConsistentAcrossPages() throws {
        let app = XCUIApplication()
        app.launch()
        let nav = app.buttons["nav.library"]
        XCTAssertTrue(nav.waitForExistence(timeout: 20))

        let yOnLaunch = nav.frame.midY              // launch lands on Chat (icons shown)
        app.buttons["nav.insights"].click()         // a page with no action icons
        let yOnInsights = app.buttons["nav.library"].frame.midY
        app.buttons["nav.settings"].click()
        let yOnSettings = app.buttons["nav.library"].frame.midY

        XCTAssertEqual(yOnLaunch, yOnInsights, accuracy: 1.0,
                       "Top bar must be the same height on Chat and Insights")
        XCTAssertEqual(yOnLaunch, yOnSettings, accuracy: 1.0,
                       "Top bar must be the same height on Chat and Settings")
    }

    /// Opening an item detail and closing it with the ✕ button works — the detail
    /// previously had no close affordance at all (only the action buttons dismissed).
    @MainActor
    func testItemDetailOpensAndCloses() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["nav.library"].waitForExistence(timeout: 20))
        app.buttons["nav.library"].click()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Library should show cards")
        card.click()

        let close = app.buttons["detail.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Detail sheet must have a close button")
        close.click()
        // After closing, the close button must be gone (sheet dismissed).
        XCTAssertFalse(close.waitForExistence(timeout: 3),
                       "Clicking ✕ must dismiss the item detail sheet")
    }

    /// Clicking the answer card's Copy button actually copies the answer to the
    /// system pasteboard — a "the button does the right thing" check. Uses the
    /// deterministic --uitest conversation (marker text MARKER_COPY_OK).
    @MainActor
    func testCopyButtonCopiesAnswerToPasteboard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launch()

        // The Copy button only exists once the answer card has rendered.
        let copyButton = app.buttons["answer.copy"].firstMatch
        XCTAssertTrue(copyButton.waitForExistence(timeout: 20), "the answer card should render")

        let pb = NSPasteboard.general
        pb.clearContents()

        copyButton.click()

        // Poll the pasteboard briefly (the click writes it on the app side).
        var copied: String?
        for _ in 0..<20 {
            copied = pb.string(forType: .string)
            if copied?.contains("MARKER_COPY_OK") == true { break }
            usleep(100_000)
        }
        XCTAssertTrue(copied?.contains("MARKER_COPY_OK") == true,
                      "Copy must put the answer text on the pasteboard (got: \(copied ?? "nil"))")
    }

    /// Clicking the history (clock) button opens the thread popover.
    @MainActor
    func testHistoryButtonOpensThreadPopover() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.history"].waitForExistence(timeout: 20))
        app.buttons["chat.history"].click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5),
                      "the history button should open the thread popover")
    }

    /// Follow-up suggestion chips render under an answer (assert only — clicking
    /// would fire a network turn).
    @MainActor
    func testFollowUpChipsRender() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launch()
        // A generic follow-up is always offered after a grounded answer.
        XCTAssertTrue(app.buttons["What are the key takeaways?"].waitForExistence(timeout: 20),
                      "follow-up chips should render beneath the answer card")
    }

    /// ⌘F switches to Library AND focuses the search field, so typed text filters
    /// the grid (verifies M69's auto-focus, which was unverifiable while AX-wedged).
    @MainActor
    func testFindShortcutFocusesSearchSoTypingFilters() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["nav.chat"].waitForExistence(timeout: 20))

        // Trigger Find via the menu item (isolates the focus question from the
        // ⌘F key-delivery question), then type.
        app.menuBars.menuItems["Find in Library"].click()
        Thread.sleep(forTimeInterval: 0.9)                 // let the focus settle (200/450ms retries)
        app.typeText("paper")                              // matches only uitest-paper.pdf

        // If the search received the text, the grid filters to the one match.
        XCTAssertTrue(app.staticTexts["uitest-paper.pdf"].waitForExistence(timeout: 4),
                      "the matching card should remain")
        XCTAssertFalse(app.staticTexts["uitest-notes.txt"].exists,
                       "non-matching cards filtered out — proves Find focused the search field")
    }

    /// Clicking Copy shows the "Copied" confirmation (M69 feedback) — the Text is
    /// inside the button, so it becomes the button's label.
    @MainActor
    func testCopyButtonShowsCopiedConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launch()
        let copy = app.buttons["answer.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 20))
        XCTAssertEqual(copy.label, "Copy")
        copy.click()
        // Poll the label briefly (the "Copied" state lasts ~1.4s).
        var sawCopied = false
        for _ in 0..<10 {
            if copy.label.contains("Copied") { sawCopied = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawCopied, "the Copy pill should briefly read 'Copied' (got '\(copy.label)')")
    }

    /// Toggling a Settings checkbox by clicking it flips its on/off state.
    @MainActor
    func testSettingsToggleClicks() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 15))
        app.buttons["nav.settings"].click()

        let agentic = app.checkBoxes["settings.agentic"]
        XCTAssertTrue(agentic.waitForExistence(timeout: 5),
                      "Agentic-mode toggle should exist on Settings")
        let before = (agentic.value as? Int) ?? -1
        agentic.click()
        let after = (agentic.value as? Int) ?? -1
        XCTAssertNotEqual(before, after, "Clicking the toggle should change its value")
    }
}
