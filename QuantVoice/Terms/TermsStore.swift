//
//  TermsStore.swift
//  Quant Voice
//
//  Оболочка словаря терминов: файл terms.json, наблюдаемость для настроек,
//  системная проверка орфографии. Вся логика сопоставления и отбора живёт
//  в библиотеке `QuantVoiceTerms` и покрыта тестами — здесь её нет.
//
//  Файл: ~/Library/Application Support/QuantVoice/terms.json — переживает
//  обновление приложения, человекочитаем, правится руками; кнопка
//  «Перечитать файл» в настройках подхватывает ручные правки без перезапуска.
//
//  Латентность: подготовка шаблонов (фонетические ключи, нормализованные
//  формы) делается ОДИН раз при загрузке и правке словаря — пересборкой
//  матчера, — а на каждую фразу остаётся дешёвое сопоставление.
//

import AppKit
import Foundation
import Observation
import QuantVoiceTerms

@MainActor
@Observable
final class TermsStore: TermsApplying {

    /// Словарь. Наблюдаемый — вкладка «Термины» в настройках рисует его напрямую.
    private(set) var terms: [Term] = []

    /// Встроенный словарь (`Term.builtIn`) — только для показа в настройках,
    /// read-only. Отсортирован по каноническому написанию для читаемости.
    /// Не наблюдаемый: это статические данные бинарника, они не меняются.
    @ObservationIgnored
    let builtInTerms: [Term] = Term.builtIn.sorted {
        $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
    }

    private let logger: any Logging
    private let fileURL: URL

    /// Готовый матчер — кэш, не состояние UI. Пересобирается при каждой
    /// правке словаря.
    @ObservationIgnored private var matcher: TermMatcher

    /// Проверка орфографии системой. Отдельный объект, чтобы библиотека
    /// ничего не знала об AppKit.
    @ObservationIgnored private let spellChecker: SystemSpellChecker

    init(logger: any Logging, fileURL: URL? = nil) {
        self.logger = logger
        self.fileURL = fileURL ?? Self.defaultFileURL

        // Заодно это прогрев spell-сервера: первый запрос к нему дороже
        // последующих, пусть случится на старте, а не посреди диктовки.
        let checker = SystemSpellChecker()
        self.spellChecker = checker
        self.matcher = TermMatcher(terms: [], commonWords: checker)

        if !checker.knowsRussian {
            logger.warning("Термины: системная проверка орфографии не знает русского — фонетические замены кириллицы выключены")
        }

        load()
    }

    // MARK: - Загрузка и сохранение

