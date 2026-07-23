//
//  PlainTextRefinerTests.swift
//  QuantVoiceTextTests
//
//  Постобработка правит текст пользователя молча, поэтому здесь, как
//  и у матчера, половина тестов про то, чего делать НЕЛЬЗЯ.
//

import XCTest
@testable import QuantVoiceText

final class PlainTextRefinerTests: XCTestCase {

    private func refine(_ s: String, _ o: RefinementOptions = .default) -> String {
        PlainTextRefiner.refine(s, options: o)
    }

    // MARK: - То, ради чего затевалось

    /// Живая жалоба 20.07.2026: модель не ставит точку в конце фразы.
    func testTrailingPeriodIsAdded() {
        XCTAssertEqual(refine("привет как дела"), "Привет как дела.")
        XCTAssertEqual(refine("собрано но не запустилось"), "Собрано но не запустилось.")
    }

    func testExistingTerminatorIsKept() {
        XCTAssertEqual(refine("Как дела?"), "Как дела?")
        XCTAssertEqual(refine("Ну наконец!"), "Ну наконец!")
        XCTAssertEqual(refine("Продолжение следует…"), "Продолжение следует…")
    }

    /// Фраза, оборванная намеренно, точкой не закрывается — иначе получится
    /// «список:.» и прочая ерунда.
    func testDanglingPunctuationIsNotClosed() {
        XCTAssertEqual(refine("нужно купить:"), "Нужно купить:")
        XCTAssertEqual(refine("во-первых,"), "Во-первых,")
    }

    func testSentencesAreCapitalized() {
        XCTAssertEqual(refine("первая. вторая. третья"),
                       "Первая. Вторая. Третья.")
        XCTAssertEqual(refine("это что? да ничего"), "Это что? Да ничего.")
    }

    // MARK: - Чего делать нельзя

    /// Термины внутри фразы регистр не меняют: «macOS» и «iPhone» пишутся
    /// со строчной осознанно, и «исправление» их сломает.
    func testLowercaseTermsInsideSentenceSurvive() {
        XCTAssertEqual(refine("работает на macOS и iPhone"),
                       "Работает на macOS и iPhone.")
    }

    /// Ни одно слово не должно потеряться — главное свойство слоя.
    func testNoWordsAreLost() {
        let input = "проверяем Claude Cowork и Claude Code на macOS"
        let output = refine(input).lowercased()
        for word in input.lowercased().split(separator: " ") {
            XCTAssertTrue(output.contains(word), "потерялось слово: \(word)")
        }
    }

    func testEmptyAndBlankTextIsUntouched() {
        XCTAssertEqual(refine(""), "")
        XCTAssertEqual(refine("   "), "   ")
        XCTAssertEqual(refine("\n"), "\n")
    }

    /// Сырой режим не трогает вообще ничего.
    func testRawModeChangesNothing() {
        let messy = "привет  ,  как дела"
        XCTAssertEqual(refine(messy, .raw), messy)
    }

    /// Диктовка вставляется в чужое поле — хвостовой перевод строки и ведущий
    /// пробел (Whisper часто отдаёт текст с него) принадлежат структуре текста,
    /// а не нам. Схлопываются только кратные пробелы.
    func testSurroundingWhitespaceIsPreserved() {
        XCTAssertEqual(refine(" привет\n"), " Привет.\n")
    }

    // MARK: - Пробелы и знаки

    func testWhitespaceIsTidied() {
        XCTAssertEqual(refine("привет  ,  как   дела"), "Привет, как дела.")
        XCTAssertEqual(refine("раз .два"), "Раз. Два.")
    }

    func testQuotesAndBracketsDoNotGetInnerSpaces() {
        XCTAssertEqual(refine("это « цитата » и ( скобка )"),
                       "Это «цитата» и (скобка).")
    }

    func testDoubledTerminatorsCollapse() {
        XCTAssertEqual(refine("готово.."), "Готово.")
    }

    // MARK: - Филлеры

    func testSoundFillersAreRemoved() {
        XCTAssertEqual(refine("эээ ну ладно"), "Ну ладно.")
        XCTAssertEqual(refine("ммм понятно"), "Понятно.")
    }

    /// Осмысленные слова, похожие на филлеры, остаются: вычищать «как бы»
    /// и «ну вот» правилами — значит менять сказанное.
    func testMeaningfulWordsAreNotStrippedAsFillers() {
        XCTAssertEqual(refine("ну вот и всё"), "Ну вот и всё.")
        XCTAssertEqual(refine("это как бы понятно"), "Это как бы понятно.")
        // Короткое «а» — союз, а не филлер.
        XCTAssertEqual(refine("а потом ушёл"), "А потом ушёл.")
    }
}
