//
//  SettingsModel.swift
//  Quant Voice
//
//  Модель окна настроек (веха M8): единственное место, где UI настроек
//  встречается с Preferences и живыми подсистемами — моделями, движками,
//  монитором хоткеев.
//
//  Правило применения изменений — честность вместо магии:
//  • что безопасно применить на живом приложении (предпочтение движка,
//    язык и выключатель 🌐) — применяется сразу;
//  • что требует пересоздания конвейера (профиль модели, уровень логов,
//    язык прогрева) — применяется при следующем запуске, а окно прямо
//    говорит об этом и предлагает кнопку перезапуска. Профиль зашит
//    в WhisperKitEngine как `let`, и селектор сознательно не умеет менять
//    его на лету (см. комментарий в EngineSelector) — «бесшовная» смена
//    означала бы пересборку всего конвейера с остановкой перехвата,
//    это несоразмерный риск для настройки, которую меняют раз в жизни.
//

import AppKit
import Observation

/// Значения, с которыми приложение реально запустилось. Нужны, чтобы отличать
/// «настройка изменена, но ещё не действует» от «всё уже применено»:
/// сравнение с UserDefaults этого не даст — defaults меняются мгновенно.
struct LaunchConfiguration: Sendable {
    let modelProfile: WhisperModelProfile
    let defaultLanguage: RecognitionLanguage
    let logLevel: LogLevel
}

@MainActor
@Observable
final class SettingsModel {

    // MARK: - Зависимости

    // `let`-зависимости макрос @Observable не отслеживает — и не должен:
    // это каналы к живым подсистемам, а не состояние UI.
    private let modelManager: ModelManager
    private let engineSelector: EngineSelector
    private let hotkeyMonitor: HotkeyMonitor?
    private let logger: any Logging
    private let launch: LaunchConfiguration

    /// Словарь терминов (M5). Не private: вкладке «Термины» нужен прямой
    /// доступ — хранилище само наблюдаемое, дублировать его состояние
    /// в модели значило бы завести второй источник правды.
    let termsStore: TermsStore

    // MARK: - Настройки (текущие значения)

    // Персистентность — в *Changed-методах, которые вызывает представление
    // через onChange. Логика «в didSet» была бы короче, но поведение
    // property observers внутри макроса @Observable — тонкий лёд, а onChange
    // в SwiftUI — проторённая дорога.
    /// Активная вкладка окна. Меняется извне (пункт меню «О программе»),
    /// поэтому живёт в модели, а не в @State представления.
    var selectedTab: SettingsTab = .recognition

    var selectedProfile: WhisperModelProfile
    var enginePreference: EnginePreference
    var defaultLanguage: RecognitionLanguage
    var logLevel: LogLevel
    var globeHoldEnabled: Bool
    var textRefinementEnabled: Bool

    // MARK: - Модели на диске

    /// Вариант → фактический размер на диске. Отсутствие ключа = не установлена.
    private(set) var installedSizes: [String: Int64] = [:]
    /// Вариант, который качается прямо сейчас. nil — загрузки нет.
    private(set) var downloadingVariant: String?
    var downloadProgress: Double = 0

    // MARK: - Права

    private(set) var microphoneStatus: PermissionStatus = .notDetermined
    private(set) var accessibilityStatus: PermissionStatus = .denied

    // MARK: - Хоткеи

    /// Действующие привязки — читаются из живого монитора, а не из констант:
    /// когда появится рекордер сочетаний, окно не придётся переделывать.
    private(set) var assignments: [HotkeyAssignment]

    // MARK: - Служебное состояние UI

    var showError = false
    var errorMessage = ""
    var showRemoveConfirmation = false
    var pendingRemovalVariant: String?

    // MARK: - Инициализация

    init(modelManager: ModelManager,
         engineSelector: EngineSelector,
         hotkeyMonitor: HotkeyMonitor?,
         termsStore: TermsStore,
         launch: LaunchConfiguration,
         logger: any Logging) {
        self.modelManager = modelManager
        self.engineSelector = engineSelector
        self.hotkeyMonitor = hotkeyMonitor
        self.termsStore = termsStore
        self.launch = launch
        self.logger = logger

        selectedProfile = Preferences.modelProfile(logger: logger)
        enginePreference = Preferences.enginePreference(logger: logger)
        defaultLanguage = Preferences.defaultLanguage(logger: logger)
        logLevel = Preferences.logLevel(logger: logger)
        globeHoldEnabled = Preferences.globeHoldEnabled()
        textRefinementEnabled = Preferences.textRefinementEnabled()
        assignments = hotkeyMonitor?.assignments ?? HotkeyAssignment.defaults
    }

    // MARK: - «Вступит в силу после перезапуска»

    /// Сравниваем с конфигурацией СТАРТА, а не с defaults: defaults уже
    /// перезаписаны, а конвейер всё ещё работает на старых значениях.
    var needsRestart: Bool {
        selectedProfile != launch.modelProfile
            || defaultLanguage != launch.defaultLanguage
            || logLevel != launch.logLevel
    }

    // MARK: - Применение изменений

    func profileChanged() {
        Preferences.setModelProfile(selectedProfile)
        logger.info("Настройки: профиль модели → \(selectedProfile.rawValue) (вступит в силу после перезапуска)")
    }

