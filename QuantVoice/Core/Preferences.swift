//
//  Preferences.swift
//  Quant Voice
//
//  Настройки, которые нужно менять БЕЗ пересборки приложения.
//
//  Окно настроек появится на M8, а замеры вехи M4 нужны сейчас: чтобы сравнить
//  профили моделей на живой машине, профиль должен переключаться снаружи.
//  UserDefaults решает это одной командой в терминале:
//
//      defaults write com.quant.voice modelProfile fast
//
//  Когда появится настоящий UI, он будет писать в эти же ключи — значения
//  переживут появление окна, а этот файл станет его моделью данных.
//

import Foundation

public enum Preferences {

    // UserDefaults берём по месту, а не храним в static-свойстве: `UserDefaults`
    // не Sendable, и глобальная константа с ним не проходит проверку строгой
    // конкурентности Swift 6. Обращение дешёвое — `.standard` кэширован системой.

    // MARK: Профиль модели

    private static let modelProfileKey = "modelProfile"

    /// Профиль модели Whisper. Дефолт, если пользователь не выбирал сам, —
    /// по объёму памяти машины (см. `recommendedDefaultProfile`): на слабых
    /// large-v3-turbo прогревается минутами и давит память, там берём small.
    ///
    /// Неизвестное значение НЕ роняет приложение и не молчит: логируется
    /// и подменяется дефолтом. Опечатка в терминале не должна выглядеть
    /// как «настройка не сработала».
    public static func modelProfile(logger: (any Logging)? = nil) -> WhisperModelProfile {
        guard let raw = UserDefaults.standard.string(forKey: modelProfileKey) else {
            return recommendedDefaultProfile()
        }
        guard let profile = WhisperModelProfile(rawValue: raw) else {
            let fallback = recommendedDefaultProfile()
            logger?.warning("Настройки: неизвестный профиль модели «\(raw)», беру \(fallback.rawValue). Допустимые: \(WhisperModelProfile.allCases.map(\.rawValue).joined(separator: ", "))")
            return fallback
        }
        return profile
    }

    /// Рекомендованный профиль под конкретную машину, когда пользователь ещё
    /// не выбрал сам. Порог по памяти: ≤ ~8 ГБ ОЗУ — `fast` (small), там
    /// large-v3-turbo прогревается мучительно долго и жрёт почти всю память
    /// (баг «бесконечное Готовлю модель» на 8 ГБ, 24.07.2026). Больше — `standard`.
    /// Мастер первого запуска берёт это же значение и преселектит модель под машину.
    public static func recommendedDefaultProfile() -> WhisperModelProfile {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return gib <= 8.5 ? .fast : .standard
    }

