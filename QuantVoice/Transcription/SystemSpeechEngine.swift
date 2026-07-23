//
//  SystemSpeechEngine.swift
//  Quant Voice
//
//  Реализация TranscriptionEngine на системном Apple SpeechAnalyzer/SpeechTranscriber
//  (фреймворк Speech, появились в macOS 26 «Tahoe», WWDC25 session 277).
//
//  Почему первый приоритет: работает на Neural Engine, модель системная —
//  ничего не качаем, ноль веса в бандле, мгновенный старт (ТЗ 5.3).
//
//  ⚠️ Открытый вопрос проекта №1: есть ли русский в supportedLocales.
//  Определяется ТОЛЬКО в рантайме: warmUp() логирует полный список локалей
//  на уровне info — это и есть ответ, который мы ждём после первой сборки.
//
//  Deployment target — macOS 14, поэтому всё, что требует macOS 26, обёрнуто
//  в @available/#available. На macOS 14-15 движок корректно сообщает, что
//  недоступен (isReady == false, supportedLanguages == [], warmUp бросает),
//  и никогда не падает.
//

import Foundation
import AVFoundation
// @preconcurrency: новые типы Speech (SpeechAnalyzer и др.) в SDK местами ещё
// не размечены Sendable-аннотациями полностью; мы используем их строго внутри
// одной задачи, поэтому глушим ложные предупреждения строгой конкурентности.
@preconcurrency import Speech

public final class SystemSpeechEngine: TranscriptionEngine, @unchecked Sendable {

    // MARK: - Состояние

    // Класс, а не актор — по той же причине, что и WhisperKitEngine:
    // контракт требует синхронные isReady/unload. Мутабельное состояние — под замком.
    private let stateLock = NSLock()
    private var ready = false                          // только под stateLock
    /// Языки, для которых системный языковой пакет реально установлен на машине.
    private var installedRecognitionLanguages: [RecognitionLanguage] = [] // под stateLock

    private let logger: any Logging

    /// Пороги те же, что у WhisperKitEngine, — единое поведение для верхнего слоя.
    private static let minimumAudioDuration: TimeInterval = 0.3
    private static let silenceAmplitudeThreshold: Float = 0.001

    public init(logger: any Logging) {
        self.logger = logger
    }

    /// Быстрая статическая проверка «эта macOS вообще умеет SpeechAnalyzer?».
    /// EngineSelector использует её, чтобы не дёргать warmUp впустую на macOS 14-15.
    public static var isRuntimeAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    // MARK: - TranscriptionEngine

    public var displayName: String { "Apple SpeechAnalyzer (системный)" }

    public var isReady: Bool {
        stateLock.withLock { ready }
    }

    /// «Реально поддерживает на этой машине» = языковой пакет УСТАНОВЛЕН.
    /// Просто «поддерживаемый, но не скачанный» язык сюда не попадает:
    /// мы не имеем права тянуть ассет без явного действия пользователя (ТЗ 7.2),
    /// а движок, которому нечем распознавать, не должен выигрывать выбор
    /// в EngineSelector. Скачиваемые языки отдаёт `downloadableLanguages()`.
    public func supportedLanguages() async -> [RecognitionLanguage] {
        guard #available(macOS 26.0, *) else { return [] }
        let installed = await SpeechTranscriber.installedLocales
        return Self.recognitionLanguages(from: installed)
    }

    /// Языки, которые система поддерживает, но пакет ещё не скачан.
    /// UI настроек показывает их с кнопкой «скачать» → installLanguageAsset.
    public func downloadableLanguages() async -> [RecognitionLanguage] {
        guard #available(macOS 26.0, *) else { return [] }
        let supported = Self.recognitionLanguages(from: await SpeechTranscriber.supportedLocales)
        let installed = Self.recognitionLanguages(from: await SpeechTranscriber.installedLocales)
        return supported.filter { !installed.contains($0) }
    }

    public func warmUp() async throws {
        guard #available(macOS 26.0, *) else {
            logger.info("SpeechAnalyzer: недоступен — требуется macOS 26, текущая система старше")
            throw TranscriptionError.engineNotReady
        }

        // ГЛАВНЫЙ ЛОГ ПРОЕКТА (открытый вопрос №1): полный список локалей.
        // По нему принимается решение из ТЗ 5.3 — делать ли системный движок дефолтом.
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let supportedIDs = supported.map { $0.identifier(.bcp47) }.sorted()
        let installedIDs = installed.map { $0.identifier(.bcp47) }.sorted()
        logger.info("SpeechAnalyzer: supportedLocales (\(supportedIDs.count)): \(supportedIDs.joined(separator: ", "))")
        logger.info("SpeechAnalyzer: installedLocales (\(installedIDs.count)): \(installedIDs.joined(separator: ", "))")

