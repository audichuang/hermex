import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatComposerTextInputConfigurationTests: XCTestCase {
    /// #209: Chinese Pinyin composes candidates from lowercase Latin letters, so
    /// the composer must never auto-capitalize (`nihao` must not become `Nihao`).
    func testComposerTextViewDisablesAutocapitalization() {
        let textView = ComposerChipTextView()

        XCTAssertEqual(textView.autocapitalizationType, .none)
    }
}
