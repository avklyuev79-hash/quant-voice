//
//  TermCoreTests.swift
//  QuantVoiceTermsTests
//
//  Слои под матчером: фонетические ключи, отсечение окончаний, отбор
//  в подсказку модели. Здесь закреплены те решения, которые легко
//  разломать «безобидной» правкой таблиц.
//

import XCTest
@testable import QuantVoiceTerms

final class PhoneticsTests: XCTestCase {

    /// Живые пары из работы: латиница и кириллическая ослышка должны
    /// сойтись в одном ключе. Если таблицу трогали — упадёт здесь.
    func testKeysConvergeAcrossAlphabets() {
        XCTAssertEqual(Phonetics.key(for: "Claude"), Phonetics.key(for: "клоут"))
        XCTAssertEqual(Phonetics.key(for: "Cowork"), Phonetics.key(for: "коворг"))
        XCTAssertEqual(Phonetics.key(for: "Anthropic"), Phonetics.key(for: "антропик"))
        XCTAssertEqual(Phonetics.key(for: "WhisperKit"), Phonetics.key(for: "висперкит"))
    }

    func testVoicingAndUnstressedVowelsCollapse() {
        // Оглушение на конце и аканье — то, что русское ухо не различает.
        XCTAssertEqual(Phonetics.key(for: "коворг"), Phonetics.key(for: "коворк"))
        XCTAssertEqual(Phonetics.key(for: "клоуд"), Phonetics.key(for: "клоут"))
    }

    /// Первый звук стоит вдвое: ослышка почти всегда сохраняет начало слова,
    /// и расхождение там значит «другое слово», а не «другой падеж».
    func testOnsetCostsDouble() {
        XCTAssertEqual(Phonetics.weight(atTermPosition: 1), 2)
        XCTAssertEqual(Phonetics.weight(atTermPosition: 2), 1)
        // Замена в начале дороже такой же замены в хвосте.
        XCTAssertGreaterThan(Phonetics.distance("KLAUT", "PLAUT"),
                             Phonetics.distance("KLAUT", "KLAUP"))
    }

    func testToleranceGrowsWithLength() {
        XCTAssertEqual(Phonetics.maxDistance(forKeyLength: 3), 0)
        XCTAssertEqual(Phonetics.maxDistance(forKeyLength: 5), 1)
        XCTAssertEqual(Phonetics.maxDistance(forKeyLength: 8), 2)
        XCTAssertEqual(Phonetics.maxDistance(forKeyLength: 14), 3)
    }

    func testShortKeysRequireExactMatch() {
        XCTAssertTrue(Phonetics.withinTolerance(termKey: "KAT", wordKey: "KAT"))
        XCTAssertFalse(Phonetics.withinTolerance(termKey: "KAT", wordKey: "KAP"))
    }

    /// Для усечённых основ требуем совпадения первого звука — страховка
    /// за то, что отсечение расширило пространство совпадений.
    func testTruncatedStemsRequireSameOnset() {
        XCTAssertFalse(Phonetics.withinTolerance(termKey: "KLAUT", wordKey: "PLAUT",
                                                 requireSameOnset: true))
    }
}

final class MorphologyTests: XCTestCase {

    private func stems(_ word: String) -> [String] {
        Morphology.stemCandidates(for: word).map(\.text)
    }

    func testWordItselfComesFirst() {
        XCTAssertEqual(Morphology.stemCandidates(for: "клоут").first,
                       Morphology.Candidate(text: "клоут", truncated: false))
    }

    func testCommonEndingsAreStripped() {
        XCTAssertTrue(stems("клоуда").contains("клоуд"))
        XCTAssertTrue(stems("клоудом").contains("клоуд"))
        XCTAssertTrue(stems("кванте").contains("квант"))
        XCTAssertTrue(stems("квантами").contains("квант"))
    }

    /// Уменьшительное «-к-» снимается вторым шагом: «клоутка» → «клоутк» → «клоут».
    func testDiminutiveSuffixIsStripped() {
        XCTAssertTrue(stems("клоутка").contains("клоут"))
        XCTAssertTrue(stems("клоутками").contains("клоут"))
    }

    /// Основа не может стать короче 3 символов и меньше 55% слова —
    /// иначе «квантование» превратилось бы в «квант».
    func testStemsStayRecognizable() {
        XCTAssertFalse(stems("квантование").contains("квант"))
        XCTAssertFalse(stems("оси").contains("ос"))
        for stem in stems("клоутками") { XCTAssertGreaterThanOrEqual(stem.count, 3) }
    }

    /// Глагольных окончаний в таблице нет: они открыли бы дорогу
    /// к сопоставлению терминов с обычными глаголами.
    func testVerbEndingsAreNotStripped() {
        XCTAssertFalse(stems("работать").contains("работ"))
    }
}

final class TermPromptBuilderTests: XCTestCase {

    func testEmptyDictionaryGivesNoPrompt() {
        XCTAssertNil(TermPromptBuilder.build(from: []))
    }

    func testPinnedTermsAlwaysMakeItAndCloseThePrompt() {
        let terms = [
            Term(canonical: "Quant", pinned: true),
            Term(canonical: "Claude", pinned: true),
            Term(canonical: "Anthropic"),
        ]
        let prompt = TermPromptBuilder.build(from: terms)
        XCTAssertNotNil(prompt)
        // Whisper сильнее верит концу промпта — закреплённые идут последними.
        XCTAssertTrue(prompt!.text.hasSuffix("Quant, Claude"), "получено: \(prompt!.text)")
    }

    /// Бюджет — про латентность, а не про лимит модели: каждый лишний токен
    /// подсказки стоит ~25 мс на каждой фразе.
    func testBudgetIsRespected() {
        let terms = (0..<40).map { Term(canonical: "Термин\($0)") }
        let prompt = TermPromptBuilder.build(from: terms, budget: 60)
        XCTAssertNotNil(prompt)
        XCTAssertLessThanOrEqual(prompt!.text.count, 60)
    }

    func testFreshTermsWinOverStaleOnes() {
        let stale = Term(canonical: "Старый", lastUsedAt: Date(timeIntervalSince1970: 0))
        let fresh = Term(canonical: "Свежий", lastUsedAt: Date())
        let prompt = TermPromptBuilder.build(from: [stale, fresh], budget: 10)
        XCTAssertEqual(prompt?.text, "Свежий")
    }
}
