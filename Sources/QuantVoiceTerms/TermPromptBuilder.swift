//
//  TermPromptBuilder.swift
//  QuantVoiceTerms
//
//  Отбор терминов в подсказку модели (ТЗ 6.6, уровень 1).
//
//  Вынесено из TermsStore вместе с матчером: отбор — чистая функция от
//  словаря, и единственный способ убедиться, что бюджет соблюдается,
//  а закреплённые термины не выпадают, — прогнать его тестами.
//

import Foundation

public enum TermPromptBuilder {

    public struct Prompt: Equatable, Sendable {
        public let text: String
        /// Сколько терминов вошло — для лога координатора.
        public let termCount: Int

        public init(text: String, termCount: Int) {
            self.text = text
            self.termCount = termCount
        }
    }

    /// Бюджет промпта в символах.
    ///
    /// ⚠️ Ограничение здесь — НЕ лимит Whisper в 224 токена, а латентность.
    /// Замер 19.07.2026 на живой машине: словарь из 11 терминов с несущей
    /// фразой поднял циклы декодера с 15–20 до 64–67 на том же аудио,
    /// то есть распознавание с 570 мс до 1500 мс. Каждый токен промпта
    /// стоит примерно как токен ответа — около 25 мс на M1 с профилем `fast`.
    ///
    /// Отсюда бюджет: 60 символов ≈ 20 токенов ≈ 500 мс сверху в худшем случае,
    /// и это уже на грани терпимого. Расширять его нельзя без пересмотра
    /// всей схемы — только вместе с потоковым распознаванием.
    public static let defaultCharacterBudget = 60

    public static func build(from terms: [Term],
                             budget: Int = defaultCharacterBudget) -> Prompt? {
        guard !terms.isEmpty else { return nil }

        // ОТБОР. Правило простое и честное: закреплённые — всегда, остальные —
        // по свежести использования, пока влезают в бюджет. Почему так: словарь
        // вырастет за лимит промпта, а «релевантность» мы мерить не умеем и не
        // пытаемся (никакого ML) — свежесть использования это дешёвый прокси
        // сигнала «об этом сейчас диктуют». Чем плохо: не знает контекста
        // текущего приложения (ТЗ 6.6 хочет это в будущем), при смене темы
        // разгоняется только после первых употреблений, а термины, которые
        // модель и так пишет верно, занимают бюджет наравне с проблемными.
        let pinned = terms.filter(\.pinned)
        let rest = terms.filter { !$0.pinned }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }

        var remaining = budget - pinned.reduce(0) { $0 + $1.canonical.count + 2 }
        var chosen: [Term] = []
        for term in rest {
            let cost = term.canonical.count + 2 // ", "
            guard remaining - cost >= 0 else { continue } // короткий термин дальше ещё может влезть
            chosen.append(term)
            remaining -= cost
        }

        // Whisper сильнее верит концу промпта — важное в конец: сначала
        // выбранные по свежести (самые свежие ближе к концу), потом закреплённые.
        let ordered = Array(chosen.reversed()) + pinned
        guard !ordered.isEmpty else { return nil }

        // Голый список без несущей фразы. ТЗ 6.6 предлагало обрамить термины
        // естественным контекстом («связный предыдущий транскрипт»), но замер
        // показал цену: «Словарь терминов: » — это ещё 6-7 токенов, то есть
        // ~150 мс на каждой фразе за оформление, которое модели ничего не даёт.
        // Список через запятую Whisper понимает как перечисление и так.
        let text = ordered.map(\.canonical).joined(separator: ", ")
        return Prompt(text: text, termCount: ordered.count)
    }
}
