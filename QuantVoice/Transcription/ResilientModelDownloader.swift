//
//  ResilientModelDownloader.swift
//  Quant Voice
//
//  Загрузка модели, переживающая плохую сеть.
//
//  ⚠️ Это единственное место приложения, которое ходит в сеть (ТЗ 7.2).
//  Всё остальное работает офлайн — и после того, как модель скачана,
//  сеть не нужна вовсе.
//
//  Почему не `WhisperKit.download`. Штатный загрузчик исправен, пока
//  исправна сеть. У нашего пользователя она не исправна: huggingface.co
//  из России режется провайдерами, соединение рвётся посреди файла,
//  а самый большой артефакт весит больше 400 МБ — скачивать его заново
//  после каждого обрыва невозможно. Скрипт `scripts/fetch-model.sh` эту
//  задачу решил год назад (докачка с места обрыва, пропуск готовых файлов,
//  повторы), но требовал терминала. Здесь та же логика, только внутри
//  приложения: приёмка M8 — «человек доходит до первой диктовки,
//  не открывая терминал».
//
//  Три вещи, которые делают загрузку живучей:
//    1. Докачка по HTTP Range — обрыв стоит остатка файла, а не всего файла.
//    2. Пропуск готовых файлов по размеру — повторный запуск продолжает
//       с места остановки, а не начинает сначала.
//    3. Перебор источников — если основной хост недоступен, берём зеркало.
//

import Foundation
import QuantVoiceModels

