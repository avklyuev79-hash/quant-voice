//
//  Contracts.swift
//  Quant Voice
//
//  Общие типы и протоколы. Единственный файл, который знают все модули.
//  Модули знают только этот файл и никогда — друг друга.
//
//  ⚠️ Этот файл — контракт. Менять его можно только согласованно:
//  правка здесь ломает все модули сразу.
//

import Foundation

// MARK: - Язык

/// Язык распознавания. Задаётся явно хоткеем (см. ТЗ 6.5), авто — третий режим.
public enum RecognitionLanguage: String, Codable, Sendable, CaseIterable {
    case russian = "ru"
    case english = "en"
    case auto

    /// BCP-47 идентификатор для системных API. Для `.auto` — nil.
    public var localeIdentifier: String? {
        switch self {
        case .russian: return "ru-RU"
        case .english: return "en-US"
        case .auto:    return nil
        }
    }

    /// Двухбуквенный код для Whisper. Для `.auto` — nil (модель определит сама).
    public var whisperCode: String? {
        switch self {
        case .russian: return "ru"
        case .english: return "en"
        case .auto:    return nil
        }
    }
}

// MARK: - Аудио

/// Формат, в котором работает весь конвейер. Единственный. Никаких вариаций.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: UInt32 = 1
}

/// Кусок аудио, готовый к подаче в движок: 16 кГц, моно, float32 в диапазоне [-1, 1].
///
/// Живёт только в памяти. На диск не пишется никогда (см. ТЗ 7.1).
public struct AudioSegment: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Момент начала записи — для замеров латентности.
    public let startedAt: Date

    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }

    public init(samples: [Float], sampleRate: Double = AudioFormat.sampleRate, startedAt: Date) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startedAt = startedAt
    }
}

/// Захват звука с микрофона.
///
/// Реализация обязана: работать в 16 кГц моно (ресемплить на лету, если устройство
/// отдаёт другое), не писать на диск, отдавать уровень для индикатора в оверлее.
public protocol AudioCapturing: AnyObject {
    /// Идёт ли запись прямо сейчас.
    var isCapturing: Bool { get }

    /// Текущий уровень сигнала 0…1 для индикатора. Обновляется ~20 раз в секунду.
    /// Читается с главного потока.
    var level: Float { get }

    /// Вызывается при изменении уровня — чтобы оверлей не опрашивал в цикле.
    var onLevelChange: ((Float) -> Void)? { get set }

    /// Начать запись. Бросает, если нет доступа к микрофону или устройство недоступно.
    func start() throws

    /// Остановить запись и забрать накопленное.
    /// Возвращает nil, если записи не было или она пустая.
    func stop() -> AudioSegment?

    /// Прервать запись и выбросить накопленное. Используется при отмене по Esc.
    func cancel()

    /// Есть ли разрешение на микрофон.
    static func permissionStatus() -> PermissionStatus

    /// Запросить разрешение. Вызывает системный диалог при первом обращении.
    static func requestPermission() async -> Bool
}

/// Состояние системного разрешения.
public enum PermissionStatus: Sendable {
    case granted
    case denied
    case notDetermined
}

// MARK: - Распознавание

/// Настройки конкретного распознавания.
public struct TranscriptionOptions: Sendable {
    public let language: RecognitionLanguage

    /// Подсказка модели — список терминов и брендов в естественном контексте.
    /// Whisper читает последние ≤224 токена, важное должно быть в конце (см. ТЗ 6.6).
    /// Системный движок Apple может игнорировать.
    public let contextPrompt: String?

    public init(language: RecognitionLanguage, contextPrompt: String? = nil) {
        self.language = language
        self.contextPrompt = contextPrompt
    }
}

/// Результат распознавания.
public struct Transcript: Sendable {
    /// Распознанный текст. Уже без ведущих и хвостовых пробелов.
    public let text: String

    /// Какой язык модель фактически использовала. nil, если движок не сообщает.
    public let detectedLanguage: String?

    /// Уверенность 0…1, если движок её отдаёт. nil — не сообщает.
    public let confidence: Float?

    /// Сколько заняло само распознавание — для замеров по ТЗ 9.1.
    public let processingTime: TimeInterval

