//
//  Term.swift
//  Quant Voice
//
//  Термин словаря (ТЗ 6.6) и формат файла terms.json.
//
//  Файл живёт в ~/Library/Application Support/QuantVoice/terms.json,
//  переживает обновление приложения и правится руками. Поэтому формат
//  снисходительный: обязательно только `canonical`, всё остальное можно
//  опустить — рукописная запись `{"canonical": "SilkSmile"}` валидна.
//

import Foundation

/// Один термин словаря.
public struct Term: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// Каноническое написание — то, что должно оказаться в тексте: «Claude Cowork».
    public var canonical: String
    /// Язык термина ("ru"/"en"). Пока только метаданные — задел под будущие
    /// правила отбора; из промпта термины по языку сознательно НЕ фильтруются:
    /// английские бренды в русской речи — главный сценарий слоя.
    public var language: String?
    /// Известные варианты произношения и ослышки: «клоут коворг», «клод коворк».
    public var variants: [String]
    /// Закреплённый термин всегда попадает в промпт, независимо от свежести.
    public var pinned: Bool
    /// Когда термин последний раз встретился в диктовке — топливо отбора в промпт.
    public var lastUsedAt: Date?
    /// Разрешено ли нечёткое (фонетическое) сопоставление для этого термина.
    /// true — ловим и незаписанные ослышки по звуку (для пользовательских
    /// терминов: их немного, и человек сам объявил их важными). false —
    /// только точное совпадение и падежные основы по явным вариантам.
    ///
    /// Встроенный словарь идёт с fuzzy=false: у него сотни записей с уже
    /// прописанными кириллическими вариантами, а фонетика на такой массе
    /// начинает воровать обычные слова, близкие по звуку к бренду
    /// («через» → «Chery»), полагаясь лишь на орфографический фильтр. Явных
    /// вариантов достаточно, а незакрытые ослышки добираются по реальным
    /// промахам, а не гаданием.
    public var fuzzy: Bool

    public init(id: UUID = UUID(),
         canonical: String,
         language: String? = nil,
         variants: [String] = [],
         pinned: Bool = false,
         lastUsedAt: Date? = nil,
         fuzzy: Bool = true) {
        self.id = id
        self.canonical = canonical
        self.language = language
        self.variants = variants
        self.pinned = pinned
        self.lastUsedAt = lastUsedAt
        self.fuzzy = fuzzy
    }

    private enum CodingKeys: String, CodingKey {
        case id, canonical, language, variants, pinned, lastUsedAt, fuzzy
    }

    // Снисходительное чтение: рукописной записи достаточно одного canonical.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonical = try container.decode(String.self, forKey: .canonical)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        language = try container.decodeIfPresent(String.self, forKey: .language)
        variants = try container.decodeIfPresent([String].self, forKey: .variants) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        fuzzy = try container.decodeIfPresent(Bool.self, forKey: .fuzzy) ?? true
    }

    // Пустые/дефолтные поля не пишем — файл читает человек, шум ему мешает.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonical, forKey: .canonical)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(language, forKey: .language)
        if !variants.isEmpty { try container.encode(variants, forKey: .variants) }
        if pinned { try container.encode(pinned, forKey: .pinned) }
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        if !fuzzy { try container.encode(fuzzy, forKey: .fuzzy) }
    }
}

/// Корень terms.json. `version` — на случай будущей миграции формата.
public struct TermsFile: Codable, Sendable {
    public var version: Int
    public var terms: [Term]

    public init(version: Int = 1, terms: [Term]) {
        self.version = version
        self.terms = terms
    }

    private enum CodingKeys: String, CodingKey { case version, terms }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        terms = try container.decodeIfPresent([Term].self, forKey: .terms) ?? []
    }
}

public extension Term {
    /// Стартовый словарь для первого запуска — термины из живой работы Алексея.
    /// Варианты — реальные ослышки первого живого теста («клоут коворг»)
    /// плюс предсказуемые транслитерации. Короткие аббревиатуры (ИП, ТЗ)
    /// ловятся только точным совпадением — фонетика на двух буквах опасна.
    ///
    /// Падежные формы сюда НЕ добавляются: «Клоуда», «Клоутку», «в Кванте»
    /// снимает Morphology. Раньше их приходилось вписывать руками, список
    /// не имел конца, и каждая форма ещё и занимала место в промпте.
    static let seed: [Term] = [
        Term(canonical: "Quant", language: "en", variants: ["квант"], pinned: true),
        // Составные термины идут отдельными записями и выигрывают у одиночных
        // (длинные шаблоны сопоставляются первыми). Без них вариант «cloud»
        // у Claude превратил бы «Claude Code» в «Claude Claude».
        Term(canonical: "Claude Code", language: "en",
             variants: ["клод код", "клоут код", "cloud code", "клауд код"]),
        Term(canonical: "Claude Cowork", language: "en",
             variants: ["клоут коворг", "клод коворк", "cloud cowork"]),
        // «cloud» — не ослышка, а корректное английское слово, и потому
        // орфографический фильтр его защищает. Ловится только явным вариантом:
        // на диктовке 20.07.2026 модель писала «Cloud» вместо «Claude»
        // раз за разом. Цена решения принята сознательно — слово «облако»
        // латиницей в тексте Алексея тоже станет «Claude».
        Term(canonical: "Claude", language: "en",
             variants: ["клод", "клоуд", "клоут", "клауд", "клаудэ", "cloud"], pinned: true),
        Term(canonical: "Cowork", language: "en",
             variants: ["коворк", "коворг", "ковок", "ковёрк", "ковэрк"], pinned: true),
        Term(canonical: "Anthropic", language: "en", variants: ["антропик", "энтропик"]),
        Term(canonical: "WhisperKit", language: "en", variants: ["висперкит", "виспер кит", "уиспер кит"]),
        Term(canonical: "macOS", language: "en", variants: ["макос", "мак ос", "мак оэс"]),
        Term(canonical: "GitHub", language: "en", variants: ["гитхаб", "гит хаб"]),
        Term(canonical: "Telegram", language: "en", variants: ["телеграм", "телеграмм"]),
        Term(canonical: "Яндекс.Директ", language: "ru", variants: ["яндекс директ", "яндекс-директ"]),
        Term(canonical: "ИП", language: "ru"),
        Term(canonical: "ТЗ", language: "ru", variants: ["тэзэ", "тезе"]),
    ]
}
