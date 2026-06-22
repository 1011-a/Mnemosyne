import XCTest
@testable import Mnemosyne

final class PalindromeTests: XCTestCase {

    func testSimpleAndNumeric() {
        XCTAssertTrue(Palindrome.isPalindrome("racecar"))
        XCTAssertTrue(Palindrome.isPalindrome("12321"))
        XCTAssertFalse(Palindrome.isPalindrome("hello"))
    }

    func testIgnoresCaseAndPunctuation() {
        XCTAssertTrue(Palindrome.isPalindrome("A man, a plan, a canal: Panama"))
        XCTAssertTrue(Palindrome.isPalindrome("Was it a car or a cat I saw?"))
        XCTAssertTrue(Palindrome.isPalindrome("No 'x' in Nixon"))
    }

    func testEmptyOrNoAlphanumericIsFalse() {
        XCTAssertFalse(Palindrome.isPalindrome(""))
        XCTAssertFalse(Palindrome.isPalindrome("!!! ???"))
    }
}