actor ResilientModelDownloader {

    /// Сколько раз пытаемся вытянуть один файл, прежде чем сменить источник.
    private static let attemptsPerFile = 4
    /// Пауза между попытками.
    private static let retryDelay: Duration = .seconds(3)
    /// Размер куска при записи на диск. Файл в память целиком не читаем:
    /// артефакты бывают по 400+ МБ, а у машины Алексея всего 8 ГБ.
    private static let chunkSize = 256 * 1024

    private let logger: any Logging
    private let session: URLSession

    init(logger: any Logging) {
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        // Ждём ответа минуту: на плохой сети рукопожатие бывает долгим,
        // но «висит навсегда» — это худший из возможных исходов (мы уже
        // обожглись на зависшем запросе токенайзера).
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Загрузка модели

    /// Скачивает вариант модели и его токенайзер.
    ///
    /// - Parameters:
    ///   - variant: имя варианта в репозитории.
    ///   - modelsRoot: `<Application Support>/QuantVoice/models`.
    ///   - progress: доля 0…1, вызывается не на главном потоке.
    /// - Returns: папка установленной модели.
    func download(variant: String,
                  repository: String,
                  modelsRoot: URL,
                  progress: @Sendable @escaping (Double) -> Void) async throws -> URL {

        let destination = modelsRoot
            .appending(path: repository, directoryHint: .isDirectory)
            .appending(path: variant, directoryHint: .isDirectory)

        // 1. Список файлов и рабочий источник — одним шагом: источник,
        // который не отдал индекс, не отдаст и файлы.
        let (source, files) = try await resolveSource(repository: repository, variant: variant)
        let totalBytes = files.reduce(0) { $0 + $1.size }
        logger.info("Загрузка модели: источник «\(source.title)», файлов \(files.count), \(totalBytes / 1_048_576) МБ")

        // 2. Файлы модели.
        var completedBytes = 0
        var activeSource = source
        for file in files {
            let target = destination.appending(path: file.relativePath(strippingVariant: variant))
            // Снимок счётчика в константу: замыкание прогресса @Sendable
            // и убегает в делегат URLSession, изменяемую переменную ему
            // захватывать нельзя. За время одного файла база всё равно
            // не меняется — она растёт только между файлами.
            let alreadyDone = completedBytes
            let fetched = try await fetch(file: file,
                                          repository: repository,
                                          to: target,
                                          source: &activeSource) { bytesInFile in
                progress(Double(alreadyDone + bytesInFile) / Double(max(totalBytes, 1)))
            }
            completedBytes += fetched
            progress(Double(completedBytes) / Double(max(totalBytes, 1)))
        }

        // 3. Токенайзер — отдельная сущность, и без него модель бесполезна.
        // Подробности грабли — в комментарии к ModelDownloadPlan.
        try await downloadTokenizer(forVariant: variant,
                                    modelsRoot: modelsRoot,
                                    source: &activeSource)

        logger.info("Загрузка модели: «\(variant)» скачана целиком")
        return destination
    }

    // MARK: - Источник

    /// Первый источник, который отдал список файлов.
    private func resolveSource(repository: String,
                               variant: String) async throws -> (ModelSource, [ModelFile]) {
        var lastError: (any Error)?
        for source in ModelSource.all {
            guard let url = source.treeURL(repository: repository, variant: variant) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                try Self.check(response, url: url)
                return (source, try ModelDownloadPlan.parseTree(data))
            } catch {
                logger.warning("Загрузка модели: источник «\(source.title)» недоступен (\(error.localizedDescription)), пробую следующий")
                lastError = error
            }
        }
        throw ModelDownloadError.allSourcesUnavailable(underlying: lastError?.localizedDescription)
    }

    // MARK: - Один файл

    /// Возвращает, сколько байт у файла итоговый размер (для общего прогресса).
    private func fetch(file: ModelFile,
                       repository: String,
                       to target: URL,
                       source: inout ModelSource,
                       progress: @Sendable @escaping (Int) -> Void) async throws -> Int {

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        var remainingSources = ModelSource.all.drop { $0 != source }
        var lastError: (any Error)?

        while let current = remainingSources.first {
            for attempt in 1...Self.attemptsPerFile {
                do {
                    let existing = Self.sizeOnDisk(target)
                    switch ModelDownloadPlan.action(expected: file.size, existing: existing) {
                    case .skip:
                        return file.size
                    case .resume(let offset):
                        try await stream(file: file, repository: repository, to: target,
                                         source: current, from: offset, progress: progress)
                    case .downloadFromScratch:
                        try? FileManager.default.removeItem(at: target)
                        try await stream(file: file, repository: repository, to: target,
                                         source: current, from: nil, progress: progress)
                    }
                    source = current
                    return file.size
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    logger.warning("Загрузка модели: обрыв на «\(file.relativePath(strippingVariant: ""))», попытка \(attempt) из \(Self.attemptsPerFile)")
                    if attempt < Self.attemptsPerFile {
                        try await Task.sleep(for: Self.retryDelay)
                    }
                }
            }
            remainingSources = remainingSources.dropFirst()
            if let next = remainingSources.first {
                logger.warning("Загрузка модели: перехожу на «\(next.title)»")
            }
        }
        throw ModelDownloadError.fileFailed(path: file.path,
                                            underlying: lastError?.localizedDescription)
    }

    /// Скачивает файл (или его хвост) во временный файл и переносит на место.
    ///
    /// Почему `download`, а не `bytes(for:)`. Поток `URLSession.AsyncBytes`
    /// отдаёт по одному байту за итерацию, и на 400-мегабайтном артефакте это
    /// сотни миллионов итераций — загрузка упёрлась бы не в сеть, а в Swift.
    /// `download` пишет на диск сам, а прогресс отдаёт делегат.
    private func stream(file: ModelFile,
                        repository: String,
                        to target: URL,
                        source: ModelSource,
                        from offset: Int?,
                        progress: @Sendable @escaping (Int) -> Void) async throws {

        guard let url = source.fileURL(repository: repository, path: file.path) else {
            throw ModelDownloadError.badURL
        }
        var request = URLRequest(url: url)
        if let offset {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let observer = DownloadProgressObserver(alreadyOnDisk: offset ?? 0, report: progress)
        let (temporary, response) = try await session.download(for: request, delegate: observer)
        try Self.check(response, url: url)
        try Task.checkCancellation()

        // 206 — сервер согласился отдать хвост. 200 на запрос с Range означает,
        // что докачка не поддержана и пришёл файл целиком: тогда пишем с нуля,
        // иначе получили бы склейку двух копий — молчаливо битый файл.
        let appending = (offset != nil) && ((response as? HTTPURLResponse)?.statusCode == 206)

        if appending, FileManager.default.fileExists(atPath: target.path) {
            try Self.append(contentsOf: temporary, to: target, chunkSize: Self.chunkSize)
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    /// Дописывание хвоста кусками: файл в память целиком не читаем —
    /// у машины Алексея 8 ГБ, а артефакты бывают по 400+ МБ.
    private static func append(contentsOf source: URL, to target: URL, chunkSize: Int) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        try writer.seekToEnd()
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
    }

    // MARK: - Токенайзер

    private func downloadTokenizer(forVariant variant: String,
                                   modelsRoot: URL,
                                   source: inout ModelSource) async throws {
        let repository = ModelDownloadPlan.tokenizerRepository(forVariant: variant)
        let folder = modelsRoot.appending(path: repository, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logger.info("Загрузка модели: токенайзер «\(repository)»")

        for name in ModelDownloadPlan.tokenizerFiles {
            let target = folder.appending(path: name)
            if let size = Self.sizeOnDisk(target), size > 0 { continue }
            guard let url = source.fileURL(repository: repository, path: name) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                try Self.check(response, url: url)
                try data.write(to: target, options: .atomic)
            } catch {
                // Часть артефактов есть не у всех вариантов — это нормально.
                // Обязателен только tokenizer.json, его проверяем ниже.
                try? FileManager.default.removeItem(at: target)
            }
        }

        let required = folder.appending(path: ModelDownloadPlan.requiredTokenizerFile)
        guard let size = Self.sizeOnDisk(required), size > 0 else {
            throw ModelDownloadError.tokenizerMissing
        }
    }

    // MARK: - Служебное

    private static func sizeOnDisk(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    private static func check(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw ModelDownloadError.httpError(code: http.statusCode)
        }
    }
}

// MARK: - Прогресс загрузки

/// Делегат одной задачи загрузки. Существует только ради колбэка прогресса:
/// `URLSession.download` иначе молчит до самого конца, а самый большой
/// артефакт качается минутами — пользователь должен видеть, что процесс идёт.
///
/// @unchecked Sendable: единственное изменяемое поле — счётчик, который
/// трогает только очередь делегата URLSession, по одной задаче за раз.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Сколько байт этого файла уже лежало на диске до докачки.
    private let alreadyOnDisk: Int
    private let report: @Sendable (Int) -> Void

    init(alreadyOnDisk: Int, report: @escaping @Sendable (Int) -> Void) {
        self.alreadyOnDisk = alreadyOnDisk
        self.report = report
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report(alreadyOnDisk + Int(totalBytesWritten))
    }

    /// Обязателен по протоколу, но файл забирает `download(for:delegate:)` —
    /// здесь делать нечего.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

// MARK: - Ошибки

enum ModelDownloadError: LocalizedError {
    case allSourcesUnavailable(underlying: String?)
    case fileFailed(path: String, underlying: String?)
    case tokenizerMissing
    case httpError(code: Int)
    case badURL

    var errorDescription: String? {
        switch self {
        case .allSourcesUnavailable:
            return "Не удалось соединиться ни с одним источником моделей. Похоже, провайдер режет доступ — попробуй включить VPN и повторить."
        case .fileFailed(let path, _):
            return "Не удалось скачать файл модели (\(path)) даже после нескольких попыток. Уже скачанное сохранено — повторный запуск продолжит с этого места."
        case .tokenizerMissing:
            return "Модель скачалась, но без словаря токенов — без него распознавание зависнет. Повтори загрузку."
        case .httpError(let code):
            return "Сервер ответил ошибкой \(code)"
        case .badURL:
            return "Некорректный адрес загрузки"
        }
    }
}
