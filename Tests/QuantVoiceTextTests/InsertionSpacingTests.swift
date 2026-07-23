//
//  InsertionSpacingTests.swift
//  QuantVoiceTextTests
//

import XCTest
@testable import QuantVoiceText

final class InsertionSpacingTests: XCTestCase {

    private let app = "com.anthropic.claudefordesktop"
    private let now = Date()

    private func previous(_ text: String,
                          app: String? = "com.anthropic.claudefordesktop",
                          secondsAgo: TimeInterval = 2) -> InsertionSpacing.Previous {
        InsertionSpacing.Previous(text: text, application: app,
                                  at: now.addingTimeInterval(-secondsAgo))
    }

    private func separator(_ text: String,
                           after previous: InsertionSpacing.Previous?,
                           app: String? = "com.anthropic.claudefordesktop") -> String {
        InsertionSpacing.separator(for: text, previous: previous, application: app, now: now)
    }

    /// Живой баг 20.07.2026: «…распознается.Специально говорю…».
    func testConsecutiveDictationsGetASpace() {
        XCTAssertEqual(separator("Специально говорю.", after: previous("Как это распознается.")), " ")
    }

    func testFirstInsertionGetsNothing() {
        XCTAssertEqual(separator("Привет.", after: nil), "")
    }

    func testExistingWhitespaceIsNotDoubled() {
        XCTAssertEqual(separator("Привет.", after: previous("Раз, два. ")), "")
        XCTAssertEqual(separator(" Привет.", after: previous("Раз, два.")), "")
        XCTAssertEqual(separator("Привет.", after: previous("Абзац\n")), "")
    }

    /// Знаки препинания приклеиваются к предыдущему слову, а не отрываются.
    func testPunctuationStartDoesNotGetASpace() {
        XCTAssertEqual(separator(", а потом ушёл.", after: previous("Сначала пришёл")), "")
        XCTAssertEqual(separator("…и всё.", after: previous("Ну")), "")
    }

    func testInsideBracketsAndQuotesNoSpace() {
        XCTAssertEqual(separator("цитата", after: previous("Он сказал: «")), "")
        XCTAssertEqual(separator("скобка", after: previous("Пример (")), "")
    }

    /// Сменилось приложение — что в его поле, мы не знаем.
    func testOtherApplicationGetsNothing() {
        XCTAssertEqual(separator("Привет.", after: previous("Раз.", app: "com.apple.Safari")), "")
    }

    /// Минуту спустя это уже не диктовка подряд, а новая мысль неизвестно где.
    func testStalePreviousInsertionGetsNothing() {
        XCTAssertEqual(separator("Привет.", after: previous("Раз.", secondsAgo: 120)), "")
    }
}
