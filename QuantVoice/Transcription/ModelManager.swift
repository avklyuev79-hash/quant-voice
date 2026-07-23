//
//  ModelManager.swift
//  Quant Voice
//
//  Управление моделями Whisper: каталог, загрузка, целостность, ручная установка.
//
//  ⚠️ ПРИВАТНОСТЬ (ТЗ 7.2): сеть используется ТОЛЬКО в этом файле и только
//  внутри `download(_:progress:)`, который вызывается по явному действию
//  пользователя. Больше никакой сетевой код в приложении не живёт.
//  Это проверяется тестом 9.3 (сетевой монитор).
//

import Foundation
import WhisperKit

// MARK: - Профили моделей

/// Профиль качества/скорости из ТЗ 5.2. Ключ каталога моделей.
/// Живёт здесь (а не в движке), потому что каталог — источник правды о том,
/// какой профиль каким файлом на диске обеспечивается.
public enum WhisperModelProfile: String, Codable, Sendable, CaseIterable {
    /// Слабое железо, максимум скорости.
    case fast
    /// Основной сценарий (по умолчанию): large-v3-turbo, сжатый до ~626 МБ.
    case standard
    /// Когда точность важнее лишних 200 мс.
    case accurate
}

// MARK: - Описание модели

/// Запись каталога: что можно установить, сколько это весит.
/// Размер показывается пользователю ДО начала загрузки (ТЗ 5.2) —
/// поэтому он зашит в каталог, а не запрашивается из сети
/// (запрос из сети до согласия пользователя нарушил бы ТЗ 7.2).
public struct WhisperModelDescriptor: Sendable, Identifiable, Equatable {
    /// Имя варианта в репозитории argmaxinc/whisperkit-coreml.
    /// Совпадает с именем папки модели на диске.
    public let variant: String
    public let profile: WhisperModelProfile
    /// Человекочитаемое имя для настроек.
    public let displayName: String
    /// Приблизительный размер загрузки в мегабайтах.
    /// У Argmax размер зашит в само имя варианта (…_626MB) — сверено с HF-репо.
    public let approximateSizeMB: Int
    /// Короткое пояснение для UI настроек.
    public let details: String

    public var id: String { variant }
}

// MARK: - Установленная модель

/// Что реально лежит на диске.
public struct InstalledWhisperModel: Sendable, Identifiable {
    public let variant: String
    public let folderURL: URL
    /// Фактический размер на диске в байтах.
    public let sizeOnDisk: Int64

    public var id: String { variant }
}

/// Результат проверки целостности.
public enum ModelIntegrity: Sendable, Equatable {
    case ok
    /// Каких обязательных артефактов не хватает.
    case incomplete(missing: [String])
}

public enum ModelManagerError: LocalizedError {
    case modelNotInstalled(String)
    case downloadedModelBroken(variant: String, missing: [String])
    case importSourceInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let variant):
            return "Модель «\(variant)» не установлена"
        case .downloadedModelBroken(let variant, let missing):
            return "Модель «\(variant)» загрузилась неполной, не хватает: \(missing.joined(separator: ", "))"
        case .importSourceInvalid(let path):
            return "Папка «\(path)» не похожа на модель WhisperKit"
        }
    }
}

// MARK: - Менеджер

