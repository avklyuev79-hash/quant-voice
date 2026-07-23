//
//  TermMatcher.swift
//  QuantVoiceTerms
//
//  Словарь замен (ТЗ 6.6, уровень 2) — чистая логика, без AppKit и файлов.
//  Оболочка (TermsStore) отвечает за terms.json, наблюдаемость и системную
//  проверку орфографии; здесь только сопоставление и подстановка.
//
//  Разделение появилось ради тестов: сопоставление — единственное место
//  проекта, где ошибка тихо портит правильный текст пользователя, и держать
//  его непокрытым нельзя. Всё, что мешало тестам (главный актор, NSSpellChecker,
//  запись на диск), вынесено наружу или спрятано за протокол.
//
//  Латентность: бюджет замен — единицы миллисекунд. Поэтому вся подготовка
//  (фонетические ключи, нормализованные формы) делается ОДИН раз в `init`,
//  а на каждую фразу остаётся дешёвое сопоставление по готовому кэшу.
//
//  Порядок проверок в окне — от самой надёжной к самой рискованной:
//    1. точное совпадение с каноническим написанием или явным вариантом;
//    2. то же, но с отсечённым русским окончанием;
//    3. фонетика (только для слов вне орфографического словаря).
//  Первое сработавшее выигрывает, дальше не идём.
//

import Foundation

/// Внешняя проверка «система знает такое слово». Реализуется через
/// NSSpellChecker в приложении и таблицей в тестах.
public protocol CommonWordChecking: AnyObject {
    /// true — слово написано правильно и трогать его нельзя.
    /// Реализация обязана быть дешёвой: вызывается по слову на фразу.
    func isCommonWord(_ word: String) -> Bool
}

/// Проверка, которая считает обычным всё. Консервативная деградация для
/// машины без нужного языка в проверке орфографии: фонетика молчит,
/// работают только точные варианты.
public final class AllWordsAreCommon: CommonWordChecking {
    public init() {}
    public func isCommonWord(_ word: String) -> Bool { true }
}

public struct TermMatcher {

    /// Результат применения словаря к тексту.
    public struct Replacement: Equatable, Sendable {
        public let text: String
        /// Канонические написания сработавших терминов — ТОЛЬКО для лога.
        public let appliedCanonicals: [String]
        /// Термины, встретившиеся во фразе (включая уже правильно написанные) —
        /// оболочка отмечает их «недавно использованными» для отбора в промпт.
        public let usedTermIDs: Set<UUID>

        public init(text: String, appliedCanonicals: [String], usedTermIDs: Set<UUID>) {
            self.text = text
            self.appliedCanonicals = appliedCanonicals
            self.usedTermIDs = usedTermIDs
        }
    }

    private let patterns: [PreparedPattern]
    private let commonWords: any CommonWordChecking

    public init(terms: [Term], commonWords: any CommonWordChecking) {
        self.commonWords = commonWords
        self.patterns = Self.buildPatterns(from: terms)
    }

    public var isEmpty: Bool { patterns.isEmpty }

    // MARK: - Применение

    public func applyReplacements(to text: String) -> Replacement {
        guard !patterns.isEmpty, !text.isEmpty else {
            return Replacement(text: text, appliedCanonicals: [], usedTermIDs: [])
        }

        let (tokens, trailing) = Self.tokenize(text)
        var result = ""
        var applied: [String] = []
        var usedIDs = Set<UUID>()
        // Кэши на фразу: одно слово попадает в несколько окон и шаблонов.
        var commonCache: [String: Bool] = [:]
        var candidateCache: [String: [Morphology.Candidate]] = [:]
        var keyCache: [String: String] = [:]

        var index = 0
        while index < tokens.count {
            var replacedWidth = 0
            // Окно уже написано правильно — сколько слов пропустить, не трогая.
            var canonicalWidth = 0
            for pattern in patterns { // отсортированы: длинные шаблоны первыми
                guard index + pattern.wordCount <= tokens.count else { continue }
                let window = Array(tokens[index ..< index + pattern.wordCount])
                let kind = match(pattern,
                                 window: window,
                                 commonCache: &commonCache,
                                 candidateCache: &candidateCache,
                                 keyCache: &keyCache)
                if kind == .alreadyCanonical {
                    // Текст уже верный — освежаем «недавно использован», чтобы
                    // термин держался в промпте, и уходим с этой позиции.
                    //
                    // Перебор прекращается, а не продолжается: следующим
                    // шаблоном идёт вариант того же термина, и фонетика
                    // радостно «заменит» Claude на Claude. Текст от этого
                    // не изменится, но замена попадёт в лог, и там, где надо
                    // разбираться, что матчер натворил, появится шум.
                    usedIDs.insert(pattern.termID)
                    canonicalWidth = pattern.wordCount
                    break
                }
                guard kind == .replace else { continue }
                let first = window[0]
                let last = window[pattern.wordCount - 1]
                // Пунктуация вокруг ядра сохраняется: «(клоут,» → «(Claude,».
                result += first.leading + first.prefix + pattern.canonical + last.suffix
                applied.append(pattern.canonical)
                usedIDs.insert(pattern.termID)
                replacedWidth = pattern.wordCount
                break
            }
            if replacedWidth > 0 {
                index += replacedWidth
            } else if canonicalWidth > 0 {
                for offset in 0 ..< canonicalWidth {
                    let token = tokens[index + offset]
                    result += token.leading + token.text
                }
                index += canonicalWidth
            } else {
                result += tokens[index].leading + tokens[index].text
                index += 1
            }
        }
        result += trailing

        return Replacement(text: result, appliedCanonicals: applied, usedTermIDs: usedIDs)
    }

