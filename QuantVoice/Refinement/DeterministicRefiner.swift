//
//  DeterministicRefiner.swift
//  Quant Voice
//
//  Третий уровень каскада постобработки (ТЗ 5.7) — тот, что работает всегда.
//  Оболочка над `PlainTextRefiner` из библиотеки `QuantVoiceText`: сами
//  правила лежат там и покрыты тестами, здесь только подключение к контракту.
//
//  Первые два уровня каскада (Apple Foundation Models, Ollama на loopback)
//  появятся позже и встанут перед этим. На машине Алексея Apple Intelligence
//  выключен, Ollama не установлена, поэтому пока каскад состоит из одного
//  уровня — и это честно отражено в `displayName`.
//

import Foundation
import QuantVoiceText

/// Причёсывание без сети и без модели: пунктуация, регистр, пробелы.
final class DeterministicRefiner: TextRefining {

    let displayName = "Базовое причёсывание"

    /// Доступен всегда — в этом весь смысл уровня.
    var isAvailable: Bool { get async { true } }

    private let logger: any Logging

    init(logger: any Logging) {
        self.logger = logger
    }

    func refine(_ text: String, language: RecognitionLanguage) async -> String {
        // Выключатель читается на каждой фразе, а не в init: пользователь
        // меняет его в настройках, и перезапуск ради этого — плохой ответ.
        guard Preferences.textRefinementEnabled() else { return text }

        let refined = PlainTextRefiner.refine(text)

        // Жёсткое правило ТЗ 5.7: постобработка не ломает диктовку. Правила
        // детерминированные и слово потерять не могут, но проверка стоит
        // ноль, а страхует от опечатки в регулярном выражении.
        guard !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Причёсывание: результат пуст — отдаю сырой текст")
            return text
        }
        return refined
    }
}
