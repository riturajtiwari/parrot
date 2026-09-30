import XCTest
@testable import ParrotCore

final class UpdaterTests: XCTestCase {
    // A syntactically valid Ed25519 public key (32 zero bytes); never used to verify anything.
    private let key = Data(count: 32).base64EncodedString()
    private let feed = "https://github.com/humanitas-labs/parrot/releases/latest/download/appcast.xml"

    private func info(version: String, key: String? = nil, feed: String? = nil) -> [String: Any] {
        var info: [String: Any] = ["CFBundleVersion": version]
        info["SUPublicEDKey"] = key ?? self.key
        info["SUFeedURL"] = feed ?? self.feed
        return info
    }

    func testAReleaseBuildWithARealKeyUpdates() {
        XCTAssertNil(Updater.configurationProblem(info: info(version: "0.1.0")))
        XCTAssertNil(Updater.configurationProblem(info: info(version: "12")))
    }

    func testDevelopmentBuildsDoNotUpdate() {
        for version in ["0.0.6-3-gabc1234", "0.0.6-3-gabc1234-dirty", "abc1234", "0.0.0.", "", "1..2"] {
            XCTAssertNotNil(Updater.configurationProblem(info: info(version: version)), version)
        }
        XCTAssertNotNil(Updater.configurationProblem(info: [:]))
    }

    func testThePlaceholderKeyTurnsUpdatesOff() {
        let placeholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", key: placeholder)))
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", key: Data(count: 16).base64EncodedString())))
    }

    func testTheFeedMustBeSet() {
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", feed: "not a url")))
    }

    /// packaging/Info.plist, found from this file: Tests/ParrotTests/ → repo root.
    private func packagedInfoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The fork never updates itself: an upstream release has another bundle
    /// identifier and signing team, and would replace the fork's features.
    func testTheForkNeverUpdatesItself() throws {
        var plist = try packagedInfoPlist()
        XCTAssertNil(plist["SUFeedURL"])
        XCTAssertNil(plist["SUPublicEDKey"])
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)
        plist["CFBundleVersion"] = "0.2.1"
        XCTAssertNotNil(Updater.configurationProblem(info: plist))
    }

    /// `AppBundle.current` compares the running bundle with this identifier,
    /// so a mismatch would stop the app role from ever being detected.
    func testTheBundleIdentifierMatchesTheCode() throws {
        XCTAssertEqual(try packagedInfoPlist()["CFBundleIdentifier"] as? String, AppBundle.identifier)
    }
}
