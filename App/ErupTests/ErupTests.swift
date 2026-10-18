import XCTest
@testable import Erup

final class ErupTests: XCTestCase {
    func testAppGroupID() {
        XCTAssertEqual(AppGroup.id, "group.me.ouihq.erup")
    }
}
