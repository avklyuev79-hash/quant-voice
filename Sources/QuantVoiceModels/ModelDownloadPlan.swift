//
//  ModelDownloadPlan.swift
//  QuantVoiceModels
//
//  Что именно надо скачать для модели — и чего качать не надо, потому что
//  оно уже лежит на диске.
//
//  Зачем свой загрузчик вместо `WhisperKit.download`. Штатный работает,
//  пока сеть работает. У нас она не работает: huggingface.co из России рвёт
//  соединение регулярно, и на 420-мегабайтном `weight.bin` это означает
//  «скачай всё заново». Скрипт `scripts/fetch-model.sh` эту задачу уже решил —
//  докачка с места обрыва, пропуск готовых файлов, повторы, — но скрипт
//  требует терминала, а приёмка M8 звучит как «человек доходит до первой
//  диктовки, не открывая терминал». Значит логику скрипта надо перенести
//  в приложение.
//
//  Здесь — чистая, проверяемая часть: разбор ответа Hugging Face, решение
//  «этот файл уже целиком на месте», выбор репозитория токенайзера.
//  Сама сеть живёт в приложении и в тестах не участвует.
//

import Foundation

/// Один файл модели в репозитории.
public struct ModelFile: Equatable, Sendable {
    /// Путь внутри репозитория: «openai_whisper-small_216MB/config.json».
    public let path: String
    /// Размер в байтах. Для LFS-файлов — размер настоящего содержимого,
    /// а не указателя: именно по нему мы понимаем, докачан файл или оборван.
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }

    /// Путь относительно папки варианта — префикс варианта убираем, иначе
    /// получится вложенная папка с тем же именем.
    public func relativePath(strippingVariant variant: String) -> String {
        let prefix = variant + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

public enum ModelDownloadPlan {

    /// Разбор ответа `/api/models/{repo}/tree/main/{variant}?recursive=true`.
    ///
    /// Список файлов берём у Hugging Face, а не зашиваем в код: у вариантов
    /// разный набор артефактов, и захардкоженный список молча устареет при
    /// смене версии модели.
    public static func parseTree(_ data: Data) throws -> [ModelFile] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelDownloadPlanError.malformedListing
        }
        let files: [ModelFile] = raw.compactMap { entry in
            guard entry["type"] as? String == "file",
                  let path = entry["path"] as? String else { return nil }
            // У LFS-файлов в `size` лежит размер указателя (~130 байт),
            // а настоящий размер — во вложенном `lfs`. Перепутать их значит
            // считать оборванный файл готовым.
            let lfsSize = (entry["lfs"] as? [String: Any])?["size"] as? Int
            let size = lfsSize ?? (entry["size"] as? Int) ?? 0
            return ModelFile(path: path, size: size)
        }
        guard !files.isEmpty else { throw ModelDownloadPlanError.emptyListing }
        return files
    }

    /// Нужно ли качать файл, если на диске уже лежит `existingSize` байт.
    ///
    /// Совпал размер — файл целиком на месте, пропускаем: это и делает
    /// загрузку перезапускаемой. Меньше — оборвался, докачиваем с этого места.
    /// Больше — что-то не то, качаем заново с нуля.
    public static func action(expected: Int, existing: Int?) -> FileAction {
        guard let existing, existing > 0 else { return .downloadFromScratch }
        if existing == expected { return .skip }
        if existing < expected { return .resume(from: existing) }
        return .downloadFromScratch
    }

    public enum FileAction: Equatable, Sendable {
        case skip
        case resume(from: Int)
        case downloadFromScratch
    }

    /// Репозиторий токенайзера для варианта модели.
    ///
    /// ⚠️ Токенайзер — отдельная сущность, и без него модель бесполезна:
    /// WhisperKit грузит веса, а потом идёт за `tokenizer.json` в Hub —
    /// даже когда сеть ему запрещена (`download: false`, запрет касается
    /// только весов). На заблокированном huggingface.co этот запрос не падает,
    /// а виснет, и снаружи выглядит как вечное «Распознаю…». Грабля стоила
    /// нам четырёх минут тишины в логе и часа поисков.
    public static func tokenizerRepository(forVariant variant: String) -> String {
        let lower = variant.lowercased()
        if lower.contains("small") { return "openai/whisper-small" }
        if lower.contains("large-v2") { return "openai/whisper-large-v2" }
        if lower.contains("base") { return "openai/whisper-base" }
        if lower.contains("tiny") { return "openai/whisper-tiny" }
        return "openai/whisper-large-v3"
    }

    /// Текстовые артефакты токенайзера. Веса (.safetensors, .bin) не трогаем —
    /// они весят гигабайты и нам не нужны.
    public static let tokenizerFiles = [
        "tokenizer.json", "tokenizer_config.json", "config.json",
        "generation_config.json", "special_tokens_map.json", "added_tokens.json",
        "vocab.json", "merges.txt", "normalizer.json", "preprocessor_config.json",
    ]

    /// Без этого файла токенайзер бесполезен — остальные необязательны
    /// и у части вариантов просто отсутствуют.
    public static let requiredTokenizerFile = "tokenizer.json"

    /// Артефакты, без которых модель не считается установленной.
    /// Тот же список, что проверяет ModelManager.integrity.
    public static let requiredModelArtifacts = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
}

public enum ModelDownloadPlanError: LocalizedError, Equatable {
    case malformedListing
    case emptyListing

    public var errorDescription: String? {
        switch self {
        case .malformedListing:
            return "Список файлов модели пришёл в неожиданном виде"
        case .emptyListing:
            return "Список файлов модели пуст — проверь имя варианта"
        }
    }
}