    public init(text: String,
                detectedLanguage: String? = nil,
                confidence: Float? = nil,
                processingTime: TimeInterval) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.confidence = confidence
        self.processingTime = processingTime
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Движок распознавания речи.
///
/// Реализаций две: системный `SpeechAnalyzer` (macOS 26) и WhisperKit.
/// Выбор — в рантайме, см. `EngineSelector`.
///
/// ⚠️ Ключевое требование: модель загружается ОДИН раз в `warmUp()` и живёт
/// резидентно. Перезагрузка модели на каждую фразу — главная ошибка,
/// которую мы не повторяем (см. ТЗ 6.1).
public protocol TranscriptionEngine: AnyObject {
    /// Человекочитаемое имя для логов и настроек.
    var displayName: String { get }

    /// Готов ли движок принимать аудио. False до `warmUp()`.
    var isReady: Bool { get }

    /// Какие языки движок реально поддерживает на этой машине.
    /// Для системного движка Apple определяется в рантайме — список локалей
    /// зависит от версии macOS (см. ТЗ 5.3, открытый вопрос №1).
    func supportedLanguages() async -> [RecognitionLanguage]

    /// Загрузить модель в память. Долгая операция, вызывается один раз при старте.
    func warmUp() async throws

    /// Распознать сегмент. Модель уже должна быть прогрета.
    func transcribe(_ audio: AudioSegment, options: TranscriptionOptions) async throws -> Transcript

    /// Выгрузить модель из памяти. Для экономии при долгом простое.
    func unload()
}

/// Ошибки распознавания.
public enum TranscriptionError: LocalizedError {
    case engineNotReady
    case modelMissing(String)
    case languageUnsupported(RecognitionLanguage)
    case audioTooShort
    case failed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Движок распознавания не готов"
        case .modelMissing(let name):
            return "Модель «\(name)» не установлена"
        case .languageUnsupported(let lang):
            return "Язык «\(lang.rawValue)» не поддерживается выбранным движком"
        case .audioTooShort:
            return "Слишком короткая запись"
        case .failed(let error):
            return "Не удалось распознать: \(error.localizedDescription)"
        }
    }
}

// MARK: - Хоткей

/// Как пользователь запустил сессию.
public enum CaptureMode: Sendable {
    /// Держит клавишу — пишем. Отпустил — распознаём.
    case hold
    /// Нажал — пишем. Нажал ещё раз — распознаём.
    case toggle
}

/// События от монитора хоткеев.
public enum HotkeyEvent: Sendable {
    /// Начать сессию записи.
    case startCapture(mode: CaptureMode, language: RecognitionLanguage)
    /// Завершить запись и распознать.
    case finishCapture
    /// Отменить, выбросить запись (Esc).
    case cancel
}

/// Глобальный перехват клавиш через CGEventTap.
///
/// ⚠️ Требует разрешения Accessibility. Без него `start()` бросает.
/// ⚠️ Перехват Esc включается только на время сессии и снимается сразу после,
/// чтобы не ломать Esc в остальной системе.
public protocol HotkeyMonitoring: AnyObject {
    var isMonitoring: Bool { get }

    /// Сюда прилетают события. Вызывается на главном потоке.
    var onEvent: ((HotkeyEvent) -> Void)? { get set }

    func start() throws
    func stop()

    /// Включить перехват Esc. Вызывается координатором при начале сессии.
    func beginEscapeCapture()

    /// Выключить перехват Esc. Вызывается при любом завершении сессии.
    func endEscapeCapture()

    /// Есть ли разрешение Accessibility.
    static func permissionStatus() -> PermissionStatus

    /// Открыть системные настройки на нужном разделе.
    static func openPermissionSettings()
}

// MARK: - Вставка текста

/// Каким способом текст в итоге попал к пользователю.
/// Логируется для чек-листа совместимости по ТЗ 9.4.
public enum InsertionMethod: String, Sendable {
    /// Accessibility API — быстро, буфер не тронут. Основной путь.
    case accessibility
    /// Синтетический ⌘V с восстановлением буфера. Фолбэк.
    case paste
    /// Положили в буфер, показали уведомление. Последняя линия.
    case clipboardOnly
}

public struct InsertionResult: Sendable {
    public let method: InsertionMethod
    public let duration: TimeInterval

    public init(method: InsertionMethod, duration: TimeInterval) {
        self.method = method
        self.duration = duration
    }
}

/// Вставка текста в поле под курсором.
///
/// Каскад строго в порядке: Accessibility → ⌘V → буфер (см. ТЗ 5.6).
/// ⚠️ Текст не теряется никогда: если не сработали первые два пути,
/// он в любом случае оказывается в буфере обмена.
public protocol TextInserting: AnyObject {
    /// Вставить текст. Не бросает при неудаче первых уровней — деградирует.
    /// Бросает только если текст не удалось даже положить в буфер.
    @MainActor
    func insert(_ text: String) async throws -> InsertionResult

