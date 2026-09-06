import XCTest
@testable import Linklet

final class OrionProfileLocatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDiscoversAndNamesOrionProfileApps() throws {
        let profileFolder = temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let application = profileFolder
            .appending(path: "Orion - Work.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: application,
            withIntermediateDirectories: true
        )

        let targets = OrionProfileLocator().discoverProfiles(searchRoots: [temporaryDirectory])

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.displayName, "Work")
        XCTAssertEqual(targets.first?.kind, .orionProfile)
    }
}
