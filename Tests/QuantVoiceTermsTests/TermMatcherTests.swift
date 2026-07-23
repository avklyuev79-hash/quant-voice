//
//  TermMatcherTests.swift
//  QuantVoiceTermsTests
//
//  Первые тесты проекта. Матчер — единственное место, где ошибка ТИХО портит
//  правильный текст пользователя: он не падает, не пишет в лог, просто
//  подменяет слово. Поэтому здесь важнее не «ловит ли он термины», а
//  «не трогает ли он то, что трогать нельзя» — половина файла про это.
//

import XCTest
@testable import QuantVoiceTerms

/// Подставная проверка орфографии: обычными считаются только перечисленные
/// слова. Настоящий NSSpellChecker знает весь русский, но тащить AppKit
/// в тесты нельзя, а список нужных слов на тестовых фразах короткий.
private final class FakeSpellChecker: CommonWordChecking {
    private let known: Set<String>
    init(_ known: [String] = []) { self.known = Set(known.map { $0.lowercased() }) }
    func isCommonWord(_ word: String) -> Bool { known.contains(word.lowercased()) }
}

final class TermMatcherTests: XCTestCase {

    private func makeMatcher(_ terms: [Term], known: [String] = []) -> TermMatcher {
        TermMatcher(terms: terms, commonWords: FakeSpellChecker(known))
    }

    private var claude: Term {
        Term(canonical: "Claude", language: "en", variants: ["клод", "клоут", "клауд"])
    }
    private var quant: Term {
        Term(canonical: "Quant", language: "en", variants: ["квант"])
    }

    // MARK: - База

    func testExactVariantIsReplaced() {
        let m = makeMatcher([claude])
        XCTAssertEqual(m.applyReplacements(to: "открой клоут").text, "открой Claude")
    }

    func testCaseIsFixed() {
        let m = makeMatcher([claude])
        XCTAssertEqual(m.applyReplacements(to: "открой claude").text, "открой Claude")
    }

    func testAlreadyCanonicalTextIsUntouchedButCounted() {
        let term = claude
        let m = makeMatcher([term])
        let out = m.applyReplacements(to: "открой Claude")
        XCTAssertEqual(out.text, "открой Claude")
        XCTAssertTrue(out.appliedCanonicals.isEmpty, "правильный текст не считается заменой")
        XCTAssertTrue(out.usedTermIDs.contains(term.id), "но термин встретился — он должен освежиться в промпте")
    }

    func testLongerPatternWins() {
        let m = makeMatcher([claude,
                             Term(canonical: "Claude Cowork", variants: ["клоут коворг"])])
        XCTAssertEqual(m.applyReplacements(to: "запусти клоут коворг").text,
                       "запусти Claude Cowork")
    }

    // MARK: - Падежи (то, ради чего затевалась переделка)

    /// Живая ослышка беты 19.07.2026: модель добавила слог, старый матчер
    /// её не узнавал, и лечилось это вписыванием формы в словарь руками.
    func testDiminutiveFormIsMatched() {
        let m = makeMatcher([claude])
        XCTAssertEqual(m.applyReplacements(to: "Клоутка не отвечает").text,
                       "Claude не отвечает")
    }

    func testDeclensionsAreMatched() {
        let m = makeMatcher([claude, quant], known: ["в", "и", "работаю"])
        let cases: [(String, String)] = [
            ("спроси клоуда", "спроси Claude"),
            ("говорил с клоудом", "говорил с Claude"),
            ("работаю в Кванте", "работаю в Quant"),
            ("много клоутов", "много Claude"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(m.applyReplacements(to: input).text, expected, "форма: \(input)")
        }
    }

    // MARK: - Чего делать нельзя

    /// Главный риск морфологии: «телеграмма» — обычное русское слово, и
    /// отсечение «а» превращает его в вариант термина Telegram. Спасает
    /// орфографический фильтр, поэтому проверяем именно его.
    func testCommonWordIsNeverTouched() {
        let m = makeMatcher([Term(canonical: "Telegram", variants: ["телеграм", "телеграмм"])],
                            known: ["телеграмма", "пришла"])
        XCTAssertEqual(m.applyReplacements(to: "пришла телеграмма").text, "пришла телеграмма")
    }

    /// Ослышка на обычных словах не должна притягиваться к терминам:
    /// «молниеносно» модель слышит как «мылные носы» (живой пример из M4).
    func testUnrelatedMisspellingIsNotPulledToTerm() {
        let m = makeMatcher([claude, quant])
        XCTAssertEqual(m.applyReplacements(to: "мылные носы").text, "мылные носы")
    }

    /// Отсечение не должно съедать больше окончания: «квантование» —
    /// самостоятельное слово, а не форма термина «Quant».
    func testStemmingDoesNotEatWholeWord() {
        let m = makeMatcher([quant])
        XCTAssertEqual(m.applyReplacements(to: "квантование сигнала").text,
                       "квантование сигнала")
    }

    /// Аббревиатуры фонетике не отдаём: на двух буквах любое сравнение
    /// звуков превращает в термин что угодно.
    func testShortAbbreviationsMatchOnlyExactly() {
        let m = makeMatcher([Term(canonical: "ИП"), Term(canonical: "ТЗ", variants: ["тэзэ"])])
        XCTAssertEqual(m.applyReplacements(to: "ИП и тэзэ").text, "ИП и ТЗ")
        XCTAssertEqual(m.applyReplacements(to: "иди уж").text, "иди уж")
    }

    // MARK: - Сохранность текста

    func testPunctuationAndSpacingSurvive() {
        let m = makeMatcher([claude])
        XCTAssertEqual(m.applyReplacements(to: "(клоут, привет)").text, "(Claude, привет)")
        XCTAssertEqual(m.applyReplacements(to: "  клоут\n").text, "  Claude\n")
    }

    func testEmptyDictionaryAndEmptyTextAreSafe() {
        XCTAssertEqual(makeMatcher([]).applyReplacements(to: "текст").text, "текст")
        XCTAssertEqual(makeMatcher([claude]).applyReplacements(to: "").text, "")
    }

    // MARK: - Стартовый словарь

    /// Живая диктовка 20.07.2026: модель писала «Cloud» вместо «Claude».
    /// Это корректное английское слово, орфографический фильтр его защищает,
    /// поэтому ловится оно только явным вариантом в словаре.
    func testSeedCatchesCloudAsClaude() {
        let m = makeMatcher(Term.seed, known: ["cloud", "code", "open"])
        XCTAssertEqual(m.applyReplacements(to: "открой Cloud").text, "открой Claude")
    }

    /// И при этом составной термин не должен рассыпаться: «Claude Code»
    /// обязан выиграть у одиночного варианта, иначе получим «Claude Claude».
    func testSeedKeepsCompoundTermsIntact() {
        let m = makeMatcher(Term.seed, known: ["cloud", "code", "cowork"])
        XCTAssertEqual(m.applyReplacements(to: "Claude Code").text, "Claude Code")
        XCTAssertEqual(m.applyReplacements(to: "cloud code").text, "Claude Code")
        XCTAssertEqual(m.applyReplacements(to: "клоут коворг").text, "Claude Cowork")
    }

    func testAppliedCanonicalsReportWhatChanged() {
        let m = makeMatcher([claude, quant], known: ["и"])
        let out = m.applyReplacements(to: "клоут и квант")
        XCTAssertEqual(out.appliedCanonicals, ["Claude", "Quant"])
    }
}