    private static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("QuantVoice", isDirectory: true)
            .appendingPathComponent("terms.json")
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            terms = Term.seed
            rebuildMatcher()
            save()
            logger.info("Термины: файла нет — создан стартовый словарь, терминов: \(terms.count)")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try Self.makeDecoder().decode(TermsFile.self, from: data)
            terms = file.terms
            rebuildMatcher()
            logger.info("Термины: загружено из terms.json, терминов: \(terms.count)")
        } catch {
            // Файл правится руками — синтаксическая ошибка не повод его затирать.
            // Откладываем битый файл в сторону (правки не пропадают) и продолжаем
            // со стартовым словарём.
            logger.error("Термины: terms.json не читается (\(error.localizedDescription)) — откладываю в terms.invalid.json, беру стартовый словарь")
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("terms.invalid.json")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: fileURL, to: backup)
            terms = Term.seed
            rebuildMatcher()
            save()
        }
    }

    /// Перечитать файл — для подхвата ручных правок без перезапуска.
    func reloadFromDisk() {
        load()
    }

    private func rebuildMatcher() {
        matcher = TermMatcher(terms: activeTerms, commonWords: spellChecker)
    }

    /// Термины для матчера: встроенный словарь (`Term.builtIn`, едет в бинарнике
    /// и обновляется с приложением) плюс пользовательские из terms.json.
    /// Пользовательский термин перекрывает встроенный по каноническому написанию —
    /// правка руками всегда сильнее «фабричного» списка. В промпт встроенный
    /// словарь сознательно НЕ идёт (см. `transcriptionPrompt`): сотни терминов
    /// не влезают в бюджет подсказки, он работает только на уровне замен.
    private var activeTerms: [Term] {
        let overridden = Set(terms.map { $0.canonical.lowercased() })
        let builtin = Term.builtIn.filter { !overridden.contains($0.canonical.lowercased()) }
        return builtin + terms
    }

    private func save() {
        do {
            let data = try Self.makeEncoder().encode(TermsFile(terms: terms))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Термины: не удалось сохранить словарь: \(error.localizedDescription)")
        }
    }

    // JSONEncoder/JSONDecoder не Sendable — создаём по месту, в static-константах
    // не храним (то же правило, что с UserDefaults, см. Preferences).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // prettyPrinted + sortedKeys: файл читает и правит человек,
        // порядок ключей должен быть стабильным, а не скакать между записями.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Правка словаря (для настроек)

    /// Добавить или обновить (по id). Единая точка для редактора.
    func upsert(_ term: Term) {
        if let index = terms.firstIndex(where: { $0.id == term.id }) {
            terms[index] = term
        } else {
            terms.append(term)
        }
        rebuildMatcher()
        save()
        logger.info("Термины: словарь обновлён, терминов: \(terms.count)")
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        terms.removeAll { ids.contains($0.id) }
        rebuildMatcher()
        save()
        logger.info("Термины: удалено \(ids.count), осталось \(terms.count)")
    }

    // MARK: - Импорт и экспорт

    func exportData() throws -> Data {
        try Self.makeEncoder().encode(TermsFile(terms: terms))
    }

    /// Импорт со слиянием по каноническому написанию (без учёта регистра):
    /// пришедший термин обновляет существующий, новые добавляются.
    /// Замена словаря целиком была бы проще, но молча стирала бы накопленное.
    func importTerms(from data: Data) throws -> (added: Int, updated: Int) {
        let imported: [Term]
        if let file = try? Self.makeDecoder().decode(TermsFile.self, from: data) {
            imported = file.terms
        } else {
            // Голый массив терминов — тоже валидный импорт.
            imported = try Self.makeDecoder().decode([Term].self, from: data)
        }
        var added = 0
        var updated = 0
        for var incoming in imported {
            if let index = terms.firstIndex(where: {
                $0.canonical.lowercased() == incoming.canonical.lowercased()
            }) {
                incoming.id = terms[index].id
                incoming.lastUsedAt = terms[index].lastUsedAt ?? incoming.lastUsedAt
                terms[index] = incoming
                updated += 1
            } else {
                terms.append(incoming)
                added += 1
            }
        }
        rebuildMatcher()
        save()
        logger.info("Термины: импорт — добавлено \(added), обновлено \(updated)")
        return (added, updated)
    }

    // MARK: - Уровень 1: prompt-biasing (ТЗ 6.6)

    func transcriptionPrompt(for language: RecognitionLanguage) -> TermsPrompt? {
        guard let prompt = TermPromptBuilder.build(from: terms) else { return nil }
        return TermsPrompt(text: prompt.text, termCount: prompt.termCount)
    }

    // MARK: - Уровень 2: словарь замен (ТЗ 6.6)

    func applyReplacements(to text: String) -> TermsReplacementResult {
        let outcome = matcher.applyReplacements(to: text)
        if !outcome.usedTermIDs.isEmpty {
            markUsed(outcome.usedTermIDs)
        }
        return TermsReplacementResult(text: outcome.text,
                                      appliedCanonicals: outcome.appliedCanonicals)
    }

    /// Отметка «использован» питает отбор в промпт. Пишем на диск сразу:
    /// файл крошечный, а отложенная запись — состояние, которое теряется
    /// при выходе из приложения.
    private func markUsed(_ ids: Set<UUID>) {
        let now = Date()
        for index in terms.indices where ids.contains(terms[index].id) {
            terms[index].lastUsedAt = now
        }
        save()
    }
}

// MARK: - Системная проверка орфографии

/// «Обычное слово» = система знает его орфографию. Это и есть «простой
/// признак» из ТЗ: собственного частотного словаря русского у нас нет,
/// а NSSpellChecker работает офлайн, знает русский и уже загружен системой.
/// Слово с ошибкой («клоут», «энтропик») — кандидат на фонетическую замену;
/// правильно написанное слово фонетика не трогает никогда.
///
/// Живёт в приложении, а не в библиотеке: NSSpellChecker — это AppKit,
/// а ядро терминов должно оставаться тестируемым без него.
@MainActor
final class SystemSpellChecker: CommonWordChecking {

    /// Языки системной проверки на этой машине. nil — проверки нет,
    /// и фонетические замены для этого письма выключены: без словаря обычных
    /// слов нельзя отличить «мылные» от «клоут», а ложная замена хуже пропуска.
    private let russian: String?
    private let english: String?

    var knowsRussian: Bool { russian != nil }

    init() {
        let available = NSSpellChecker.shared.availableLanguages
        russian = Self.resolve("ru", in: available)
        english = Self.resolve("en", in: available)
    }

    nonisolated func isCommonWord(_ word: String) -> Bool {
        MainActor.assumeIsolated {
            let lower = word.lowercased()
            let isCyrillic = lower.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            guard let language = isCyrillic ? russian : english else {
                // Проверки нет — считаем слово обычным: фонетика молчит,
                // работают только точные варианты. Консервативная деградация.
                return true
            }
            let misspelled = NSSpellChecker.shared.checkSpelling(of: lower,
                                                                 startingAt: 0,
                                                                 language: language,
                                                                 wrap: false,
                                                                 inSpellDocumentWithTag: 0,
                                                                 wordCount: nil)
            return misspelled.location == NSNotFound
        }
    }

    /// Код языка проверки орфографии: точное совпадение или регион («ru_RU»).
    private static func resolve(_ code: String, in available: [String]) -> String? {
        if available.contains(code) { return code }
        return available.first { $0.hasPrefix(code + "_") }
    }
}
