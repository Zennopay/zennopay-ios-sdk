import XCTest
@testable import Zennopay
#if canImport(SwiftUI)
import SwiftUI
#endif

// Tests added by the accessibility / overflow / screen-size QA pass
// (2026-07-17): formatter overflow safety, the keypad input cap policy, and
// the Dynamic Type scale mapping.

// MARK: - Currency formatting: extreme / hostile inputs must never crash

final class CurrencyDisplayOverflowTests: XCTestCase {

    func test_formatMinor_intMax_doesNotCrash_andRendersDigits() {
        let s = CurrencyDisplay.formatMinor(Int.max, numeric: "704")
        XCTAssertTrue(s.hasPrefix("₫"))
        XCTAssertTrue(s.contains(","), "grouping must survive extreme input: \(s)")
    }

    func test_formatMinor_intMin_doesNotCrash() {
        let s = CurrencyDisplay.formatMinor(Int.min, numeric: "764")
        XCTAssertFalse(s.isEmpty)
    }

    func test_formatMinorWithLabel_intMax_doesNotCrash() {
        let s = CurrencyDisplay.formatMinorWithLabel(Int.max, numeric: "704")
        XCTAssertTrue(s.hasSuffix(" VND"))
    }

    func test_formatUSDCents_intMax_doesNotCrash() {
        let s = CurrencyDisplay.formatUSDCents(Int.max)
        XCTAssertTrue(s.hasPrefix("$"))
    }

    func test_exchangeRateLine_extremeValues_doesNotCrash() {
        let line = CurrencyDisplay.exchangeRateLine(
            usdCents: 1, localMinorUnits: Int.max, localCurrency: "704"
        )
        XCTAssertNotNil(line)
    }

    func test_formatMinor_defensiveHugeQuote_rendersReadably() {
        // ₫999,999,999 — a QR/quote could carry it even though the backend
        // rejects it at confirm. The formatter must render it exactly.
        XCTAssertEqual(
            CurrencyDisplay.formatMinor(99_999_999_900, numeric: "704"),
            "₫999,999,999"
        )
        XCTAssertEqual(
            CurrencyDisplay.formatMinor(99_999_999, numeric: "764"),
            "฿999,999.99"
        )
    }
}

// MARK: - Keypad input policy (static-QR amount entry cap)

final class KeypadInputPolicyTests: XCTestCase {

    func test_leadingZero_isSilentlyIgnored() {
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("", "0", currencyNumeric: "704"),
            .accepted("")
        )
    }

    func test_normalTyping_accepts() {
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("3500", "0", currencyNumeric: "704"),
            .accepted("35000")
        )
    }

    func test_vnd_atExactlyFiveMillion_isAccepted() {
        // 500000 + "0" → 5,000,000 == the cap (not over it).
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("500000", "0", currencyNumeric: "704"),
            .accepted("5000000")
        )
    }

    func test_vnd_beyondFiveMillion_isRefusedWithLimitHint() {
        // 5,000,000 + any digit would be ≥ 50,000,000 — refused, digits kept.
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("5000000", "1", currencyNumeric: "704"),
            .refused(hint: .vndPerTransactionLimit)
        )
        // 500001 + "0" → 5,000,010 > cap.
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("500001", "0", currencyNumeric: "704"),
            .refused(hint: .vndPerTransactionLimit)
        )
    }

    func test_tripleZero_respectsVNDLimit() {
        XCTAssertEqual(
            KeypadInputPolicy.appendingTripleZero("5000", currencyNumeric: "704"),
            .accepted("5000000")
        )
        XCTAssertEqual(
            KeypadInputPolicy.appendingTripleZero("5001", currencyNumeric: "704"),
            .refused(hint: .vndPerTransactionLimit)
        )
    }

    func test_tripleZero_onEmpty_isSilentNoOp() {
        XCTAssertEqual(
            KeypadInputPolicy.appendingTripleZero("", currencyNumeric: "704"),
            .accepted("")
        )
    }

    func test_nonVND_capsAtNineDigits_notAtVNDLimit() {
        // THB has no client-side VND cap, but the 9-digit ceiling holds so the
        // hero can never overflow.
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("99999999", "9", currencyNumeric: "764"),
            .accepted("999999999")
        )
        XCTAssertEqual(
            KeypadInputPolicy.appendingDigit("999999999", "9", currencyNumeric: "764"),
            .refused(hint: .maxLength)
        )
        XCTAssertEqual(
            KeypadInputPolicy.appendingTripleZero("9999999", currencyNumeric: "764"),
            .refused(hint: .maxLength)
        )
    }

    func test_twelvePlusDigitInput_cannotBeReached() {
        // Simulate mashing "9" forever: the accepted string never exceeds the
        // ceiling, so a 12+-digit hero is impossible.
        var digits = ""
        for _ in 0..<40 {
            if case .accepted(let next) = KeypadInputPolicy.appendingDigit(
                digits, "9", currencyNumeric: "764"
            ) {
                digits = next
            }
        }
        XCTAssertLessThanOrEqual(digits.count, KeypadInputPolicy.maxDigits)
    }
}

#if canImport(SwiftUI)
// MARK: - Dynamic Type scale mapping

final class ZTypeScaleTests: XCTestCase {

    func test_multiplier_identityAtLarge() {
        XCTAssertEqual(ZTypeScale.multiplier(for: .large), 1.0, accuracy: 0.001)
    }

    func test_multiplier_followsPlatformBodyCurve() {
        XCTAssertEqual(ZTypeScale.multiplier(for: .extraSmall), 14.0 / 17.0, accuracy: 0.001)
        XCTAssertEqual(ZTypeScale.multiplier(for: .extraExtraLarge), 21.0 / 17.0, accuracy: 0.001)
        XCTAssertEqual(
            ZTypeScale.multiplier(for: .accessibilityExtraExtraExtraLarge),
            53.0 / 17.0, accuracy: 0.001
        )
    }

    func test_scaled_regularText_capsAtAccessibilityMedium() {
        // 14pt at AX-XXXL would be 44pt uncapped; the regular cap (28/17)
        // holds it at 23pt so fixed chrome stays usable.
        XCTAssertEqual(
            ZTypeScale.scaled(14, category: .accessibilityExtraExtraExtraLarge),
            (14 * 28.0 / 17.0).rounded()
        )
        // Below the cap the platform multiplier applies directly.
        XCTAssertEqual(
            ZTypeScale.scaled(14, category: .extraExtraLarge),
            (14 * 21.0 / 17.0).rounded()
        )
    }

    func test_scaled_hero_capsEarlier() {
        XCTAssertEqual(
            ZTypeScale.scaled(
                56, category: .accessibilityExtraLarge,
                maxMultiplier: ZTypeScale.heroMaxMultiplier
            ),
            (56 * 23.0 / 17.0).rounded()
        )
    }

    func test_scaled_shrinksForSmallCategories() {
        XCTAssertEqual(
            ZTypeScale.scaled(17, category: .extraSmall),
            (17 * 14.0 / 17.0).rounded()
        )
    }
}
#endif
