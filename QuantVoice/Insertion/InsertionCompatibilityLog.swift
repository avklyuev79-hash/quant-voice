//
//  InsertionCompatibilityLog.swift
//  Quant Voice
//
//  Статистика «приложение → какой уровень каскада сработал». Питает прогон
//  ручного чек-листа совместимости из ТЗ 9.4: продиктовал в каждое приложение —
//  экспортировал отчёт — приложил к приёмке вехи M3.
//
//  ⚠️ Приватность (ТЗ 7.4): хранится только bundle id, имя приложения, метод,
//  счётчики и даты. Вставляемый текст сюда не попадает никогда.
//

import Foundation

@MainActor
public final class InsertionCompatibilityLog {

    // MARK: Модель

    /// Накопленная статистика по одному приложению.
    public struct Entry: Codable, Sendable {
        public var appName: String?
        /// InsertionMethod.rawValue → количество срабатываний.
        public var counts: [String: Int]
        public var lastMethodRaw: String
        public var lastDate: Date

        public var total: Int { counts.values.reduce(0, +) }
    }

    /// bundle id (или "(unknown)") → статистика.
    public private(set) var entries: [String: Entry] = [:]

    private let logger: Logging?
    private let storageURL: URL?

    private static let unknownKey = "(unknown)"

    /// Чек-лист из ТЗ 9.4 с известными bundle id. У Telegram их два —
    /// версия из Mac App Store и «Telegram Desktop» с сайта.
    private static let checklist: [(name: String, bundleIDs: [String])] = [
        ("Safari",    ["com.apple.Safari"]),
        ("Chrome",    ["com.google.Chrome"]),
        ("Mail",      ["com.apple.mail"]),
        ("Notes",     ["com.apple.Notes"]),
        ("Telegram",  ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        ("Slack",     ["com.tinyspeck.slackmacgap"]),
        ("VS Code",   ["com.microsoft.VSCode"]),
        ("Xcode",     ["com.apple.dt.Xcode"]),
        ("Pages",     ["com.apple.iWork.Pages"]),
        ("Numbers",   ["com.apple.iWork.Numbers"]),
        ("Obsidian",  ["md.obsidian"]),
        ("Spotlight", ["com.apple.Spotlight"]),
        ("Терминал",  ["com.apple.Terminal"]),
    ]

    // MARK: Инициализация

    /// - Parameter storageURL: куда сохранять JSON. nil — стандартное место
    ///   в Application Support. Явный URL нужен тестам.
    public init(logger: Logging? = nil, storageURL: URL? = nil) {
        self.logger = logger
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    private static func defaultStorageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("QuantVoice", isDirectory: true)
            .appendingPathComponent("insertion-compatibility.json")
    }

    // MARK: Запись

    public func record(app: FocusedAppInfo?, method: InsertionMethod, date: Date = Date()) {
        let key = app?.bundleID ?? Self.unknownKey
        var entry = entries[key] ?? Entry(appName: app?.name,
                                          counts: [:],
                                          lastMethodRaw: method.rawValue,
                                          lastDate: date)
        entry.counts[method.rawValue, default: 0] += 1
        entry.lastMethodRaw = method.rawValue
        entry.lastDate = date
        if entry.appName == nil { entry.appName = app?.name }
        entries[key] = entry

        // Пишем сразу: одна вставка — одна запись, это единицы раз в минуту.
        // Потерять статистику при внезапном завершении обиднее, чем сэкономить
        // одну запись маленького JSON.
        persist()
    }

    /// Стереть накопленное (кнопка в настройках перед прогоном чек-листа).
    public func reset() {
        entries = [:]
        guard let url = storageURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Экспорт

    /// Человекочитаемый отчёт для приёмки вехи: чек-лист ТЗ 9.4 с покрытием,
    /// затем все прочие приложения.
    public func exportReport(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")

        var lines: [String] = []
        lines.append("Совместимость вставки — чек-лист ТЗ 9.4")
        lines.append("Сформировано: \(formatter.string(from: now))")
        lines.append("")

        var covered = 0
        var checklistIDs = Set<String>()

        for item in Self.checklist {
            checklistIDs.formUnion(item.bundleIDs)
            // Приложение чек-листа могло встретиться под любым из известных id.
            var found: (bundleID: String, entry: Entry)?
            for bundleID in item.bundleIDs {
                if let entry = entries[bundleID] {
                    found = (bundleID, entry)
                    break
                }
            }
            if let (bundleID, entry) = found {
                covered += 1
                lines.append("[x] \(item.name) (\(bundleID)) — \(Self.describe(entry, formatter: formatter))")
            } else {
                lines.append("[ ] \(item.name) — нет данных")
            }
        }
        lines.append("")
        lines.append("Покрыто: \(covered) из \(Self.checklist.count).")

        let others = entries
            .filter { !checklistIDs.contains($0.key) }
            .sorted { $0.value.lastDate > $1.value.lastDate }
        if !others.isEmpty {
            lines.append("")
            lines.append("Прочие приложения:")
            for (bundleID, entry) in others {
                let title = entry.appName.map { "\($0) (\(bundleID))" } ?? bundleID
                lines.append("    \(title) — \(Self.describe(entry, formatter: formatter))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ entry: Entry, formatter: DateFormatter) -> String {
        // Порядок уровней каскада — как в ТЗ 5.6, для единообразия отчёта.
        let order: [InsertionMethod] = [.accessibility, .paste, .clipboardOnly]
        let breakdown = order
            .compactMap { method -> String? in
                guard let count = entry.counts[method.rawValue], count > 0 else { return nil }
                return "\(method.rawValue) ×\(count)"
            }
            .joined(separator: ", ")
        return "\(breakdown) · последний: \(entry.lastMethodRaw), \(formatter.string(from: entry.lastDate))"
    }

    // MARK: Персистентность

    private func load() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([String: Entry].self, from: data)
        } catch {
            // Битый файл не повод падать: статистика вспомогательная,
            // начинаем с чистого листа.
            logger?.warning("Лог совместимости повреждён, начинаем заново: \(error.localizedDescription)")
            entries = [:]
        }
    }

    private func persist() {
        guard let url = storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logger?.warning("Не удалось сохранить лог совместимости: \(error.localizedDescription)")
        }
    }
}
