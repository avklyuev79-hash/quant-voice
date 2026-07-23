//
//  PlainTextRefiner.swift
//  QuantVoiceText
//
//  Детерминированный уровень постобработки (ТЗ 5.7, уровень 3) — тот, что
//  работает всегда: без сети, без модели, без установки чего-либо.
//
//  Повод из живой диктовки 20.07.2026: текст распознаётся чисто, но модель
//  не ставит точку в конце фразы и не всегда даёт заглавную после точки.
//  Это ровно та работа, для которой LLM избыточна — правила короткие
//  и проверяемые.
//
//  Чего здесь СОЗНАТЕЛЬНО нет: расстановки запятых. Запятая в русском
//  зависит от структуры предложения, а не от пауз, и всякая попытка
//  угадать её правилами кончается расстановкой запятых там, где их быть
//  не должно. Это работа для уровней 1-2 каскада (Foundation Models,
//  Ollama), которые видят смысл фразы.
//
//  Жёсткое правило ТЗ 5.7 — постобработка НИКОГДА не ломает диктовку.
//  Здесь оно соблюдается по построению: все операции обратимы по смыслу
//  и не могут потерять слово. Пустой или пробельный текст возвращается
//  как есть.
//

import Foundation

public struct RefinementOptions: Equatable, Sendable {
    /// Схлопнуть кратные пробелы, убрать пробел перед знаком препинания
    /// и добавить после него.
    public var tidyWhitespace: Bool
    /// Заглавная буква в начале текста и после точки, «!», «?».
    public var capitalizeSentences: Bool
    /// Точка в конце, если фраза кончилась словом.
    public var ensureTrailingPunctuation: Bool
    /// Убрать звуковые филлеры («эээ», «ммм»).
    public var stripFillers: Bool

    public init(tidyWhitespace: Bool = true,
                capitalizeSentences: Bool = true,
                ensureTrailingPunctuation: Bool = true,
                stripFillers: Bool = true) {
        self.tidyWhitespace = tidyWhitespace
        self.capitalizeSentences = capitalizeSentences
        self.ensureTrailingPunctuation = ensureTrailingPunctuation
        self.stripFillers = stripFillers
    }

    public static let `default` = RefinementOptions()
    /// Ничего не трогать — режим «сырой» из пресетов ТЗ 5.7.
    public static let raw = RefinementOptions(tidyWhitespace: false,
                                              capitalizeSentences: false,
                                              ensureTrailingPunctuation: false,
                                              stripFillers: false)
}

public enum PlainTextRefiner {

    public static func refine(_ text: String,
                              options: RefinementOptions = .default) -> String {
        // Пустой или пробельный текст — не наша забота, отдаём как есть.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        var out = text
        if options.stripFillers { out = removingFillers(out) }
        if options.tidyWhitespace { out = tidyingWhitespace(out) }
        if options.capitalizeSentences { out = capitalizingSentences(out) }
        if options.ensureTrailingPunctuation { out = addingTrailingPeriod(out) }

        // Страховка на случай, если правила съели всё: лучше сырой текст,
        // чем пустое поле (ТЗ 5.7).
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : out
    }

    // MARK: - Филлеры

    /// Только ЗВУКОВЫЕ филлеры: «эээ», «ммм», «э-э». Слова-паразиты вроде
    /// «как бы» и «ну вот» не трогаем — они бывают осмысленной частью фразы
    /// («ну вот и всё»), и вычищать их правилами значит менять сказанное.
    private static func removingFillers(_ text: String) -> String {
        // Пробел после филлера съедается вместе с ним — иначе на месте
        // выброшенного «эээ» останется дыра в начале фразы.
        let pattern = "(?i)(?<![\\p{L}\\p{N}])(?:э{2,}|м{2,}|э-э|м-м|а{3,})(?![\\p{L}\\p{N}])[,]?[ \\t]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Пробелы и знаки

    private static func tidyingWhitespace(_ text: String) -> String {
        var s = text

        // Дубли знаков, которые модель иногда выдаёт вместе с нашим же
        // добавлением: «..» → «.», «,,» → «,».
        s = s.replacingOccurrences(of: "([.,!?;:])\\1+", with: "$1",
                                   options: .regularExpression)
        // Пробел перед знаком препинания — убрать.
        s = s.replacingOccurrences(of: "[ \\t]+([.,!?;:%…])", with: "$1",
                                   options: .regularExpression)
        // Пробел после знака, если дальше буква или цифра.
        s = s.replacingOccurrences(of: "([.,!?;:])(?=[\\p{L}\\p{N}])", with: "$1 ",
                                   options: .regularExpression)
        // Кавычки-ёлочки и скобки: пробел внутрь не пускаем.
        s = s.replacingOccurrences(of: "«[ \\t]+", with: "«", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+»", with: "»", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\([ \\t]+", with: "(", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+\\)", with: ")", options: .regularExpression)
        // Кратные пробелы. Переводы строк не трогаем: если пользователь
        // надиктовал абзац, структура его.
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        // Пробелы по краям строк.
        s = s.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n[ \\t]+", with: "\n", options: .regularExpression)

        return s
    }

    // MARK: - Регистр

    /// Заглавная в начале текста и после «.», «!», «?», «…».
    ///
    /// Слова, начинающиеся со строчной НЕ после точки, не трогаем: там может
    /// быть термин («macOS», «iPhone»), и «исправление» его сломает.
    private static func capitalizingSentences(_ text: String) -> String {
        var result = ""
        // Начало текста — тоже граница предложения.
        var atSentenceStart = true
        var pendingBoundary = false

        for ch in text {
            if atSentenceStart, ch.isLetter {
                result.append(contentsOf: String(ch).uppercased())
                atSentenceStart = false
                pendingBoundary = false
                continue
            }
            if ".!?…".contains(ch) {
                pendingBoundary = true
            } else if pendingBoundary, ch.isWhitespace {
                // Знак, потом пробел — дальше новое предложение.
                atSentenceStart = true
                pendingBoundary = false
            } else if !ch.isWhitespace {
                pendingBoundary = false
                atSentenceStart = false
            }
            result.append(ch)
        }
        return result
    }

    // MARK: - Точка в конце

    /// Точка в конце, если фраза кончилась словом или цифрой.
    ///
    /// Не ставим после «,», «:», «—» и открытой скобки: там фраза оборвана
    /// намеренно, и точка выглядела бы ошибкой. Уже стоящий знак («?», «!»,
    /// «…») не трогаем.
    private static func addingTrailingPeriod(_ text: String) -> String {
        // Хвостовые пробелы и переводы строк сохраняем: вставка идёт
        // в чужое поле, и структура текста пользователя не наша.
        let trailingWhitespace = text.suffix(while: { $0.isWhitespace })
        let body = String(text.dropLast(trailingWhitespace.count))
        guard let last = body.last else { return text }
        guard last.isLetter || last.isNumber || last == ")" || last == "»" else { return text }
        return body + "." + trailingWhitespace
    }
}

private extension String {
    /// Хвост строки, пока символы удовлетворяют условию.
    func suffix(while predicate: (Character) -> Bool) -> String {
        var out = ""
        for ch in reversed() {
            guard predicate(ch) else { break }
            out.insert(ch, at: out.startIndex)
        }
        return out
    }
}
