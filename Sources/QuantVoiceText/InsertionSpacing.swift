//
//  InsertionSpacing.swift
//  QuantVoiceText
//
//  Разделитель между двумя вставками подряд.
//
//  Повод — живая диктовка 20.07.2026: Алексей надиктовал три фразы одну
//  за другой, и они склеились встык — «…распознается.Специально говорю…».
//  Каждая фраза сама по себе причёсана правильно, точка на месте, но между
//  вставками пробела нет, потому что вставка не знает, что было до неё.
//
//  Почему не через AX. Прочитать символ слева от каретки правильнее, но
//  на живой машине AX-путь в целевом приложении не работает вовсе
//  (в логе — «.success, но ни каретка, ни длина не изменились»), и вставка
//  идёт через ⌘V вслепую. Значит контекст приходится помнить самим.
//
//  Эвристика, и она может ошибиться: если между фразами пользователь сам
//  переставил курсор, лишний пробел окажется не на месте. Цена ошибки —
//  один пробел, цена бездействия — склеенный текст на каждой второй фразе,
//  поэтому размен принят. Условия сужены до предсказуемых: то же
//  приложение, короткий промежуток, и явные признаки того, что разделитель
//  уже есть.
//

import Foundation

public enum InsertionSpacing {

    /// Что известно о предыдущей вставке.
    public struct Previous: Equatable, Sendable {
        public let text: String
        /// Bundle ID приложения, куда вставляли.
        public let application: String?
        public let at: Date

        public init(text: String, application: String?, at: Date) {
            self.text = text
            self.application = application
            self.at = at
        }
    }

    /// За сколько предыдущая вставка «протухает». Минута — это уже не
    /// диктовка подряд, а новая мысль в неизвестно каком месте документа.
    public static let staleAfter: TimeInterval = 60

    /// Пробел, который нужно добавить перед новым текстом. Пустая строка —
    /// добавлять ничего не надо.
    public static func separator(for text: String,
                                 previous: Previous?,
                                 application: String?,
                                 now: Date = Date()) -> String {
        guard let previous else { return "" }
        // Другое приложение — мы не знаем, что там в поле.
        guard previous.application == application else { return "" }
        guard now.timeIntervalSince(previous.at) <= staleAfter else { return "" }

        // Разделитель уже есть с одной из сторон.
        guard let tail = previous.text.last, !tail.isWhitespace else { return "" }
        guard let head = text.first, !head.isWhitespace else { return "" }

        // Новая фраза начинается со знака препинания или закрывающей скобки —
        // пробел перед ними в русском не ставится.
        if ",.!?;:%…)»".contains(head) { return "" }
        // Предыдущая закончилась открывающей скобкой или кавычкой —
        // внутрь них пробел тоже не нужен.
        if "(«".contains(tail) { return "" }

        return " "
    }
}
