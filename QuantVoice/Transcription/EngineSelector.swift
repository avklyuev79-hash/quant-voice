//
//  EngineSelector.swift
//  Quant Voice
//
//  Выбор движка распознавания в рантайме (ТЗ 5.3).
//
//  Логика по умолчанию (.automatic): если системный SpeechAnalyzer доступен
//  И его языковой пакет для нужного языка установлен — берём его: он быстрее
//  стартует, ничего не качает и не ест память процесса. Иначе — WhisperKit.
//  Пользователь может жёстко переопределить выбор в настройках.
//
//  Селектор умеет прогреть выбранный движок при старте приложения и
//  переключиться на другой без перезапуска (сначала греем новый,
//  потом выгружаем старый — диктовка не проседает ни на секунду).
//

import Foundation

/// Предпочтение пользователя из настроек. RawValue хранится в UserDefaults
/// слоем настроек — сам селектор ничего не персистит (не его зона).
public enum EnginePreference: String, Codable, Sendable, CaseIterable {
    /// Решает селектор: системный, если может, иначе WhisperKit.
    case automatic
    /// Всегда системный SpeechAnalyzer (если ОС позволяет).
    case system
    /// Всегда WhisperKit.
    case whisperKit
}

/// Движок, который можно безопасно передавать между задачами.
/// Контракт TranscriptionEngine сам по себе не требует Sendable (менять его
/// нельзя), но обе наши реализации Sendable — фиксируем это в типе, иначе
/// строгая конкурентность Swift 6 не даст актору отдавать движок наружу.
public typealias ConcurrentTranscriptionEngine = TranscriptionEngine & Sendable

/// Актор: смена предпочтения и прогрев конкурентны по своей природе
/// (настройки + старт приложения), сериализуем их без ручных замков.
public actor EngineSelector {

    private let systemEngine: SystemSpeechEngine
    private let whisperEngine: WhisperKitEngine
    private let logger: any Logging

    private var preference: EnginePreference

    public init(modelManager: ModelManager,
                whisperProfile: WhisperModelProfile = .standard,
                preference: EnginePreference = .automatic,
                logger: any Logging) {
        self.systemEngine = SystemSpeechEngine(logger: logger)
        self.whisperEngine = WhisperKitEngine(modelManager: modelManager,
                                              profile: whisperProfile,
                                              logger: logger)
        self.preference = preference
        self.logger = logger
    }

    // MARK: - Доступ к движкам (для диагностики и настроек)

    public var system: SystemSpeechEngine { systemEngine }
    public var whisper: WhisperKitEngine { whisperEngine }
    public var currentPreference: EnginePreference { preference }

    // MARK: - Выбор

    /// Какой движок использовать для данного языка прямо сейчас.
    ///
    /// Возвращает движок, НЕ гарантируя его прогретость — прогрев отдельно
    /// (`warmUpSelected` при старте, либо координатор зовёт warmUp сам,
    /// повторный warmUp прогретого движка — бесплатный no-op).
    public func engine(for language: RecognitionLanguage) async -> any ConcurrentTranscriptionEngine {
        switch preference {
        case .system:
            // Жёсткий выбор пользователя уважаем даже там, где он неудачен
            // (язык не установлен) — но честно предупреждаем в логе:
            // ошибки распознавания всплывут наверх с понятным описанием.
            if !SystemSpeechEngine.isRuntimeAvailable {
                logger.warning("Выбор движка: в настройках задан системный, но macOS его не поддерживает — беру WhisperKit")
                return whisperEngine
            }
            return systemEngine

        case .whisperKit:
            return whisperEngine

        case .automatic:
            if await systemSupports(language) {
                return systemEngine
            }
            return whisperEngine
        }
    }

    /// Может ли системный движок обслужить язык прямо сейчас.
    /// .auto системный не умеет по построению (локаль задаётся явно).
    private func systemSupports(_ language: RecognitionLanguage) async -> Bool {
        guard SystemSpeechEngine.isRuntimeAvailable, language != .auto else { return false }
        return await systemEngine.supportedLanguages().contains(language)
    }

    // MARK: - Прогрев при старте

    /// Прогрев на старте приложения. Греем движок, который будет обслуживать
    /// язык по умолчанию; если он не поднялся — греем запасной, чтобы первая
    /// диктовка не ловила холодный старт (ТЗ 6.1).
    ///
    /// Не бросает: неудача прогрева — это состояние («модель не установлена»),
    /// которое UI покажет пользователю, а не авария приложения.
    public func warmUpSelected(defaultLanguage: RecognitionLanguage) async {
        let primary = await engine(for: defaultLanguage)
        do {
            try await primary.warmUp()
            logger.info("Выбор движка: прогрет «\(primary.displayName)»")
            return
        } catch {
            logger.warning("Выбор движка: «\(primary.displayName)» не прогрелся (\(error.localizedDescription)) — пробую запасной")
        }

        // Запасной — «другой из двух». Идентичность движков сравниваем через ===,
        // чтобы не тащить Equatable в протокол ради одной проверки.
        let fallback: any ConcurrentTranscriptionEngine = (primary === whisperEngine) ? systemEngine : whisperEngine
        do {
            try await fallback.warmUp()
            logger.info("Выбор движка: прогрет запасной «\(fallback.displayName)»")
        } catch {
            logger.error("Выбор движка: оба движка недоступны. Системный: нужен macOS 26 и языковой пакет. "
                + "WhisperKit: нужна установленная модель. Ошибка запасного: \(error.localizedDescription)")
        }
    }

    // MARK: - Переключение без перезапуска

    /// Смена предпочтения из настроек. Порядок важен: СНАЧАЛА греем новый
    /// движок, ПОТОМ выгружаем старый — между сменами нет окна, в котором
    /// диктовка не работала бы. Память на время переключения растёт на размер
    /// одной модели — осознанная цена бесшовности.
    public func setPreference(_ newPreference: EnginePreference,
                              defaultLanguage: RecognitionLanguage) async {
        guard newPreference != preference else { return }
        let oldEngine = await engine(for: defaultLanguage)
        preference = newPreference
        let newEngine = await engine(for: defaultLanguage)
        logger.info("Выбор движка: переключение \(oldEngine.displayName) → \(newEngine.displayName)")

        guard newEngine !== oldEngine else { return }

        do {
            try await newEngine.warmUp()
        } catch {
            logger.warning("Выбор движка: новый движок не прогрелся (\(error.localizedDescription)) — старый оставляю в памяти как страховку")
            return
        }
        oldEngine.unload()
    }

    /// Смена профиля модели Whisper (быстрый/обычный/точный) потребовала бы
    /// пересоздания движка — это делает слой приложения, создавая новый
    /// селектор; здесь метода нарочно нет, чтобы не плодить полуживые состояния.

    // MARK: - Сводка для диагностики

    /// Короткая сводка «кто есть кто» — для EngineDiagnostics и меню отладки.
    public func summary(defaultLanguage: RecognitionLanguage) async -> String {
        let systemLangs = await systemEngine.supportedLanguages()
        let whisperLangs = await whisperEngine.supportedLanguages()
        let chosen = await engine(for: defaultLanguage)
        return """
        Предпочтение: \(preference.rawValue)
        Системный движок: \(SystemSpeechEngine.isRuntimeAvailable ? "доступен" : "недоступен (нужен macOS 26)"), установленные языки: [\(systemLangs.map(\.rawValue).joined(separator: ", "))]
        WhisperKit: языки: [\(whisperLangs.map(\.rawValue).joined(separator: ", "))]
        Для языка «\(defaultLanguage.rawValue)» будет выбран: \(chosen.displayName)
        """
    }
}
