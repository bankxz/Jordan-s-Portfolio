import XCTest

/// End-to-end journeys against demo data. Every test also saves screenshots (kept as test attachments)
/// which CI exports for visual QA: light, dark, and accessibility text sizes.
final class PeakUITests: XCTestCase {
    // IDs from PeakKit.SampleData.
    private let attackAnimals = "920587237"
    private let obbyRush = "735030788"
    private let petCafe = "606849621"
    private let mainGoal = "11111111-2222-3333-4444-555555555501"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(mode: String = "normal", dark: Bool = false, textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demoMode", mode, "-colorScheme", dark ? "dark" : "light"]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHomeShowsLiveNowAndGames() {
        let app = launch()
        XCTAssertTrue(element(app, "liveNowCard").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "gameCard.\(attackAnimals)").exists)
        screenshot(app, "home-light")
        app.swipeUp()
        screenshot(app, "home-light-scrolled")
    }

    @MainActor
    func testOpenGameDetailAndSwitchRange() {
        let app = launch()
        app.tabBars.buttons["Games"].tap()
        let row = element(app, "gameRow.\(attackAnimals)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        screenshot(app, "games-light")
        row.tap()
        XCTAssertTrue(app.staticTexts["Players now"].waitForExistence(timeout: 10))
        app.buttons["7D"].tap()
        XCTAssertTrue(app.staticTexts["Players now"].waitForExistence(timeout: 10))
        screenshot(app, "game-detail-7d-light")
    }

    @MainActor
    func testFavouriteToggleFromDetail() {
        let app = launch()
        app.tabBars.buttons["Games"].tap()
        let row = element(app, "gameRow.\(petCafe)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let favourite = app.buttons["favouriteButton"]
        XCTAssertTrue(favourite.waitForExistence(timeout: 10))
        XCTAssertEqual(favourite.label, "Favourite")
        favourite.tap()
        let predicate = NSPredicate(format: "label == %@", "Remove favourite")
        expectation(for: predicate, evaluatedWith: favourite)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testTabsAndGoalDetail() {
        let app = launch()
        app.tabBars.buttons["Goals"].tap()
        let goal = element(app, "goalCard.\(mainGoal)")
        XCTAssertTrue(goal.waitForExistence(timeout: 15))
        screenshot(app, "goals-light")
        goal.tap()
        XCTAssertTrue(app.staticTexts["Tasks"].waitForExistence(timeout: 5))
        screenshot(app, "goal-detail-light")

        app.tabBars.buttons["Ads"].tap()
        XCTAssertTrue(element(app, "campaignCard.spring-launch").waitForExistence(timeout: 5))
        screenshot(app, "ads-light")

        app.tabBars.buttons["Alerts"].tap()
        XCTAssertTrue(element(app, "alertsRecentHeader").waitForExistence(timeout: 5))
        screenshot(app, "alerts-light")
    }

    @MainActor
    func testEmptyState() {
        let app = launch(mode: "empty")
        XCTAssertTrue(app.staticTexts["No games yet"].waitForExistence(timeout: 15))
        screenshot(app, "home-empty")
    }

    @MainActor
    func testErrorStateOffersRetry() {
        let app = launch(mode: "failing")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 15))
        screenshot(app, "home-error")
    }

    @MainActor
    func testDarkModeScreens() {
        let app = launch(dark: true)
        XCTAssertTrue(element(app, "liveNowCard").waitForExistence(timeout: 15))
        screenshot(app, "home-dark")
        app.tabBars.buttons["Games"].tap()
        element(app, "gameRow.\(attackAnimals)").tap()
        XCTAssertTrue(app.staticTexts["Players now"].waitForExistence(timeout: 10))
        screenshot(app, "game-detail-dark")
    }

    @MainActor
    func testAccessibilityTextSize() {
        let app = launch(textSize: "UICTContentSizeCategoryAccessibilityXXL")
        XCTAssertTrue(element(app, "liveNowCard").waitForExistence(timeout: 15))
        screenshot(app, "home-a11y-xxl")
        app.swipeUp()
        screenshot(app, "home-a11y-xxl-scrolled")
        app.tabBars.buttons["Games"].tap()
        element(app, "gameRow.\(attackAnimals)").tap()
        XCTAssertTrue(app.staticTexts["Players now"].waitForExistence(timeout: 10))
        screenshot(app, "game-detail-a11y-xxl")
    }

    /// Routing + navigation for a widget/notification URL, independent of OS URL delivery.
    @MainActor
    func testLaunchURLRoutesToGoal() {
        let app = XCUIApplication()
        app.launchArguments += ["-demoMode", "normal", "-colorScheme", "light",
                                "-openURL", "peakstats://goal/\(mainGoal)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tasks"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Goals"].isSelected)
        screenshot(app, "launch-url-goal")
    }

    /// Catches anything (our layout or a simulator compatibility mode) pushing content off-screen.
    @MainActor
    func testContentFitsScreenWidth() {
        let app = launch()
        let card = element(app, "liveNowCard")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        let screenWidth = XCUIScreen.main.screenshot().image.size.width
        XCTAssertEqual(window.width, screenWidth, accuracy: 1, "App window is wider than the screen")
        XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX - 8, "Card touches the right edge")
        XCTAssertGreaterThanOrEqual(card.frame.minX, 8)
        XCTAssertEqual(card.frame.minX, window.maxX - card.frame.maxX, accuracy: 2, "Card isn't centred")
    }

    @MainActor
    func testDeepLinkOpensGame() throws {
        let app = launch()
        XCTAssertTrue(element(app, "liveNowCard").waitForExistence(timeout: 15))
        // Same URL a widget tap sends, delivered by the system rather than injected.
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "peakstats://game/\(obbyRush)")))
        // iOS may ask "Open in Peak?" for custom-scheme URLs.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openButton = springboard.buttons["Open"]
        if openButton.waitForExistence(timeout: 3) { openButton.tap() }
        let title = element(app, "gameDetailTitle")
        let appeared = title.waitForExistence(timeout: 10)
        screenshot(app, "deeplink-after-open")
        XCTAssertTrue(appeared, "Game detail didn't open. State: \(app.debugDescription.prefix(2_000))")
        XCTAssertEqual(title.label, "Obby Rush")
        screenshot(app, "deeplink-game")
    }

    // MARK: Insights and AI

    @MainActor
    func testBriefingAndAskPeak() {
        let app = launch()
        let briefing = element(app, "briefingCard")
        XCTAssertTrue(briefing.waitForExistence(timeout: 15))
        screenshot(app, "home-briefing")

        briefing.tap()
        XCTAssertTrue(app.navigationBars["Briefing"].waitForExistence(timeout: 10))
        screenshot(app, "briefing-detail")
        app.navigationBars.buttons.firstMatch.tap()

        element(app, "askButton").tap()
        let consent = element(app, "consentButton")
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        screenshot(app, "ask-consent")
        consent.tap()

        let suggestion = app.buttons["Why did my top game lose players yesterday?"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        screenshot(app, "ask-suggestions")
        suggestion.tap()
        XCTAssertTrue(element(app, "askAnswer").waitForExistence(timeout: 10))
        screenshot(app, "ask-answer")
    }

    @MainActor
    func testUnusualChangesOnAlerts() {
        let app = launch()
        app.tabBars.buttons["Alerts"].tap()
        XCTAssertTrue(element(app, "digest.\(attackAnimals)").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Possible cause")).firstMatch.exists)
        screenshot(app, "alerts-unusual")
    }

    @MainActor
    func testUpdateImpactOnGameDetail() {
        let app = launch()
        app.tabBars.buttons["Games"].tap()
        let row = element(app, "gameRow.\(attackAnimals)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let card = element(app, "updateImpactCard")
        for _ in 0..<4 where card.exists == false || card.isHittable == false {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        screenshot(app, "game-update-impact")
    }

    @MainActor
    func testPortfolioHealthBelowGames() {
        let app = launch()
        app.tabBars.buttons["Games"].tap()
        XCTAssertTrue(element(app, "gameRow.\(attackAnimals)").waitForExistence(timeout: 15))
        let card = element(app, "portfolioCard")
        for _ in 0..<5 where card.exists == false {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        screenshot(app, "games-portfolio")
    }

    @MainActor
    func testGoalPlanner() {
        let app = launch()
        app.tabBars.buttons["Goals"].tap()
        let plan = element(app, "planGoalButton")
        XCTAssertTrue(plan.waitForExistence(timeout: 15))
        plan.tap()
        XCTAssertTrue(element(app, "goalPlanSummary").waitForExistence(timeout: 10))
        screenshot(app, "goal-planner")
    }

    @MainActor
    func testBriefingDarkAndLargeText() {
        let dark = launch(dark: true)
        XCTAssertTrue(element(dark, "briefingCard").waitForExistence(timeout: 15))
        screenshot(dark, "home-briefing-dark")
        dark.terminate()
        let large = launch(textSize: "UICTContentSizeCategoryAccessibilityXXL")
        XCTAssertTrue(element(large, "briefingCard").waitForExistence(timeout: 15))
        screenshot(large, "home-briefing-a11y-xxl")
    }
}
