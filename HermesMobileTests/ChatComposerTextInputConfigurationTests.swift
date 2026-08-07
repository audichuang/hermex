import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatComposerTextInputConfigurationTests: XCTestCase {
    /// #209: Chinese Pinyin composes candidates from lowercase Latin letters, so
    /// the composer must never auto-capitalize (`nihao` must not become `Nihao`).
    func testComposerTextViewDisablesAutocapitalization() {
        let textView = ComposerTextView.PastingTextView.configuredForComposer()

        XCTAssertEqual(textView.autocapitalizationType, .none)
    }

    /// The rest of the composer configuration is unchanged by that fix.
    func testComposerTextViewKeepsExistingInputConfiguration() {
        let textView = ComposerTextView.PastingTextView.configuredForComposer()

        XCTAssertEqual(textView.textContentType, UITextContentType?.none)
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertTrue(textView.adjustsFontForContentSizeCategory)
        XCTAssertEqual(textView.textContainerInset, .zero)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)
        XCTAssertNotNil(textView.pasteConfiguration)
    }
}
