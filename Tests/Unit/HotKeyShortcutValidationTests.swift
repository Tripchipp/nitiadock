import Carbon.HIToolbox
import XCTest

final class HotKeyShortcutValidationTests: XCTestCase {
    private func validate(_ keyCode: Int, _ modifiers: UInt32) -> HotKeyShortcutRejection? {
        HotKeyShortcutValidation.validate(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
    }

    func testAcceptsCommonCombinations() {
        XCTAssertNil(validate(kVK_ANSI_D, UInt32(optionKey | shiftKey | cmdKey)), "the default ⌥⇧⌘D must be usable")
        XCTAssertNil(validate(kVK_ANSI_K, UInt32(controlKey | cmdKey)))
        XCTAssertNil(validate(kVK_F5, UInt32(cmdKey)))
        XCTAssertNil(validate(kVK_ANSI_F, UInt32(controlKey | optionKey | cmdKey)), "⌃⌥ with ⌘ is a safe combo, only the one without ⌘ is rejected")
    }

    func testRejectsMissingPrimaryModifier() {
        XCTAssertEqual(validate(kVK_ANSI_A, 0), .missingPrimaryModifier)
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(shiftKey)), .missingPrimaryModifier, "⇧ alone is not a primary modifier")
    }

    func testRejectsUnreliableOptionOnlyModifiers() {
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(optionKey)), .unreliableModifiers)
        XCTAssertEqual(validate(kVK_ANSI_A, UInt32(optionKey | shiftKey)), .unreliableModifiers)
    }

    func testRejectsSystemReservedCombinations() {
        XCTAssertEqual(validate(kVK_ANSI_F, UInt32(controlKey | optionKey)), .reservedBySystem, "⌃⌥ without ⌘ is VoiceOver's modifier domain")
        XCTAssertEqual(validate(kVK_ANSI_D, UInt32(optionKey | cmdKey)), .reservedBySystem, "⌥⌘D belongs to macOS (system Dock show/hide)")
        XCTAssertNil(validate(kVK_ANSI_E, UInt32(optionKey | cmdKey)), "⌥⌘ is rejected only with the D key")
    }

    func testRejectsForbiddenKeysRegardlessOfModifiers() {
        XCTAssertEqual(validate(kVK_Escape, UInt32(cmdKey)), .forbiddenKey)
        XCTAssertEqual(validate(kVK_Delete, UInt32(optionKey | cmdKey)), .forbiddenKey)
        XCTAssertEqual(validate(kVK_ForwardDelete, UInt32(controlKey)), .forbiddenKey)
    }
}
