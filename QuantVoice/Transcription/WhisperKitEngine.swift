//
//  WhisperKitEngine.swift
//  Quant Voice
//
//  Реализация TranscriptionEngine на WhisperKit (argmaxinc/argmax-oss-swift, MIT).
//
//  Ключевое требование (ТЗ 6.1): модель загружается ОДИН раз в warmUp() и живёт
//  резидентно в памяти. Никаких перезагрузок между фразами, никаких подпроцессов.
//  Это главный источник скорости и главное отличие от VoxLocal.
//
//  ⚠️ Сеть: движок сконфигурирован с download: false — он НИКОГДА не ходит в сеть.
//  Модель и токенайзер заранее кладёт на диск ModelManager (ТЗ 7.2).
//

import Foundation
import WhisperKit

public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {

    // MARK: - Состояние

    // Почему @unchecked Sendable, а не actor: протокол TranscriptionEngine требует
    // СИНХРОННЫЕ `isReady` и `unload()`, которые актор дать не может. Поэтому класс,
    // а потокобезопасность обеспечиваем вручную: все мутабельные поля читаются
    // и пишутся только под `stateLock`. Сам объект WhisperKit не потокобезопасен,
    // но одновременных transcribe у нас не бывает по построению — координатор
    // ведёт одну сессию за раз; на случай ошибки в верхнем слое стоит
    // защита `transcriptionInFlight` (честный отказ вместо гонки данных).

    private let stateLock = NSLock()
    private var whisperKit: WhisperKit?      // только под stateLock
    private var ready = false                // только под stateLock
    private var warming = false              // только под stateLock
    private var transcriptionInFlight = false // только под stateLock

    private let modelManager: ModelManager
    private let logger: any Logging
    private let profile: WhisperModelProfile

    /// Записи короче этого порога не подаём в модель: Whisper на обрывках
    /// и тишине галлюцинирует (ТЗ 6.3). 0.3 с — меньше любого осмысленного слова.
    private static let minimumAudioDuration: TimeInterval = 0.3

    /// Если пик амплитуды ниже этого порога — в записи физически нет речи,
    /// только шум АЦП. Дешёвая страховка от галлюцинаций до появления
    /// полноценного VAD (M4).
    private static let silenceAmplitudeThreshold: Float = 0.001

    /// Известные галлюцинации Whisper на тишине/шуме — артефакты обучения
    /// на субтитрах YouTube. Сегмент с таким текстом и повышенным noSpeechProb
    /// выбрасываем. Список короткий и точечный, чтобы не задеть живую речь.
    private static let hallucinationMarkers: [String] = [
        "продолжение следует",
        "субтитры сделал",
        "субтитры подготовил",
        "редактор субтитров",
        "dimatorzok",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
    ]

    public init(modelManager: ModelManager,
                profile: WhisperModelProfile = .standard,
                logger: any Logging) {
        self.modelManager = modelManager
        self.profile = profile
        self.logger = logger
    }

    // MARK: - TranscriptionEngine

    public var displayName: String { "WhisperKit (\(Self.modelDescriptor(for: profile).displayName))" }

    public var isReady: Bool {
        stateLock.withLock { ready }
    }

    /// Whisper мультиязычен всегда; но «реально поддерживает на этой машине»
    /// означает «есть модель на диске». Без модели список пуст — так
    /// EngineSelector честно видит, что движок пока бесполезен.
    public func supportedLanguages() async -> [RecognitionLanguage] {
        let variant = Self.modelDescriptor(for: profile).variant
        guard await modelManager.isInstalled(variant) else { return [] }
        // .auto включён: Whisper умеет определять язык сам (ТЗ 6.5, третий режим).
        return [.russian, .english, .auto]
    }

    public func warmUp() async throws {
        // Повторный warmUp — не ошибка: селектор может дёргать его при
        // переключении движков. Если уже готовы или уже греемся — выходим тихо.
        let shouldProceed: Bool = stateLock.withLock {
            if ready || warming { return false }
            warming = true
            return true
        }
        guard shouldProceed else { return }
        defer { stateLock.withLock { warming = false } }

        let descriptor = Self.modelDescriptor(for: profile)

        guard let folder = await modelManager.installedFolder(for: descriptor.variant) else {
            logger.warning("WhisperKit: модель «\(descriptor.variant)» не установлена, warmUp невозможен")
            throw TranscriptionError.modelMissing(descriptor.displayName)
        }

        logger.info("WhisperKit: загружаю модель «\(descriptor.variant)» в память…")
        let start = Date()

        let config = WhisperKitConfig(
            // modelFolder задан явно → WhisperKit не пойдёт в сеть за моделью.
            modelFolder: folder.path,
            // Токенайзер закэширован ModelManager'ом в этой же базе при установке.
            tokenizerFolder: modelManager.downloadBaseURL,
            // Дефолтные computeOptions: CoreML сам раскладывает слои по ANE/GPU/CPU —
            // ровно то, ради чего выбран WhisperKit (ТЗ 5.2).
            verbose: false,
            // prewarm выключен: он удваивает время загрузки ради экономии пиковой
            // памяти, а у нас модель и так живёт резидентно — грузим сразу.
            prewarm: false,
            load: true,
            // ⚠️ Жёсткий запрет сети для движка (ТЗ 7.2).
            download: false
        )

        do {
            let pipe = try await WhisperKit(config)
            stateLock.withLock {
                whisperKit = pipe
                ready = true
            }
            let elapsed = Date().timeIntervalSince(start)
            logger.info(String(format: "WhisperKit: модель загружена за %.2f с, резидентна в памяти", elapsed))
        } catch {
            logger.error("WhisperKit: загрузка модели не удалась: \(error.localizedDescription)")
            throw TranscriptionError.failed(underlying: error)
        }
    }

    public func transcribe(_ audio: AudioSegment,
                           options: TranscriptionOptions) async throws -> Transcript {
        // Захватываем pipe и помечаем «в работе» атомарно.
        let pipe: WhisperKit = try stateLock.withLock {
            guard ready, let pipe = whisperKit else {
                throw TranscriptionError.engineNotReady
            }
            guard !transcriptionInFlight else {
                // Верхний слой не должен звать нас параллельно. Если позвал —
                // честный отказ безопаснее гонки внутри не-потокобезопасного WhisperKit.
                throw TranscriptionError.engineNotReady
            }
            transcriptionInFlight = true
            return pipe
        }
        defer { stateLock.withLock { transcriptionInFlight = false } }

        // Отсечка мусора ДО модели: короткие обрывки и чистая тишина —
        // источник галлюцинаций Whisper (ТЗ 6.3).
        guard audio.duration >= Self.minimumAudioDuration else {
            throw TranscriptionError.audioTooShort
        }
        guard let peak = audio.samples.max(by: { abs($0) < abs($1) }),
              abs(peak) >= Self.silenceAmplitudeThreshold else {
            throw TranscriptionError.audioTooShort
        }

        let decodeOptions = makeDecodingOptions(for: options, tokenizer: pipe.tokenizer)

        let start = Date()
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: audio.samples,
                                                decodeOptions: decodeOptions)
        } catch {
            logger.error("WhisperKit: распознавание не удалось: \(error.localizedDescription)")
            throw TranscriptionError.failed(underlying: error)
        }
        let processingTime = Date().timeIntervalSince(start)

        // Постфильтр галлюцинаций: WhisperKit сам гасит окна по noSpeechThreshold,
        // но одиночные фантомные сегменты просачиваются — добираем их здесь.
        let segments = results.flatMap { $0.segments }
        let keptSegments = segments.filter { !Self.isLikelyHallucination($0) }
        if keptSegments.count < segments.count {
            logger.debug("WhisperKit: отброшено сегментов-галлюцинаций: \(segments.count - keptSegments.count)")
        }

        let text = keptSegments
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Грубая уверенность из средней лог-вероятности токенов: exp() переводит
        // её в 0…1. Не строгая метрика, но достаточно для «подсветить сомнительное».
        let confidence: Float?
        if keptSegments.isEmpty {
            confidence = nil
        } else {
            let avgLogProb = keptSegments.map(\.avgLogprob).reduce(0, +) / Float(keptSegments.count)
            confidence = min(1, max(0, exp(avgLogProb)))
        }

        logger.debug(String(format: "WhisperKit: %.2f с аудио распознано за %.0f мс",
                            audio.duration, processingTime * 1000))

        // Разбивка по стадиям (M4). Без неё оптимизация — гадание: обрезка тишины
        // лечит только логмелы и энкодер, а если время съедает цикл декодера,
        // помогает совсем другое (меньше токенов, другой профиль модели).
        // `totalDecodingFallbacks` > 0 означает, что модель не уложилась в порог
        // с первой попытки и прогнала декодер заново — это удвоение латентности.
        if let t = results.first?.timings {
            logger.debug(String(format:
                "WhisperKit: стадии — логмелы %.0f мс · энкодер %.0f мс · декодер %.0f мс (циклов %.0f, фолбэков %.0f)",
                t.logmels * 1000,
                t.encoding * 1000,
                t.decodingLoop * 1000,
                t.totalDecodingLoops,
                t.totalDecodingFallbacks))
        }

        return Transcript(
            text: text,
            detectedLanguage: results.first?.language,
            confidence: confidence,
            processingTime: processingTime
        )
    }

    public func unload() {
        // Синхронный контракт: флаг снимаем сразу (движок мгновенно «не готов»),
        // само освобождение памяти — асинхронно в фоне.
        stateLock.withLock { ready = false }
        Task { [weak self] in
            guard let self else { return }
            let pipe: WhisperKit? = self.stateLock.withLock {
                let p = self.whisperKit
                self.whisperKit = nil
                return p
            }
            await pipe?.unloadModels()
            self.logger.info("WhisperKit: модель выгружена из памяти")
        }
    }

    // MARK: - Параметры декодирования

    private func makeDecodingOptions(for options: TranscriptionOptions,
                                     tokenizer: WhisperTokenizer?) -> DecodingOptions {
        // Проброс contextPrompt (ТЗ 6.6, prompt-biasing): WhisperKit принимает
        // токены, поэтому кодируем строку токенайзером модели. Ведущий пробел —
        // конвенция Whisper: токены слов «с пробелом» и «без» различаются,
        // без пробела первое слово промпта склеится с спецтокеном.
        // Обрезать до 224 не нужно: WhisperKit сам берёт последний ~половинный
        // контекст (suffix(223)) и сам добавляет <|startofprev|> — важное в конце
        // промпта переживает обрезку, как и требует ТЗ.
        var promptTokens: [Int]?
        if let prompt = options.contextPrompt, !prompt.isEmpty, let tokenizer {
            let encoded = tokenizer.encode(text: " " + prompt)
                // Токенайзер может добавить спецтокены — в промпте им не место.
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = encoded.isEmpty ? nil : encoded
        }

        let isAuto = (options.language == .auto)

        return DecodingOptions(
            task: .transcribe,
            // Для ru/en — явная фиксация языка (ТЗ 6.5: авто-детект ошибается
            // на коротких фразах). Для .auto язык не задаём — модель определит.
            language: options.language.whisperCode,
            // Жадное декодирование: температура 0 — максимум детерминизма и скорости.
            temperature: 0.0,
            // Дефолтные 5 фолбэков с ростом температуры — это до 6 прогонов декодера
            // в худшем случае. Для диктовки с бюджетом 400 мс режем до 2.
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: isAuto,
            skipSpecialTokens: true,
            // Таймстемпы не нужны: вставляем цельный текст. Без них декодер
            // тратит меньше токенов — прямой выигрыш в латентности.
            withoutTimestamps: true,
            wordTimestamps: false,
            promptTokens: promptTokens,
            // Пороги подавления галлюцинаций. compressionRatio ловит зацикливание
            // («и и и и…»), logProb — неуверенный бред, noSpeech 0.5 (строже
            // дефолтных 0.6) — фантомный текст на тишине. Значения — стартовые,
            // тонкая настройка по замерам на M4.
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.5,
            // Фразы диктовки короче 30-секундного окна Whisper — чанкинг не нужен,
            // его VAD-обвязка только добавила бы латентности.
            chunkingStrategy: nil
        )
    }

    // MARK: - Фильтр галлюцинаций

    private static func isLikelyHallucination(_ segment: TranscriptionSegment) -> Bool {
        // Совсем фантомный сегмент: модель сама почти уверена, что речи не было.
        if segment.noSpeechProb > 0.8 { return true }

        // Типовой YouTube-артефакт при заметной вероятности тишины.
        // Порог 0.3 — чтобы не выбросить настоящую фразу «продолжение следует»
        // в живой диктовке, где noSpeechProb будет низким.
        if segment.noSpeechProb > 0.3 {
            let normalized = segment.text.lowercased()
            if hallucinationMarkers.contains(where: { normalized.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Каталог

    private static func modelDescriptor(for profile: WhisperModelProfile) -> WhisperModelDescriptor {
        ModelManager.descriptor(for: profile)
    }
}
