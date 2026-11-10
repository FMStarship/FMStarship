@testable import StarshipPlugin
import XCTest

/// The developer tools (the command file, Control-Option-D and the table watch) only go into a build that asks for them.
final class PluginBuildTests: XCTestCase {
    func testAPlainBuildHasNoDeveloperTools() {
        XCTAssertFalse(PluginBuild.developerTools, "STARSHIP_DEVELOPER is for `Scripts/install-plugin.sh --developer` only")
    }
}