    public static func setModelProfile(_ profile: WhisperModelProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: modelProfileKey)
    }

    // MARK: Язык по умолчанию

    private static let defaultLanguageKey = "defaultLanguage"

    /// Язык по умолчанию: на нём работает удержание 🌐 и прогрев движка
    /// при старте. Язык конкретной диктовки всё равно фиксируется хоткеем
    /// (ТЗ 6.5) — эта настройка его не перебивает.
    public static func defaultLanguage(logger: (any Logging)? = nil) -> RecognitionLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultLanguageKey) else {
            return .russian
        }
        guard let language = RecognitionLanguage(rawValue: raw) else {
            logger?.warning("Настройки: неизвестный язык «\(raw)», беру ru. Допустимые: \(RecognitionLanguage.allCases.map(\.rawValue).joined(separator: ", "))")
            return .russian
        }
        return language
    }

    public static func setDefaultLanguage(_ language: RecognitionLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultLanguageKey)
    }

    // MARK: Предпочтение движка

    private static let enginePreferenceKey = "enginePreference"

    public static func enginePreference(logger: (any Logging)? = nil) -> EnginePreference {
        guard let raw = UserDefaults.standard.string(forKey: enginePreferenceKey) else {
            return .automatic
        }
        guard let preference = EnginePreference(rawValue: raw) else {
            logger?.warning("Настройки: неизвестное предпочтение движка «\(raw)», беру automatic. Допустимые: \(EnginePreference.allCases.map(\.rawValue).joined(separator: ", "))")
            return .automatic
        }
        return preference
    }

    public static func setEnginePreference(_ preference: EnginePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: enginePreferenceKey)
    }

    // MARK: Диктовка по удержанию 🌐

    private static let globeHoldEnabledKey = "globeHoldEnabled"

    /// Дефолт — включено. `bool(forKey:)` не годится: для отсутствующего
    /// ключа он молча отдаёт false, и дефолт «включено» был бы невозможен.
    public static func globeHoldEnabled() -> Bool {
        UserDefaults.standard.object(forKey: globeHoldEnabledKey) as? Bool ?? true
    }

    public static func setGlobeHoldEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: globeHoldEnabledKey)
    }

    // MARK: Подсказка модели терминами (prompt-biasing)

    private static let termsPromptEnabledKey = "termsPromptEnabled"

    /// Первый слой словаря терминов — список терминов в промпте модели.
    /// Вынесен в выключатель, потому что стоит дорого: замер 19.07.2026 показал
    /// +900 мс к распознаванию на словаре из 11 терминов (каждый токен промпта
    /// декодируется наравне с ответом). Второй слой — фонетические замены —
    /// работает независимо и бесплатно, поэтому выключение промпта не лишает
    /// пользователя починки терминов, а лишь снимает попытку предупредить модель.
    ///
    /// Дефолт — включено: точность терминов заявлена главным дифференциатором,
    /// и решение «скорость против точности» Алексей принимает по опыту беты.
    public static func termsPromptEnabled() -> Bool {
        UserDefaults.standard.object(forKey: termsPromptEnabledKey) as? Bool ?? true
    }

    public static func setTermsPromptEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: termsPromptEnabledKey)
    }

    // MARK: Постобработка текста

    private static let textRefinementEnabledKey = "textRefinementEnabled"

    /// Детерминированная постобработка (ТЗ 5.7, уровень 3): точка в конце
    /// фразы, заглавная после точки, пробелы, звуковые филлеры.
    ///
    /// Дефолт — включено: повод прямой, из живой диктовки 20.07.2026 (модель
    /// не ставит точку в конце). Стоит единицы миллисекунд, сети не требует.
    /// Выключатель нужен тем, кто диктует куски внутрь готового текста —
    /// там автоматическая точка и заглавная мешают.
    public static func textRefinementEnabled() -> Bool {
        UserDefaults.standard.object(forKey: textRefinementEnabledKey) as? Bool ?? true
    }

    public static func setTextRefinementEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: textRefinementEnabledKey)
    }

    // MARK: Мастер первого запуска

    private static let onboardingCompletedKey = "onboardingCompleted"

    /// Пройден ли мастер первого запуска. Дефолт — false: свежая установка
    /// показывает мастер один раз. Флаг ставится, когда человек закрыл мастер
    /// (прошёл до конца или нажал «Позже») — второй раз не навязываемся,
    /// всё то же есть в настройках и меню.
    public static func onboardingCompleted() -> Bool {
        UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    }

    public static func setOnboardingCompleted(_ completed: Bool) {
        UserDefaults.standard.set(completed, forKey: onboardingCompletedKey)
    }

    // MARK: Уровень логирования

    private static let logLevelKey = "logLevel"

    /// Имена уровней: в defaults храним строку, а не rawValue —
    /// `defaults write com.quant.voice logLevel info` читается человеком.
    private static let logLevelNames: [String: LogLevel] = [
        "debug": .debug, "info": .info, "warning": .warning, "error": .error,
    ]

    /// Дефолт — .debug, а не «info в релизе»: идёт веха M4, замеры латентности
    /// пишутся уровнем debug, и потерять их из-за смены уровня нельзя.
    /// После закрытия M4 дефолт можно опустить до nil — FileLogger сам
    /// выберет info в релизной сборке.
    static func logLevel(logger: (any Logging)? = nil) -> LogLevel {
        guard let raw = UserDefaults.standard.string(forKey: logLevelKey) else {
            return .debug
        }
        guard let level = logLevelNames[raw] else {
            logger?.warning("Настройки: неизвестный уровень логирования «\(raw)», беру debug. Допустимые: \(logLevelNames.keys.sorted().joined(separator: ", "))")
            return .debug
        }
        return level
    }

    static func setLogLevel(_ level: LogLevel) {
        let name = logLevelNames.first { $0.value == level }?.key ?? "debug"
        UserDefaults.standard.set(name, forKey: logLevelKey)
    }
}