        let supportedLangs = Self.recognitionLanguages(from: supported)
        let installedLangs = Self.recognitionLanguages(from: installed)
        logger.info("SpeechAnalyzer: русский \(supportedLangs.contains(.russian) ? "ЕСТЬ" : "ОТСУТСТВУЕТ") в supported, "
            + "пакет \(installedLangs.contains(.russian) ? "установлен" : "не установлен"); "
            + "английский \(supportedLangs.contains(.english) ? "есть" : "отсутствует") в supported, "
            + "пакет \(installedLangs.contains(.english) ? "установлен" : "не установлен")")

        // Ассеты сами не качаем (ТЗ 7.2: сеть — только по явному действию).
        // Готовность = хотя бы один из наших языков уже установлен в системе.
        guard !installedLangs.isEmpty else {
            logger.warning("SpeechAnalyzer: ни один нужный языковой пакет не установлен — "
                + "нужна явная загрузка (installLanguageAsset) или другой движок")
            throw TranscriptionError.engineNotReady
        }

        stateLock.withLock {
            installedRecognitionLanguages = installedLangs
            ready = true
        }
        logger.info("SpeechAnalyzer: готов, установленные языки: \(installedLangs.map(\.rawValue).joined(separator: ", "))")
    }

    public func transcribe(_ audio: AudioSegment,
                           options: TranscriptionOptions) async throws -> Transcript {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.engineNotReady
        }
        let installedLangs: [RecognitionLanguage] = try stateLock.withLock {
            guard ready else { throw TranscriptionError.engineNotReady }
            return installedRecognitionLanguages
        }

        // SpeechTranscriber создаётся на конкретную локаль — режима «определи
        // язык сам» у него нет. .auto обслуживает только Whisper (ТЗ 6.5).
        guard options.language != .auto else {
            throw TranscriptionError.languageUnsupported(.auto)
        }
        guard installedLangs.contains(options.language),
              let localeID = options.language.localeIdentifier else {
            throw TranscriptionError.languageUnsupported(options.language)
        }

        guard audio.duration >= Self.minimumAudioDuration else {
            throw TranscriptionError.audioTooShort
        }
        guard let peak = audio.samples.max(by: { abs($0) < abs($1) }),
              abs(peak) >= Self.silenceAmplitudeThreshold else {
            throw TranscriptionError.audioTooShort
        }

        let start = Date()
        do {
            let text = try await Self.runAnalysis(samples: audio.samples,
                                                  sampleRate: audio.sampleRate,
                                                  localeIdentifier: localeID)
            let processingTime = Date().timeIntervalSince(start)
            logger.debug(String(format: "SpeechAnalyzer: %.2f с аудио распознано за %.0f мс",
                                audio.duration, processingTime * 1000))
            return Transcript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                detectedLanguage: localeID,
                // Уверенность системный API в стабильной форме не отдаёт.
                // TODO(M4): проверить атрибуты AttributedString результата —
                // в них может быть transcriptionConfidence; если есть — пробросить.
                confidence: nil,
                processingTime: processingTime
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            logger.error("SpeechAnalyzer: распознавание не удалось: \(error.localizedDescription)")
            throw TranscriptionError.failed(underlying: error)
        }
    }

    public func unload() {
        // Системная модель принадлежит ОС и памяти нашего процесса почти не держит —
        // выгружать нечего. Снимаем готовность для симметрии контракта.
        stateLock.withLock { ready = false }
        logger.debug("SpeechAnalyzer: деактивирован")
    }

    // MARK: - Явная загрузка языкового пакета

    /// Скачивание системного языкового пакета. Вызывается ТОЛЬКО по явному
    /// действию пользователя из UI (кнопка «скачать язык») — аналогично
    /// загрузке моделей в ModelManager. Скачивает Apple своими средствами,
    /// но это всё равно сеть, поэтому правило то же (ТЗ 7.2).
    public func installLanguageAsset(for language: RecognitionLanguage) async throws {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.engineNotReady
        }
        guard let localeID = language.localeIdentifier else {
            throw TranscriptionError.languageUnsupported(language)
        }
        let locale = Locale(identifier: localeID)

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { Self.sameLanguage($0, locale) }) else {
            logger.warning("SpeechAnalyzer: локаль \(localeID) не поддерживается системой")
            throw TranscriptionError.languageUnsupported(language)
        }

        logger.info("SpeechAnalyzer: запрашиваю загрузку языкового пакета \(localeID)…")
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
            logger.info("SpeechAnalyzer: языковой пакет \(localeID) установлен")
        } else {
            // nil-запрос означает «качать нечего — уже установлен».
            logger.info("SpeechAnalyzer: языковой пакет \(localeID) уже установлен")
        }

        // Обновляем кэш готовности.
        let installedLangs = Self.recognitionLanguages(from: await SpeechTranscriber.installedLocales)
        stateLock.withLock {
            installedRecognitionLanguages = installedLangs
            if !installedLangs.isEmpty { ready = true }
        }
    }

    // MARK: - Сам прогон анализа

    /// Один сеанс SpeechAnalyzer на одну фразу.
    ///
    /// Почему на каждую фразу новый анализатор: системная модель резидентна
    /// на уровне ОС, наш объект — лишь лёгкая сессия поверх неё, поэтому
    /// требование резидентности (ТЗ 6.1) не нарушается.
    /// TODO(M4): замерить накладные расходы создания сессии; если заметны —
    /// перейти на долгоживущий анализатор с потоковой подачей буферов
    /// (он же откроет путь к раннему декодированию, ТЗ 6.2).
    @available(macOS 26.0, *)
    private static func runAnalysis(samples: [Float],
                                    sampleRate: Double,
                                    localeIdentifier: String) async throws -> String {
        // Без volatileResults: нам нужен только финальный текст, промежуточные
        // варианты — лишняя работа и «прыгающий» текст (ТЗ 6.4).
        let transcriber = SpeechTranscriber(locale: Locale(identifier: localeIdentifier),
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Анализатор сообщает, в каком формате ему удобнее всего принимать звук
        // (обычно это НЕ наши 16 кГц) — конвертируем наш сегмент под него.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        guard let sourceBuffer = Self.makePCMBuffer(samples: samples, sampleRate: sampleRate) else {
            throw TranscriptionError.failed(underlying: NSError(
                domain: "QuantVoice.SystemSpeechEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать аудиобуфер"]))
        }
        let inputBuffer: AVAudioPCMBuffer
        if let analyzerFormat, analyzerFormat != sourceBuffer.format {
            inputBuffer = try Self.convert(sourceBuffer, to: analyzerFormat)
        } else {
            inputBuffer = sourceBuffer
        }

        // Вся фраза уже записана — подаём её одним куском и закрываем поток.
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: inputBuffer))
        continuation.finish()

        // Читателя результатов запускаем ДО старта анализа (канонический паттерн
        // WWDC25): документация не гарантирует буферизацию результатов, которые
        // никто не читал, поэтому надёжнее слушать поток с самого начала.
        // SpeechTranscriber Sendable (SpeechModule: Sendable) — захват безопасен.
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            // Закрытие потока НЕ завершает сессию — завершаем явно, иначе
            // results никогда не закончатся (поведение API, задокументировано Apple).
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    // MARK: - Аудио-утилиты

    /// [Float] 16 кГц моно → AVAudioPCMBuffer в том же формате.
    private static func makePCMBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AudioFormat.channelCount,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// Конвертация буфера в формат анализатора (ресемплинг/смена разрядности).
    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriptionError.failed(underlying: NSError(
                domain: "QuantVoice.SystemSpeechEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter не создан для формата \(format)"]))
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        // +4096 кадров запаса: ресемплер имеет право отдать чуть больше расчётного.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.failed(underlying: NSError(
                domain: "QuantVoice.SystemSpeechEngine", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать выходной буфер"]))
        }

        var sourceConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if sourceConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            sourceConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw TranscriptionError.failed(underlying: conversionError)
        }
        guard status != .error else {
            throw TranscriptionError.failed(underlying: NSError(
                domain: "QuantVoice.SystemSpeechEngine", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Ошибка конвертации аудио"]))
        }
        return output
    }

    // MARK: - Сопоставление локалей

    /// Locale системы → наши языки. Сравниваем по языковому коду («ru», «en»),
    /// а не по полному идентификатору: en-US/en-GB и т.п. равно годятся
    /// для английской диктовки, а формат идентификатора (ru_RU против ru-RU)
    /// у Apple исторически гуляет.
    private static func recognitionLanguages(from locales: [Locale]) -> [RecognitionLanguage] {
        var result: [RecognitionLanguage] = []
        let codes = Set(locales.compactMap { $0.language.languageCode?.identifier.lowercased() })
        if codes.contains("ru") { result.append(.russian) }
        if codes.contains("en") { result.append(.english) }
        return result
    }

    private static func sameLanguage(_ a: Locale, _ b: Locale) -> Bool {
        a.language.languageCode?.identifier.lowercased() == b.language.languageCode?.identifier.lowercased()
    }
}
