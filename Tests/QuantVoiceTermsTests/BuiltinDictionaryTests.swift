//
//  BuiltinDictionaryTests.swift
//  QuantVoiceTermsTests
//
//  Проверка встроенного словаря (`Term.builtIn`). Как и у матчера, половина
//  файла — про то, чего делать НЕЛЬЗЯ: словарь на сотню терминов опаснее
//  ручного десятка, потому что легко украсть обычное слово. Негативные тесты
//  моделируют настоящий NSSpellChecker списком известных слов — именно он
//  защищает правильный текст на путях по основе и по фонетике.
//

import XCTest
@testable import QuantVoiceTerms

final class BuiltinDictionaryTests: XCTestCase {

    /// Подставная проверка орфографии со списком реальных русских слов,
    /// которые встречаются в негативных тестах. Настоящий NSSpellChecker
    /// знает их все; здесь перечислены только нужные.
    private final class FakeSpellChecker: CommonWordChecking {
        private let known: Set<String>
        init(_ known: [String]) { self.known = Set(known.map { $0.lowercased() }) }
        func isCommonWord(_ word: String) -> Bool { known.contains(word.lowercased()) }
    }

    private func makeMatcher(known: [String] = []) -> TermMatcher {
        TermMatcher(terms: Term.builtIn, commonWords: FakeSpellChecker(known))
    }

    // MARK: - Бренды ловятся

    func testBrandFromCyrillicVariant() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "открой ютуб").text, "открой YouTube")
        XCTAssertEqual(m.applyReplacements(to: "оплата через пейпал").text, "оплата через PayPal")
        XCTAssertEqual(m.applyReplacements(to: "поставил вотсап").text, "поставил WhatsApp")
    }

    func testBrandCaseIsFixed() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "зашёл в youtube").text, "зашёл в YouTube")
    }

    func testMultiwordBrand() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "гит лаб снова упал").text, "GitLab снова упал")
    }

    func testBrandSurvivesPunctuation() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "(ютуб),").text, "(YouTube),")
    }

    // MARK: - Аббревиатуры (только точное совпадение = починка регистра)

    func testAbbreviationCaseIsFixed() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "посчитай ндс за квартал").text, "посчитай НДС за квартал")
        XCTAssertEqual(m.applyReplacements(to: "укажи инн и кпп").text, "укажи ИНН и КПП")
    }

    func testLatinAbbreviationFromCyrillicMishearing() {
        let m = makeMatcher()
        XCTAssertEqual(m.applyReplacements(to: "настроил црм").text, "настроил CRM")
        XCTAssertEqual(m.applyReplacements(to: "занимаюсь сео").text, "занимаюсь SEO")
    }

    // MARK: - Чего делать НЕЛЬЗЯ

    /// «по» — предлог, а не сокращение ПО: ПО в словарь сознательно не внесён.
    func testCommonPrepositionIsNotAbbreviated() {
        let m = makeMatcher(known: ["по", "это", "правилам"])
        XCTAssertEqual(m.applyReplacements(to: "это по правилам").text, "это по правилам")
    }

    /// «гости» не должны стать «ГОСТ»: основа «гост» совпала бы, но
    /// орфографический фильтр защищает известное слово.
    func testKnownWordIsNotStemmedIntoAbbreviation() {
        let m = makeMatcher(known: ["пришли", "гости"])
        XCTAssertEqual(m.applyReplacements(to: "пришли гости").text, "пришли гости")
    }

    /// «питон» (змея) не должен стать Python: вариант в словаре только «пайтон»,
    /// а фонетическую близость гасит орфографический фильтр.
    func testCommonWordIsNotMangledByPhonetics() {
        let m = makeMatcher(known: ["люблю", "питон", "красный", "мак", "поле"])
        XCTAssertEqual(m.applyReplacements(to: "люблю питон").text, "люблю питон")
        XCTAssertEqual(m.applyReplacements(to: "красный мак в поле").text, "красный мак в поле")
    }

    /// Ключевая гарантия встроенного словаря: он НЕ полагается на фонетику,
    /// поэтому обычные слова, близкие по звуку к бренду, не крадутся ДАЖЕ без
    /// орфографического фильтра. «через» не должно стать «Chery», «лама» — «Llama».
    /// Проверка с пустым списком известных слов — если бы фонетика была включена,
    /// защиты бы не было и тест бы упал.
    func testBuiltinDoesNotRelyOnPhonetics() {
        let m = makeMatcher(known: [])
        XCTAssertEqual(m.applyReplacements(to: "оплата через пейпал").text, "оплата через PayPal")
        XCTAssertEqual(m.applyReplacements(to: "через час").text, "через час")
        XCTAssertEqual(m.applyReplacements(to: "лама в горах").text, "лама в горах")
    }

    /// Обычная русская фраза без единого термина проходит насквозь без правок.
    func testPlainSentenceUntouched() {
        let m = makeMatcher(known: ["мы", "договорились", "встретиться", "завтра", "утром"])
        let phrase = "мы договорились встретиться завтра утром"
        XCTAssertEqual(m.applyReplacements(to: phrase).text, phrase)
    }

    // MARK: - Санитарные

    func testDictionaryHasNoDuplicateCanonicals() {
        let canonicals = Term.builtIn.map { $0.canonical.lowercased() }
        XCTAssertEqual(canonicals.count, Set(canonicals).count, "дубликаты канонических написаний во встроенном словаре")
    }

    /// Латентность замен — бюджет единицы–десятки миллисекунд на фразу даже
    /// на полном словаре. Грубая проверка, что порядок величины не уехал.
    func testReplacementLatencyIsReasonable() {
        let m = makeMatcher(known: ["мы", "обсудили", "проект", "и", "решили", "перенести", "встречу"])
        let phrase = "мы обсудили проект и решили перенести встречу на следующую неделю чтобы всё успеть подготовить"
        let start = Date()
        for _ in 0 ..< 200 { _ = m.applyReplacements(to: phrase) }
        let perCall = Date().timeIntervalSince(start) / 200.0
        XCTAssertLessThan(perCall, 0.05, "замена на фразу заняла \(perCall * 1000) мс — слишком долго")
    }
}