/// Актор: все операции с каталогом моделей сериализованы, чтобы две
/// параллельные загрузки/удаления не растоптали друг друга.
public actor ModelManager {

    // MARK: Каталог

    /// Три профиля из ТЗ 5.2. Варианты и размеры сверены с
    /// huggingface.co/argmaxinc/whisperkit-coreml (июль 2026):
    /// - fast:     small, сжатый OD-MBP до 216 МБ — быстрый и всё ещё мультиязычный;
    /// - standard: large-v3-turbo (v20240930), сжатый до 626 МБ — рекомендация
    ///   самих Argmax «для максимальной мультиязычной точности», наш дефолт;
    /// - accurate: полный large-v3, сжатый до 947 МБ — когда важнее точность.
    public static let catalog: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(
            variant: "openai_whisper-small_216MB",
            profile: .fast,
            displayName: "Быстрый (small, 216 МБ)",
            approximateSizeMB: 216,
            details: "Максимальная скорость, чуть ниже точность. Для слабого железа."
        ),
        WhisperModelDescriptor(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            profile: .standard,
            displayName: "Обычный (large-v3-turbo, 626 МБ)",
            approximateSizeMB: 626,
            details: "Рекомендуемый баланс скорости и точности. Вариант по умолчанию."
        ),
        WhisperModelDescriptor(
            variant: "openai_whisper-large-v3_947MB",
            profile: .accurate,
            displayName: "Точный (large-v3, 947 МБ)",
            approximateSizeMB: 947,
            details: "Максимальная точность, медленнее обычного примерно на треть."
        ),
    ]

    public static func descriptor(for profile: WhisperModelProfile) -> WhisperModelDescriptor {
        // Каталог покрывает все профили — force unwrap здесь был бы честен,
        // но падение из-за опечатки в каталоге не стоит того. Дефолт — standard.
        catalog.first { $0.profile == profile } ?? catalog[1]
    }

    // MARK: Пути

    /// База для WhisperKit/Hub: `~/Library/Application Support/QuantVoice`.
    /// Hub-загрузчик кладёт файлы в `<база>/models/<репозиторий>/<вариант>`,
    /// поэтому итоговый путь моделей — ровно тот, что требует ТЗ:
    /// `~/Library/Application Support/QuantVoice/models/…`.
    /// `nonisolated let` — константа, движку не нужен `await`, чтобы её прочитать.
    public nonisolated let downloadBaseURL: URL

    /// Корень каталога моделей: `<база>/models`.
    public nonisolated let modelsRootURL: URL

    private let logger: any Logging

    /// Загрузчик, переживающий плохую сеть (докачка, пропуск готовых файлов,
    /// зеркала). Ленивый: создаётся при первой загрузке, а не при старте —
    /// у большинства запусков модель уже на диске и качать нечего.
    private lazy var downloader = ResilientModelDownloader(logger: logger)

    /// Обязательные артефакты CoreML-модели WhisperKit.
    /// Каждый существует либо как .mlmodelc (скомпилированный), либо как .mlpackage.
    private static let requiredArtifacts = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    public init(logger: any Logging) {
        self.logger = logger

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.downloadBaseURL = appSupport.appendingPathComponent("QuantVoice", isDirectory: true)
        self.modelsRootURL = downloadBaseURL.appendingPathComponent("models", isDirectory: true)

        // Создаём каталог заранее: пользователь должен иметь возможность
        // положить модель руками ещё до первой загрузки из приложения.
        try? FileManager.default.createDirectory(at: modelsRootURL,
                                                 withIntermediateDirectories: true)
    }

    // MARK: Что установлено

    /// Сканирует каталог моделей. Ищет рекурсивно (глубина ограничена), потому что
    /// Hub-загрузчик кладёт модель в `models/argmaxinc/whisperkit-coreml/<вариант>`,
    /// а руками пользователь может положить папку прямо в `models/<вариант>` —
    /// оба варианта должны находиться. Это и есть «поддержка ручной установки».
    public func installedModels() -> [InstalledWhisperModel] {
        var found: [InstalledWhisperModel] = []
        scanForModels(in: modelsRootURL, depth: 0, into: &found)
        return found.sorted { $0.variant < $1.variant }
    }

    public func isInstalled(_ variant: String) -> Bool {
        installedFolder(for: variant) != nil
    }

    /// Папка установленной модели или nil. Движок зовёт это перед warmUp.
    public func installedFolder(for variant: String) -> URL? {
        installedModels().first { $0.variant == variant }?.folderURL
    }

    private func scanForModels(in directory: URL, depth: Int, into result: inout [InstalledWhisperModel]) {
        // Глубины 4 хватает для `models/argmaxinc/whisperkit-coreml/<вариант>`
        // с запасом; глубже не лезем, чтобы не сканировать чужой мусор.
        guard depth <= 4 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if case .ok = integrity(at: entry) {
                result.append(InstalledWhisperModel(
                    variant: entry.lastPathComponent,
                    folderURL: entry,
                    sizeOnDisk: directorySize(of: entry)
                ))
            } else {
                scanForModels(in: entry, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: Целостность

    /// Проверка целостности: все три CoreML-артефакта и конфиг на месте.
    /// Это защита от оборванной загрузки и от «я скопировал полпапки».
    /// Дополнительная (глубокая) проверка — пробная загрузка модели —
    /// выполняется в конце `download`, см. ниже.
    public func integrity(at folder: URL) -> ModelIntegrity {
        let fm = FileManager.default
        var missing: [String] = []
        for artifact in Self.requiredArtifacts {
            let compiled = folder.appendingPathComponent("\(artifact).mlmodelc")
            let package = folder.appendingPathComponent("\(artifact).mlpackage")
            if !fm.fileExists(atPath: compiled.path) && !fm.fileExists(atPath: package.path) {
                missing.append(artifact)
            }
        }
        // config.json нужен WhisperKit для метаданных модели.
        if !fm.fileExists(atPath: folder.appendingPathComponent("config.json").path) {
            missing.append("config.json")
        }
        return missing.isEmpty ? .ok : .incomplete(missing: missing)
    }

    // MARK: Загрузка

    /// Загрузка модели с Hugging Face.
    ///
    /// ⚠️ Вызывается ТОЛЬКО по явному действию пользователя, после того как UI
    /// показал ему размер (`descriptor.approximateSizeMB`) и получил согласие.
    /// Это единственная точка выхода приложения в сеть (ТЗ 7.2).
    ///
    /// После загрузки делает две вещи, обе — осознанно:
    /// 1. Проверяет целостность по файлам.
    /// 2. Один раз загружает модель в память и выгружает. Зачем:
    ///    а) это настоящая проверка целостности — битая модель не загрузится;
    ///    б) при этом WhisperKit докачивает и кэширует токенайзер в ту же папку —
    ///       без этого первый warmUp движка полез бы в сеть за tokenizer.json,
    ///       что нарушило бы ТЗ 7.2 («сеть только здесь»);
    ///    в) CoreML при первой загрузке специализирует модель под чип и кэширует
    ///       результат — значит, первый настоящий warmUp будет быстрым.
    ///
    /// - Parameter progress: доля 0…1 для индикатора в UI. Вызывается не на главном потоке.
    /// - Returns: папка установленной модели.
    public func download(_ descriptor: WhisperModelDescriptor,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        logger.info("Модели: начинаю загрузку «\(descriptor.variant)» (~\(descriptor.approximateSizeMB) МБ)")

        // Качаем своим загрузчиком, а не `WhisperKit.download`: тот исправен,
        // пока исправна сеть, а huggingface.co из России рвёт соединение —
        // и обрыв на 400-мегабайтном артефакте означал бы «скачай всё заново».
        // Подробности и три приёма живучести — в ResilientModelDownloader.
        // Он же кладёт рядом токенайзер, за которым WhisperKit иначе полез бы
        // в сеть на первом же распознавании (ТЗ 7.2).
        let folder: URL
        do {
            folder = try await downloader.download(
                variant: descriptor.variant,
                repository: "argmaxinc/whisperkit-coreml",
                modelsRoot: modelsRootURL,
                progress: { fraction in
                    progress?(fraction)
                }
            )
        } catch {
            logger.error("Модели: загрузка «\(descriptor.variant)» не удалась: \(error.localizedDescription)")
            throw error
        }

        // Быстрая проверка по файлам.
        if case .incomplete(let missing) = integrity(at: folder) {
            logger.error("Модели: «\(descriptor.variant)» неполная, не хватает: \(missing.joined(separator: ", "))")
            throw ModelManagerError.downloadedModelBroken(variant: descriptor.variant, missing: missing)
        }

        // Глубокая проверка + кэш токенайзера + специализация CoreML (см. док-коммент).
        logger.info("Модели: «\(descriptor.variant)» загружена, проверяю (пробная загрузка в память)…")
        do {
            let verifyConfig = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: downloadBaseURL,
                verbose: false,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(verifyConfig)
            await pipe.unloadModels()
        } catch {
            logger.error("Модели: «\(descriptor.variant)» не прошла пробную загрузку: \(error.localizedDescription)")
            throw ModelManagerError.downloadedModelBroken(variant: descriptor.variant,
                                                          missing: ["модель не загружается: \(error.localizedDescription)"])
        }

        logger.info("Модели: «\(descriptor.variant)» установлена и проверена")
        return folder
    }

    // MARK: Ручная установка

    /// Импорт модели, которую пользователь скачал сам (например, git-lfs с HF).
    /// Копируем в наш каталог, чтобы у приложения был один источник правды,
    /// а пользовательская копия осталась нетронутой.
    ///
    /// ⚠️ Токенайзер при ручной установке не кэшируется (мы не ходим в сеть
    /// без явной команды). Если tokenizer.json не лежит рядом с моделью,
    /// первый warmUp честно упадёт с понятной ошибкой — UI предложит либо
    /// докачать через `download`, либо положить токенайзер рядом.
    @discardableResult
    public func importModel(from sourceURL: URL) throws -> URL {
        guard case .ok = integrity(at: sourceURL) else {
            throw ModelManagerError.importSourceInvalid(sourceURL.path)
        }
        let destination = modelsRootURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceURL, to: destination)
        logger.info("Модели: «\(sourceURL.lastPathComponent)» установлена вручную")
        return destination
    }

    /// Удаление модели с диска — для настроек («освободить место»).
    public func remove(_ variant: String) throws {
        guard let folder = installedFolder(for: variant) else {
            throw ModelManagerError.modelNotInstalled(variant)
        }
        try FileManager.default.removeItem(at: folder)
        logger.info("Модели: «\(variant)» удалена")
    }

    // MARK: Утилиты

    private func directorySize(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
