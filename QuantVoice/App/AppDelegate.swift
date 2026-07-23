//
//  AppDelegate.swift
//  Quant Voice
//
//  Точка входа приложения. Menu-bar без главного окна (LSUIElement).
//  Здесь же — точка сборки конвейера: единственное место, где конкретные
//  реализации модулей встречаются с координатором.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Уровень задаётся в настройках (M8). Дефолт пока .debug — идёт M4,
    // замеры латентности пишутся уровнем debug (см. Preferences.logLevel).
    private let logger = FileLogger(minimumLevel: Preferences.logLevel())
    private let appState = AppState()

    // Держим сильные ссылки: у menu-bar приложения нет окон,
    // которые удерживали бы граф объектов за нас.
    private var menuBarController: MenuBarController?
    private var overlayPanel: OverlayPanel?
    private var sessionCoordinator: SessionCoordinator?

    // Слой распознавания живёт всю жизнь приложения: модель резидентна,
    // перезагружать её между фразами нельзя (ТЗ 6.1).
    private var modelManager: ModelManager?
    private var engineSelector: EngineSelector?

    /// Словарь терминов (M5, ТЗ 6.6) живёт всю жизнь приложения:
    /// координатор читает его на каждой фразе, окно настроек редактирует.
    private var termsStore: TermsStore?

    /// Монитор хоткеев держим и отдельно от координатора: настройки меняют
    /// его на живую (язык 🌐, выключатель 🌐) без пересборки конвейера.
    private var hotkeyMonitor: HotkeyMonitor?

    /// Окно настроек (веха M8). Создаётся лениво при первом открытии.
    private var settingsController: SettingsWindowController?

    /// Мастер первого запуска (остаток M8). Живёт, пока открыт.
    private var onboardingController: OnboardingWindowController?

    /// Идёт ли сейчас мастер первого запуска. Пока идёт — не показываем
    /// собственные алерты про права: мастер ведёт человека через них сам,
    /// два окна поверх друг друга сбивают с толку.
    private var isOnboarding = false

    /// Значения настроек, с которыми приложение реально запустилось, —
    /// окно настроек сравнивает с ними, чтобы честно показать
    /// «вступит в силу после перезапуска».
    private var launchConfiguration: LaunchConfiguration?

    /// Живёт, только пока ждём права Accessibility. Как получили — гасим.
    private var permissionObserver: AccessibilityPermissionObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        logger.info("Quant Voice \(version) запускается")

        // Менеджер моделей создаём до меню: меню умеет качать модели,
        // а без модели WhisperKit не работает.
        let modelManager = ModelManager(logger: logger)
        self.modelManager = modelManager

        let termsStore = TermsStore(logger: logger)
        self.termsStore = termsStore

        menuBarController = MenuBarController(appState: appState,
                                              logger: logger,
                                              logsDirectory: FileLogger.logsDirectory,
                                              modelManager: modelManager)
        overlayPanel = OverlayPanel(appState: appState)

        sessionCoordinator = assemblePipeline(modelManager: modelManager, termsStore: termsStore)

        // Замыкание, а не прямая ссылка на окно: зависимости окна настроек
        // появляются только после сборки конвейера, окно создаётся лениво.
        menuBarController?.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        menuBarController?.onOpenAbout = { [weak self] in
            self?.showSettings(selecting: .about)
        }

        // Первый запуск: флаг ставим ДО startPipelineWhenPermitted, чтобы тот
        // не показал свой алерт про Accessibility поверх мастера.
        let firstRun = !Preferences.onboardingCompleted()
        isOnboarding = firstRun

        // Конвейер пытаемся поднять всегда: если право уже есть — заведётся сразу,
        // если нет — повесит наблюдателя и оживёт, как только человек выдаст право
        // (в том числе на шаге мастера). Алерт при этом подавлен через isOnboarding.
        startPipelineWhenPermitted()

        if firstRun {
            showOnboarding()
        } else {
            ensureMicrophonePermission()
        }
        runDiagnostics()
    }

    /// Мастер первого запуска. Ведёт через модель и два разрешения; на выходе
    /// снимает флаг онбординга и — если модель докачали сейчас — перезапускает
    /// приложение, чтобы движок загрузил её в память на старте.
    private func showOnboarding() {
        guard let modelManager else {
            // Без менеджера моделей мастер бессмысленен; помечаем пройденным,
            // чтобы не застрять на нём при каждом запуске.
            Preferences.setOnboardingCompleted(true)
            isOnboarding = false
            return
        }
        let model = OnboardingModel(modelManager: modelManager,
                                    appState: appState,
                                    logger: logger)
        let controller = OnboardingWindowController(model: model)
        controller.onFinished = { [weak self] shouldRelaunch in
            guard let self else { return }
            Preferences.setOnboardingCompleted(true)
            self.isOnboarding = false
            if shouldRelaunch {
                self.logger.info("Онбординг: модель докачана, перезапускаю для её загрузки")
                self.relaunchApp()
                return
            }
            // Освобождаем контроллер на следующем витке цикла: сейчас мы можем
            // быть внутри windowWillClose самого окна, и снести его синхронно
            // значит освободить окно посреди его же колбэка.
            // Без перезапуска доделывать нечего: конвейер уже ждёт право по
            // наблюдателю, микрофон запрошен на шаге мастера.
            Task { @MainActor in self.onboardingController = nil }
        }
        onboardingController = controller
        controller.show()
    }

    /// Перезапуск приложения (та же схема, что у кнопки в настройках): пауза,
    /// чтобы старый процесс успел умереть и не было двух перехватов сразу.
    private func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n '\(bundleURL.path)'"]
        } else {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            process.arguments = ["-c", "sleep 0.5; '\(executable)' >/dev/null 2>&1 &"]
        }
        do {
            try process.run()
        } catch {
            logger.error("Онбординг: перезапуск не удался: \(error.localizedDescription). Перезапусти вручную.")
            return
        }
        NSApp.terminate(nil)
    }

    /// Спрашивает доступ к микрофону при старте, а не при первой диктовке.
    ///
    /// Почему при старте: пока приложение ни разу не запросило доступ, macOS
    /// вообще не показывает его в списке «Конфиденциальность → Микрофон» —
    /// выдать разрешение руками невозможно, галки просто нет. Человек видит
    /// «нет разрешения на микрофон» и не может ничего сделать. Единственный
    /// способ появиться в списке — вызвать `AVCaptureDevice.requestAccess`.
    ///
    /// Отказ не блокирует приложение: меню, загрузка моделей и настройки
    /// работают и без микрофона — диктовка просто не стартует.
    private func ensureMicrophonePermission() {
        let status = AudioCapture.permissionStatus()
        appState.microphonePermission = status

        switch status {
        case .granted:
            logger.info("Микрофон: доступ есть")

        case .notDetermined:
            logger.info("Микрофон: доступ не запрашивался — показываю системный диалог")
            Task { @MainActor in
                let granted = await AudioCapture.requestPermission()
                self.appState.microphonePermission = granted ? .granted : .denied
                self.logger.info("Микрофон: пользователь \(granted ? "разрешил" : "отказал")")
                if !granted { self.promptForMicrophone() }
            }

        case .denied:
            logger.error("Микрофон: доступ запрещён — диктовка работать не будет")
            promptForMicrophone()
        }
    }

    /// Объясняет, почему диктовка молчит, и ведёт в нужный раздел настроек.
    ///
    /// Ad-hoc подпись меняется при каждой пересборке, поэтому запись в TCC
    /// сбрасывается и разрешение придётся выдавать заново — это ожидаемо
    /// на время разработки и уйдёт, когда подпись станет постоянной.
    private func promptForMicrophone() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Нужен доступ к микрофону"
        alert.informativeText = """
        Без него Quant Voice не слышит речь и диктовка не работает.

        Системные настройки → Конфиденциальность и безопасность → Микрофон → включить QuantVoice.

        Звук обрабатывается на этом Mac и никуда не отправляется.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            // Каскад URL общий для всех разделов приватности — PrivacySettingsPane.
            PrivacySettingsPane.microphone.open()
        }
    }

    /// Пытается поднять конвейер, а если права Accessibility ещё нет —
    /// ждёт, пока пользователь его выдаст, и поднимает сам.
    ///
    /// Без этого приходилось перезапускать приложение после выдачи права:
    /// человек ставит галку в системных настройках, возвращается — и ничего
    /// не работает, потому что попытка была одна, при старте.
    private func startPipelineWhenPermitted() {
        guard let sessionCoordinator else { return }

        do {
            try sessionCoordinator.start()
            appState.accessibilityPermission = .granted
            logger.info("Конвейер диктовки запущен")
            permissionObserver?.stop()
            permissionObserver = nil
        } catch {
            appState.accessibilityPermission = .denied
            logger.error("Конвейер не запустился: \(error.localizedDescription)")

            guard permissionObserver == nil else { return }
            logger.info("Жду выдачи права Accessibility — конвейер поднимется сам")

            // Показываем это ОДИН раз и явно: молчаливая запись в лог означала бы,
            // что человек сидит и гадает, почему хоткей не срабатывает.
            // Во время мастера первого запуска молчим — он ведёт через это право сам.
            if !isOnboarding {
                promptForAccessibility()
            }

            let observer = AccessibilityPermissionObserver()
            observer.onChange = { [weak self] isGranted in
                guard isGranted else { return }
                self?.logger.info("Право Accessibility выдано — поднимаю конвейер")
                self?.startPipelineWhenPermitted()
            }
            observer.start()
            permissionObserver = observer
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionCoordinator?.shutdown()
        logger.info("Quant Voice завершается")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Точка сборки конвейера

    /// Единственное место, где конкретные реализации протоколов контракта
    /// (AudioCapturing, HotkeyMonitoring, TranscriptionEngine, TextInserting,
    /// TextRefining) встречаются друг с другом. Модули пишутся параллельно
    /// отдельными исполнителями; по мере готовности они подключаются ЗДЕСЬ —
    /// и больше нигде: координатор знает только протоколы.
    ///
    /// Возвращает nil только если собрать конвейер физически невозможно.
    private func assemblePipeline(modelManager: ModelManager,
                                  termsStore: TermsStore) -> SessionCoordinator? {
        // Профиль модели читается из настроек, а не зашит: на M4 нужно сравнить
        // `fast` и `standard` замерами на живой машине, а пересборка ради
        // переключения профиля растянула бы каждый замер на минуты.
        let profile = Preferences.modelProfile(logger: logger)
        let defaultLanguage = Preferences.defaultLanguage(logger: logger)
        let enginePreference = Preferences.enginePreference(logger: logger)
        logger.info("Настройки старта: профиль \(profile.rawValue), язык \(defaultLanguage.rawValue), движок \(enginePreference.rawValue)")

        // Фиксируем, с чем реально запустились: defaults могут поменяться
        // в любой момент, а конвейер продолжит работать на этих значениях.
        launchConfiguration = LaunchConfiguration(modelProfile: profile,
                                                  defaultLanguage: defaultLanguage,
                                                  logLevel: Preferences.logLevel(logger: logger))

        let selector = EngineSelector(modelManager: modelManager,
                                      whisperProfile: profile,
                                      preference: enginePreference,
                                      logger: logger)
        self.engineSelector = selector

        // Адаптер прячет акторную природу селектора за синхронным протоколом
        // и позволяет менять движок на лету, не пересобирая конвейер.
        let engine = AdaptiveTranscriptionEngine(selector: selector,
                                                 defaultLanguage: defaultLanguage,
                                                 logger: logger)

        let monitor = HotkeyMonitor(logger: logger)
        monitor.globeLanguage = defaultLanguage
        monitor.globeHoldEnabled = Preferences.globeHoldEnabled()
        self.hotkeyMonitor = monitor

        return SessionCoordinator(audio: AudioCapture(),
                                  hotkeys: monitor,
                                  engine: engine,
                                  inserter: TextInserter(logger: logger),
                                  refiner: DeterministicRefiner(logger: logger),
                                  terms: termsStore,
                                  appState: appState,
                                  logger: logger)
    }

    // MARK: - Окно настроек

    /// Лениво: зависимости окна (менеджер моделей, селектор, монитор)
    /// существуют только после сборки конвейера, а большинству запусков
    /// окно вообще не понадобится.
    private func showSettings(selecting tab: SettingsTab? = nil) {
        if settingsController == nil {
            guard let modelManager, let engineSelector, let termsStore, let launchConfiguration else {
                logger.error("Настройки: конвейер ещё не собран, окно открыть нечем")
                return
            }
            let model = SettingsModel(modelManager: modelManager,
                                      engineSelector: engineSelector,
                                      hotkeyMonitor: hotkeyMonitor,
                                      termsStore: termsStore,
                                      launch: launchConfiguration,
                                      logger: logger)
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.show(selecting: tab)
    }

    /// Объясняет, почему ничего не работает, и открывает нужный раздел настроек.
    ///
    /// Системный диалог `AXIsProcessTrustedWithOptions` показывается один раз
    /// за жизнь записи в TCC — после пересборки приложение считается новым,
    /// и диалог приходит снова. Поэтому дублируем его собственным окном
    /// с кнопкой: так человек точно поймёт, что от него нужно.
    private func promptForAccessibility() {
        AccessibilityPermission.requestWithSystemPrompt()

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Нужно разрешение «Универсальный доступ»"
        alert.informativeText = """
        Без него Quant Voice не видит нажатие хоткея и не может вставить текст.

        Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включить QuantVoice.

        Приложение само подхватит разрешение, перезапускать не нужно.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
    }

    // MARK: - Диагностика окружения

    /// Одноразовый прогон, который отвечает на открытые вопросы проекта:
    /// какие движки доступны на этой машине, какие языки они знают
    /// (в частности — есть ли русский в системном движке Apple, ТЗ 5.3),
    /// какие модели уже лежат на диске.
    ///
    /// Результат уходит в лог. Это первое, что нужно прочитать после
    /// первой успешной сборки.
    private func runDiagnostics() {
        guard let modelManager, let engineSelector else { return }
        let diagnostics = EngineDiagnostics(modelManager: modelManager,
                                            selector: engineSelector,
                                            logger: logger)
        let language = launchConfiguration?.defaultLanguage ?? .russian
        Task.detached(priority: .utility) {
            _ = await diagnostics.run(defaultLanguage: language)
        }
    }
}