    // MARK: - Сопоставление

    enum MatchKind: Equatable {
        case none
        /// Окно уже совпадает с каноническим написанием буква в букву.
        case alreadyCanonical
        case replace
    }

    func match(_ pattern: PreparedPattern,
               window: [Token],
               commonCache: inout [String: Bool],
               candidateCache: inout [String: [Morphology.Candidate]],
               keyCache: inout [String: String]) -> MatchKind {
        // Чистая пунктуация в окне — не слово, сопоставлять нечего.
        guard window.allSatisfy({ !$0.core.isEmpty }) else { return .none }

        let cores = window.map(\.core)

        // 1. ТОЧНЫЙ ПУТЬ. Каноническое написание или явный вариант.
        // Словарный фильтр здесь не нужен: пользователь сам сказал, что
        // «квант» в его речи — это Quant. Сюда же входит починка регистра.
        let coreJoined = cores.joined(separator: " ")
        if Self.normalizedForm(coreJoined) == pattern.normalized {
            return coreJoined == pattern.canonical ? .alreadyCanonical : .replace
        }

        // Дальше — пути, расширяющие пространство совпадений, и оба закрыты
        // орфографическим фильтром: правильно написанное слово не трогаем
        // никогда. Без этого «телеграмма» (сообщение) стала бы «Telegram»,
        // а «мылные носы» — брендом.
        for core in cores {
            if isCommonWord(core, cache: &commonCache) { return .none }
        }

        // 2. ТОЧНЫЙ ПУТЬ ПО ОСНОВЕ. «в Кванте» → «квант» → вариант Quant.
        // Позиционно: у каждого слова окна свой набор основ, комбинации
        // не перебираем — падеж падает на слова независимо.
        var matchedByStem = true
        for (position, core) in cores.enumerated() {
            let expected = pattern.normalizedWords[position]
            let candidates = stemCandidates(for: core, cache: &candidateCache)
            let hit = candidates.contains { Self.normalizedForm($0.text) == expected }
            if !hit { matchedByStem = false; break }
        }
        if matchedByStem { return .replace }

        // 3. ФОНЕТИКА. Только для шаблонов, достаточно длинных для звукового
        // сравнения (аббревиатуры «ИП», «ТЗ» ловятся лишь точным совпадением).
        guard let termKeys = pattern.wordKeys else { return .none }
        for (position, core) in cores.enumerated() {
            guard core.count >= 3 else { return .none }
            let candidates = stemCandidates(for: core, cache: &candidateCache)
            let hit = candidates.contains { candidate in
                let wordKey = phoneticKey(for: candidate.text, cache: &keyCache)
                guard wordKey.count >= 3 else { return false }
                return Phonetics.withinTolerance(termKey: termKeys[position],
                                                 wordKey: wordKey,
                                                 requireSameOnset: candidate.truncated)
            }
            guard hit else { return .none }
        }
        return .replace
    }

    // MARK: - Кэши

    private func isCommonWord(_ word: String, cache: inout [String: Bool]) -> Bool {
        let lower = word.lowercased()
        if let cached = cache[lower] { return cached }
        let value = commonWords.isCommonWord(lower)
        cache[lower] = value
        return value
    }