    /// Является ли сфокусированное поле полем ввода пароля.
    /// В такие поля не вставляем никогда (см. ТЗ 5.6).
    @MainActor
    func focusedFieldIsSecure() -> Bool
}

public enum InsertionError: LocalizedError {
    case secureFieldRefused
    case clipboardUnavailable

    public var errorDescription: String? {
        switch self {
        case .secureFieldRefused:
            return "Вставка в поле пароля заблокирована"
        case .clipboardUnavailable:
            return "Буфер обмена недоступен"
        }
    }
}

// MARK: - Постобработка

/// Причёсывание распознанного текста.
///
/// ⚠️ Жёсткое правило: постобработка НИКОГДА не ломает диктовку (см. ТЗ 5.7).
/// Таймаут, проверка вменяемости, при любом сбое — сырой текст.
public protocol TextRefining: AnyObject {
    var displayName: String { get }
    var isAvailable: Bool { get async }

    /// Причесать текст. Реализация ОБЯЗАНА вернуть исходный текст при любой проблеме,
    /// а не бросать. Бросать нельзя — это ломает диктовку.
    func refine(_ text: String, language: RecognitionLanguage) async -> String
}

// MARK: - Слой терминов

/// Промпт для prompt-biasing (ТЗ 6.6, уровень 1).
public struct TermsPrompt: Sendable {
    public let text: String
    /// Сколько терминов вошло — для лога координатора.
    public let termCount: Int

    public init(text: String, termCount: Int) {
        self.text = text
        self.termCount = termCount
    }
}

/// Результат словаря замен (ТЗ 6.6, уровень 2).
public struct TermsReplacementResult: Sendable {
    public let text: String
    /// Канонические написания сработавших терминов — ТОЛЬКО для лога.
    /// Исходные (заменённые) слова сюда не попадают: они часть распознанного
    /// текста, а он в лог не пишется никогда (ТЗ 7.4).
    public let appliedCanonicals: [String]

    public init(text: String, appliedCanonicals: [String]) {
        self.text = text
        self.appliedCanonicals = appliedCanonicals
    }
}

/// Слой терминов (ТЗ 6.6): до распознавания подсказывает модели ожидаемые
/// термины, после — детерминированно чинит известные ослышки.
///
/// `@MainActor`, потому что вызывается координатором с главного актора
/// и работает со словарём, который параллельно редактирует UI настроек.
/// Обе операции обязаны быть дешёвыми (единицы миллисекунд на заранее
/// подготовленном кэше) — главный актор они не задерживают.
@MainActor
public protocol TermsApplying: AnyObject {
    /// Промпт под текущую диктовку. nil — словарь пуст, подсказывать нечего.
    func transcriptionPrompt(for language: RecognitionLanguage) -> TermsPrompt?

    /// Применить словарь замен к распознанному тексту.
    func applyReplacements(to text: String) -> TermsReplacementResult
}

// MARK: - Состояние сессии

/// Что показывает оверлей. Ровно эти состояния, других нет.
public enum SessionState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case refining
    case inserting
    case completed(InsertionMethod)
    case cancelled
    case failed(String)
}

// MARK: - Замеры

/// Тайминги одной сессии — для критерия приёмки по ТЗ 9.1.
/// Заполняется координатором, пишется в лог в отладочном режиме.
public struct SessionMetrics: Sendable {
    public var audioDuration: TimeInterval = 0
    public var transcriptionTime: TimeInterval = 0
    public var refinementTime: TimeInterval = 0
    public var insertionTime: TimeInterval = 0
    /// Главная цифра: от отпускания клавиши до текста в поле.
    public var endToEndLatency: TimeInterval = 0

    public init() {}

    public var summary: String {
        String(format: "аудио %.2fс · распознавание %.0fмс · причёсывание %.0fмс · вставка %.0fмс · итого %.0fмс",
               audioDuration,
               transcriptionTime * 1000,
               refinementTime * 1000,
               insertionTime * 1000,
               endToEndLatency * 1000)
    }
}

// MARK: - Логирование

/// Логгер приложения.
///
/// ⚠️ В лог НИКОГДА не попадает распознанный текст, содержимое буфера обмена
/// или аудиоданные (см. ТЗ 7.4). Это проверяется тестом.
public protocol Logging: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}
