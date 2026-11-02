import XCTest
@testable import Kit

final class GreetingTests: XCTestCase {
    func testText() {
        XCTAssertEqual(Greeting.text(for: "selftest"), "Hello, selftest")
    }
}