    func enginePreferenceChanged() {
        Preferences.setEnginePreference(enginePreference)
        logger.info("Настройки: предпочтение движка → \(enginePreference.rawValue)")
        // Селектор умеет переключаться на живом приложении: сначала греет
        // новый движок, потом выгружает старый — перезапуск не нужен.
        let selector = engineSelector
        let preference = enginePreference
        let language = defaultLanguage
        Task {
            await selector.setPreference(preference, defaultLanguage: language)
        }
    }

    func defaultLanguageChanged() {
        Preferences.setDefaultLanguage(defaultLanguage)
        // Язык удержания 🌐 монитор принимает на лету; язык прогрева
        // при старте зашит в конвейер — он обновится после перезапуска.
        hotkeyMonitor?.globeLanguage = defaultLanguage
        logger.info("Настройки: язык по умолчанию → \(defaultLanguage.rawValue)")
    }

    func logLevelChanged() {
        Preferences.setLogLevel(logLevel)
        logger.info("Настройки: уровень логирования → \(logLevel.label.trimmingCharacters(in: .whitespaces)) (вступит в силу после перезапуска)")
    }

    func globeHoldChanged() {
        Preferences.setGlobeHoldEnabled(globeHoldEnabled)
        hotkeyMonitor?.globeHoldEnabled = globeHoldEnabled
        logger.info("Настройки: диктовка по удержанию 🌐 \(globeHoldEnabled ? "включена" : "выключена")")
    }

    func textRefinementChanged() {
        Preferences.setTextRefinementEnabled(textRefinementEnabled)
        logger.info("Настройки: базовое причёсывание \(textRefinementEnabled ? "включено" : "выключено")")
    }

    // MARK: - Модели: что на диске

    func isInstalled(_ variant: String) -> Bool {
        installedSizes[variant] != nil
    }

    /// Подпись под пунктом профиля: пояснение из каталога + состояние на диске.
    func statusLine(for descriptor: WhisperModelDescriptor) -> String {
        if downloadingVariant == descriptor.variant {
            return "\(descriptor.details) Загружается…"
        }
        if let size = installedSizes[descriptor.variant] {
            return "\(descriptor.details) Установлена, \(Self.megabytes(size)) на диске."
        }
        return "\(descriptor.details) Не установлена, загрузка ~\(descriptor.approximateSizeMB) МБ."
    }

    /// Пересканировать диск. Зовётся при показе окна и после загрузки/удаления.
    func refreshModels() {
        Task { @MainActor in
            let models = await self.modelManager.installedModels()
            // uniquingKeysWith: один и тот же вариант может лежать дважды
            // (ручная установка в корень + загрузка Hub'ом глубже) — падать
            // из-за этого нельзя, берём первый найденный.
            self.installedSizes = Dictionary(models.map { ($0.variant, $0.sizeOnDisk) },
                                             uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Модели: загрузка и удаление

    func download(_ descriptor: WhisperModelDescriptor) {
        guard downloadingVariant == nil else { return }
        downloadingVariant = descriptor.variant
        downloadProgress = 0
        logger.info("Настройки: пользователь запросил загрузку «\(descriptor.variant)»")

        Task { @MainActor in
            defer {
                self.downloadingVariant = nil
                self.refreshModels()
            }
            do {
                _ = try await self.modelManager.download(descriptor) { [weak self] fraction in
                    // Колбэк @Sendable и приходит не с главного потока —
                    // прыгаем на главный актор, как в MenuBarController.
                    Task { @MainActor in
                        self?.downloadProgress = fraction
                    }
                }
                // Если скачали модель активного профиля — перезапуск не нужен:
                // AdaptiveTranscriptionEngine сам прогреет движок перед фразой.
            } catch {
                self.presentError("Не удалось загрузить модель: \(error.localizedDescription)")
            }
        }
    }

    /// Удаление, подтверждённое диалогом. Сам диалог — забота представления.
    func removeConfirmed() {
        guard let variant = pendingRemovalVariant else { return }
        pendingRemovalVariant = nil
        logger.info("Настройки: пользователь удаляет модель «\(variant)»")
        Task { @MainActor in
            do {
                try await self.modelManager.remove(variant)
            } catch {
                self.presentError("Не удалось удалить модель: \(error.localizedDescription)")
            }
            self.refreshModels()
        }
    }

    // MARK: - Права

    func refreshPermissions() {
        microphoneStatus = AudioCapture.permissionStatus()
        accessibilityStatus = AccessibilityPermission.status
    }

    func requestMicrophoneAccess() {
        Task { @MainActor in
            _ = await AudioCapture.requestPermission()
            self.refreshPermissions()
        }
    }

    // MARK: - Перезапуск

    /// Перезапуск по кнопке. Пауза в sh нужна, чтобы старый процесс успел
    /// умереть: `open -n` без неё поднял бы второй экземпляр рядом с ещё
    /// живым первым — два перехвата клавиатуры одновременно.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n '\(bundleURL.path)'"]
        } else {
            // Голый бинарь (запуск без .app при отладке) — стартуем его же.
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            process.arguments = ["-c", "sleep 0.5; '\(executable)' >/dev/null 2>&1 &"]
        }

        do {
            try process.run()
        } catch {
            presentError("Не удалось перезапустить: \(error.localizedDescription). Перезапусти приложение вручную.")
            return
        }
        logger.info("Настройки: перезапуск для применения изменений")
        NSApp.terminate(nil)
    }

    // MARK: - Служебное

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f МБ", Double(bytes) / 1_048_576)
    }
}