    private func stemCandidates(for word: String,
                                cache: inout [String: [Morphology.Candidate]]) -> [Morphology.Candidate] {
        let lower = word.lowercased()
        if let cached = cache[lower] { return cached }
        let value = Morphology.stemCandidates(for: lower)
        cache[lower] = value
        return value
    }

    private func phoneticKey(for word: String, cache: inout [String: String]) -> String {
        if let cached = cache[word] { return cached }
        let value = Phonetics.key(for: word)
        cache[word] = value
        return value
    }

    // MARK: - Подготовленные шаблоны

    struct PreparedPattern {
        let termID: UUID
        let canonical: String
        let wordCount: Int
        /// Нормализованная форма для точного совпадения: строчные буквы и цифры
        /// без пунктуации и пробелов («Яндекс.Директ» → «яндексдирект»).
        let normalized: String
        /// То же, но по словам — для сопоставления по основам, где каждое
        /// слово окна разбирается отдельно.
        let normalizedWords: [String]
        /// Фонетические ключи по словам. nil — шаблон слишком короткий для
        /// фонетики (аббревиатуры ловим только точным совпадением).
        let wordKeys: [String]?
    }

    static func buildPatterns(from terms: [Term]) -> [PreparedPattern] {
        var built: [PreparedPattern] = []
        var seen = Set<String>()
        for term in terms {
            // Каноническое написание и каждый вариант — отдельные шаблоны:
            // у них может быть разное число слов («Яндекс.Директ» — одно,
            // «яндекс директ» — два), а варианты дают фонетике честные
            // кириллические опоры вместо угаданного чтения латиницы.
            for source in [term.canonical] + term.variants {
                let words = source.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty else { continue }
                let normalized = normalizedForm(source)
                guard !normalized.isEmpty else { continue }
                let dedupKey = "\(term.id)|\(words.count)|\(normalized)"
                guard seen.insert(dedupKey).inserted else { continue }

                let keys = words.map { Phonetics.key(for: $0) }
                // Фонетика только если термин её разрешает (пользовательские —
                // да, встроенный словарь — нет, см. Term.fuzzy) и ключи достаточно
                // длинные. Иначе шаблон ловится лишь точным совпадением и основой.
                let phoneticEligible = term.fuzzy && keys.allSatisfy { $0.count >= 3 }
                built.append(PreparedPattern(termID: term.id,
                                             canonical: term.canonical,
                                             wordCount: words.count,
                                             normalized: normalized,
                                             normalizedWords: words.map(normalizedForm),
                                             wordKeys: phoneticEligible ? keys : nil))
            }
        }
        // Длинные шаблоны первыми: «Claude Cowork» должен победить «Claude».
        return built.sorted { $0.wordCount > $1.wordCount }
    }

    /// Строчные буквы и цифры, всё остальное выпадает. Общая нормализация
    /// для точного сопоставления: «яндекс-директ», «Яндекс Директ»
    /// и «Яндекс.Директ» дают одну и ту же форму.
    static func normalizedForm(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() where ch.isLetter || ch.isNumber {
            out.append(ch)
        }
        return out
    }

    // MARK: - Токенизация

    struct Token: Equatable {
        /// Пробелы перед словом — как в оригинале, чтобы собрать текст без потерь.
        let leading: String
        /// Слово целиком, с прилипшей пунктуацией: «(клоут,».
        let text: String
        /// Пунктуация до ядра, само ядро, пунктуация после.
        let prefix: String
        let core: String
        let suffix: String
    }

    static func tokenize(_ text: String) -> (tokens: [Token], trailing: String) {
        var tokens: [Token] = []
        var leading = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            tokens.append(makeToken(leading: leading, text: word))
            leading = ""
            word = ""
        }
        for ch in text {
            if ch.isWhitespace {
                flush()
                leading.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        // Остаток leading — хвостовые пробелы/переводы строк, не теряем их.
        return (tokens, leading)
    }

    private static func makeToken(leading: String, text: String) -> Token {
        let chars = Array(text)
        var start = 0
        var end = chars.count
        while start < end, !(chars[start].isLetter || chars[start].isNumber) { start += 1 }
        while end > start, !(chars[end - 1].isLetter || chars[end - 1].isNumber) { end -= 1 }
        return Token(leading: leading,
                     text: text,
                     prefix: String(chars[0..<start]),
                     core: String(chars[start..<end]),
                     suffix: String(chars[end...]))
    }
}
