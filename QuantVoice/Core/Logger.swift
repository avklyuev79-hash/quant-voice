//
//  Logger.swift
//  Quant Voice
//
//  Файловый логгер — реализация протокола Logging из Contracts.swift.
//
//  ⚠️ ПРИВАТНОСТЬ (ТЗ 7.4, проверяется тестом):
//  в лог НИКОГДА не передаётся распознанный текст, содержимое буфера обмена
//  или аудиоданные. Сюда пишут только служебные сообщения: события, тайминги,
//  имена движков, коды языков, тексты ошибок. Если какой-то вызов передаёт
//  в message текст пользователя — это ошибка использования логгера, и её
//  поймает приватность-тест (поиск известной надиктованной фразы по логам).
//

import Foundation

/// Уровень записи. Порядок случаев важен — фильтрация сравнивает rawValue.
enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO "
        case .warning: return "WARN "
        case .error:   return "ERROR"
        }
    }
}

/// Пишет в `~/Library/Logs/QuantVoice/QuantVoice.log` с ротацией по размеру.
///
/// Потокобезопасность: всё изменяемое состояние (дескриптор файла, счётчик
/// размера, форматтер даты) трогается только на последовательной очереди
/// `queue`, поэтому `@unchecked Sendable` здесь честный — протокол `Logging`
/// требует Sendable, а актор не подошёл бы: методы протокола синхронные.
/// Синхронный вызов лишь ставит запись в очередь и не блокирует вызывающего.
final class FileLogger: Logging, @unchecked Sendable {

    /// Папка логов. Публична, чтобы пункт меню «Открыть логи» вёл сюда же,
    /// а не в собственную копию пути.
    static let logsDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QuantVoice", isDirectory: true)

    /// Порог ротации. 2 МБ текста — недели работы; больше держать незачем,
    /// ТЗ 7.4 требует принудительно ограничивать размер.
    private static let maxFileSize: UInt64 = 2 * 1024 * 1024

    private let fileURL: URL
    private let rotatedURL: URL
    private let minimumLevel: LogLevel
    private let queue = DispatchQueue(label: "com.quant.voice.logger", qos: .utility)

    // Всё ниже — только на `queue`.
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private let timestampFormatter: DateFormatter

    init(minimumLevel: LogLevel? = nil) {
        self.fileURL = Self.logsDirectory.appendingPathComponent("QuantVoice.log")
        self.rotatedURL = Self.logsDirectory.appendingPathComponent("QuantVoice.1.log")

        // В отладочной сборке пишем всё — там и живут замеры латентности;
        // в релизе по умолчанию от info, чтобы лог не разбухал.
        #if DEBUG
        self.minimumLevel = minimumLevel ?? .debug
        #else
        self.minimumLevel = minimumLevel ?? .info
        #endif

        // DateFormatter не потокобезопасен, но используется только на `queue`.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.timestampFormatter = formatter
    }

    deinit {
        // Дожидаемся хвоста очереди, чтобы не потерять последние строки при выходе.
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - Logging

    func debug(_ message: String)   { write(.debug, message) }
    func info(_ message: String)    { write(.info, message) }
    func warning(_ message: String) { write(.warning, message) }
    func error(_ message: String)   { write(.error, message) }

    // MARK: - Запись

    private func write(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        // Дату фиксируем в момент вызова, а не в момент исполнения на очереди —
        // иначе под нагрузкой тайминги в логе «поплывут».
        let timestamp = Date()
        queue.async { [self] in
            let line = "\(timestampFormatter.string(from: timestamp)) [\(level.label)] \(message)\n"
            append(line)
            #if DEBUG
            // Дублируем в консоль Xcode, чтобы при отладке не лазить в файл.
            print(line, terminator: "")
            #endif
        }
    }

    /// Только на `queue`.
    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        openIfNeeded()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentSize += UInt64(data.count)
            if currentSize > Self.maxFileSize {
                rotate()
            }
        } catch {
            // Некуда логировать ошибку логгера; закрываем дескриптор,
            // следующая запись попробует открыть файл заново.
            try? handle.close()
            self.handle = nil
        }
    }

    /// Только на `queue`.
    private func openIfNeeded() {
        guard handle == nil else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.logsDirectory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let newHandle = try FileHandle(forWritingTo: fileURL)
            currentSize = try newHandle.seekToEnd()
            handle = newHandle
        } catch {
            handle = nil
        }
    }

    /// Только на `queue`. Ротация: текущий файл становится `.1.log`
    /// (прошлый `.1.log` удаляется), пишем в свежий. Итого на диске
    /// не больше ~двух порогов — размер ограничен принудительно.
    private func rotate() {
        try? handle?.close()
        handle = nil
        currentSize = 0
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        // Новый файл откроется лениво при следующей записи.
    }
}
