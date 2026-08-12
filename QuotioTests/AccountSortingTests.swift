import XCTest
@testable import Quotio

final class AccountSortingTests: XCTestCase {
    private struct Account: Equatable {
        let email: String
    }

    func testActiveAccountFloatsToTop() {
        let accounts = [
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com"),
            Account(email: "charlie@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) {
            $0.email == "charlie@example.com"
        }

        XCTAssertEqual(result.map(\.email), [
            "charlie@example.com",
            "alpha@example.com",
            "bravo@example.com"
        ])
    }

    func testMultipleActiveAccountsKeepStableRelativeOrder() {
        let accounts = [
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com"),
            Account(email: "charlie@example.com"),
            Account(email: "delta@example.com")
        ]

        let active: Set<String> = ["bravo@example.com", "delta@example.com"]
        let result = AccountSorting.prioritizingActive(accounts) {
            active.contains($0.email)
        }

        XCTAssertEqual(result.map(\.email), [
            "bravo@example.com",
            "delta@example.com",
            "alpha@example.com",
            "charlie@example.com"
        ])
    }

    func testNoActiveAccountLeavesOrderUnchanged() {
        let accounts = [
            Account(email: "charlie@example.com"),
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) { _ in false }

        XCTAssertEqual(result, accounts)
    }

    func testAllActiveAccountsLeaveOrderUnchanged() {
        let accounts = [
            Account(email: "charlie@example.com"),
            Account(email: "alpha@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) { _ in true }

        XCTAssertEqual(result, accounts)
    }

    func testEmptyListStaysEmpty() {
        let result = AccountSorting.prioritizingActive([Account]()) { _ in true }
        XCTAssertTrue(result.isEmpty)
    }
}
