//
//  SessionCoordinator.swift
//  Quant Voice
//
//  Центральный класс: оркестрирует полный цикл диктовки
//  хоткей → запись → оверлей → распознавание → постобработка → вставка.
//
//  Знает ТОЛЬКО протоколы из Contracts.swift. Конкретные реализации
//  (аудио, хоткеи, движок, вставка, постобработка) инжектятся снаружи —
//  их пишут отдельные модули, координатор их имён не знает.
//

import Foundation

/// Коробка, переносящая не-Sendable значение через границу изоляции.
///
/// Зачем: протоколы контракта сознательно не Sendable — контракт не навязывает
/// реализациям модель изоляции. Но `transcribe`/`refine` асинхронные, и вызов
/// с главного актора уходит на общий пул. Коробка объявляет содержимое
/// потокобезопасным «под ответственность реализации»: движок и постобработчик
/// по контракту обязаны выдерживать вызов из любого исполнителя.
struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Координатор сессии диктовки.
///
/// Живёт на главном акторе: события хоткеев приходят на главный поток,
/// состояние UI (`AppState`) главноакторное, вставка (`TextInserting`)
/// по контракту `@MainActor`. Тяжёлые шаги (распознавание, постобработка)
/// уходят с главного актора через nonisolated-мостики ниже — интерфейс
/// не подмерзает, пока модель декодирует.
@MainActor
final class SessionCoordinator {

    // MARK: - Зависимости (только протоколы контракта)

    private let audio: any AudioCapturing
    private let hotkeys: any HotkeyMonitoring
    private let engine: UnsafeSendableBox<any TranscriptionEngine>
    private let inserter: any TextInserting
    /// Постобработка опциональна: nil — шаг просто пропускается (ТЗ 5.7).
    private let refiner: UnsafeSendableBox<any TextRefining>?
    /// Слой терминов (ТЗ 6.6) тоже опционален: nil — диктовка работает без него.
    /// Протокол @MainActor и операции дешёвые — коробка-мостик не нужна.
    private let terms: (any TermsApplying)?
    private let appState: AppState
    private let logger: any Logging

    // MARK: - Состояние сессии

    /// Язык текущей сессии — фиксируется хоткеем при старте (ТЗ 6.5).
    private var sessionLanguage: RecognitionLanguage = .russian
    private var pipelineTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    /// Записи короче этого — случайные касания хоткея, не диктовка.
    /// Гоняем их в модель незачем: только время и галлюцинации на тишине.
    private static let minimumAudioDuration: TimeInterval = 0.25

    // MARK: - Инициализация

    init(audio: any AudioCapturing,
         hotkeys: any HotkeyMonitoring,
         engine: any TranscriptionEngine,
         inserter: any TextInserting,
         refiner: (any TextRefining)?,
         terms: (any TermsApplying)?,
         appState: AppState,
         logger: any Logging) {
        self.audio = audio
        self.hotkeys = hotkeys
        self.engine = UnsafeSendableBox(engine)
        self.inserter = inserter
        self.refiner = refiner.map { UnsafeSendableBox($0) }
        self.terms = terms
        self.appState = appState
        self.logger = logger
    }

    // MARK: - Жизненный цикл

    /// Запускает мониторинг хоткеев и прогревает движок.
    /// Бросает, если хоткеи не стартовали (обычно — нет права Accessibility).
    func start() throws {
        // Уровень микрофона течёт в AppState колбэком — оверлей ничего не опрашивает.
        // Контракт обещает главный поток; assumeIsolated проверит это в рантайме.
        let appState = self.appState
        audio.onLevelChange = { level in
            MainActor.assumeIsolated {
                appState.microphoneLevel = level
            }
        }

        hotkeys.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }

        try hotkeys.start()

        appState.engineName = engine.value.displayName
        logger.info("Координатор запущен, движок: \(engine.value.displayName)")

        // Прогрев — один раз при старте, модель дальше живёт резидентно (ТЗ 6.1).
        // Задача сохраняется: конвейер перед первой фразой дождётся её конца.
        let engineBox = engine
        let logger = self.logger
        warmUpTask = Task {
            do {
                let started = Date()
                try await Self.warmUp(engineBox)
                logger.info(String(format: "Движок прогрет за %.1f с", Date().timeIntervalSince(started)))
            } catch {
                // Не фатально на старте: transcribe честно бросит engineNotReady,
                // и пользователь увидит ошибку в оверлее в момент диктовки.
                logger.error("Прогрев движка не удался: \(error.localizedDescription)")
            }
        }
    }

    /// Останавливает всё. Вызывается при завершении приложения.
    func shutdown() {
        pipelineTask?.cancel()
        warmUpTask?.cancel()
        idleTask?.cancel()
        audio.cancel()
        hotkeys.endEscapeCapture()
        hotkeys.stop()
        engine.value.unload()
        logger.info("Координатор остановлен")
    }

    // MARK: - События хоткеев

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .startCapture(let mode, let language):
            beginSession(mode: mode, language: language)
        case .finishCapture:
            finishSession()
        case .cancel:
            cancelSession()
        }
    }

    // MARK: - Шаги цикла

    private func beginSession(mode: CaptureMode, language: RecognitionLanguage) {
        // Повторный хоткей посреди активной сессии игнорируем: параллельных
        // сессий не бывает, а «оборвать и начать заново» — неожиданное поведение.
        guard !appState.isSessionActive else {
            logger.debug("Хоткей во время активной сессии — игнорирую")
            return
        }
        // Если предыдущая сессия ещё показывает терминальное состояние —
        // обрываем показ, начинается новая.
        idleTask?.cancel()
        pipelineTask?.cancel()

        sessionLanguage = language

        do {
            try audio.start()
        } catch {
            logger.error("Микрофон не стартовал: \(error.localizedDescription)")
            concludeSession(with: .failed("Не удалось включить микрофон. Проверь разрешение в Настройках → Конфиденциальность"),
                            idleAfter: 3.0)
            return
        }

        // Esc перехватываем только на время сессии (контракт HotkeyMonitoring),
        // чтобы не ломать Esc в остальной системе.
        hotkeys.beginEscapeCapture()
        appState.sessionState = .listening

        let modeName: String
        switch mode {
        case .hold:   modeName = "удержание"
        case .toggle: modeName = "переключатель"
        }
        logger.info("Запись началась: режим \(modeName), язык \(language.rawValue)")
    }

    private func finishSession() {
        guard appState.sessionState == .listening else { return }

        // Точка отсчёта главной метрики (ТЗ 9.1): отпускание клавиши → текст в поле.
        let releasedAt = Date()

        let segment = audio.stop()
        appState.microphoneLevel = 0

        guard let segment, segment.duration >= Self.minimumAudioDuration else {
            logger.info("Запись пустая или слишком короткая — считаю отменой")
            concludeSession(with: .cancelled, idleAfter: 0.8)
            return
        }

        // Если движок ещё греется, показываем «Готовлю модель…», а не «Распознаю…»:
        // первый холодный прогрев занимает минуты, и на «Распознаю…» это выглядит
        // как зависание — человек закрывает приложение, не дождавшись (баг Ани, 23.07).
        appState.sessionState = engine.value.isReady ? .transcribing : .preparing
        logger.info(String(format: "Запись остановлена: %.2f с аудио", segment.duration))

        pipelineTask = Task { [weak self] in
            await self?.runPipeline(segment: segment, releasedAt: releasedAt)
        }
    }

    private func cancelSession() {
        guard appState.isSessionActive else { return }
        pipelineTask?.cancel()
        pipelineTask = nil
        audio.cancel()
        logger.info("Сессия отменена (Esc)")
        concludeSession(with: .cancelled, idleAfter: 0.8)
    }

    /// Распознавание → постобработка → вставка. Выполняется на главном акторе,
    /// но каждый тяжёлый шаг — await с уходом на общий пул, UI живёт.
    private func runPipeline(segment: AudioSegment, releasedAt: Date) async {
        var metrics = SessionMetrics()
        metrics.audioDuration = segment.duration

        do {
            // Первая фраза после старта могла прийти раньше конца прогрева — ждём его,
            // а не бросаем engineNotReady пользователю в лицо. Пока ждём — на экране
            // «Готовлю модель…» (выставлено в finishSession).
            await warmUpTask?.value
            try Task.checkCancellation()
            // Прогрев позади — с этого момента идёт собственно распознавание.
            if appState.sessionState == .preparing {
                appState.sessionState = .transcribing
            }

            // 1. Распознавание. Промпт из словаря терминов (ТЗ 6.6, уровень 1):
            // без него модель с зафиксированным русским честно транслитерирует
            // английские бренды на слух («клоут коворг» вместо «Claude Cowork»).
            // Промпт можно выключить в настройках: он стоит ~25 мс за токен,
            // а фонетические замены ниже чинят термины и без него.
            let termsPrompt = Preferences.termsPromptEnabled()
                ? terms?.transcriptionPrompt(for: sessionLanguage)
                : nil
            if let termsPrompt {
                logger.info("Термины: в промпт ушло терминов: \(termsPrompt.termCount), символов: \(termsPrompt.text.count)")
            }
            let options = TranscriptionOptions(language: sessionLanguage,
                                               contextPrompt: termsPrompt?.text)
            let transcript = try await Self.transcribe(engine, segment: segment, options: options)
            metrics.transcriptionTime = transcript.processingTime
            try Task.checkCancellation()

            guard !transcript.isEmpty else {
                logger.info("Распознавание вернуло пустой текст")
                concludeSession(with: .failed("Речь не распозналась — попробуй ещё раз"), idleAfter: 2.5)
                return
            }
            var text = transcript.text

            // 1б. Словарь замен (ТЗ 6.6, уровень 2) — ДО постобработки:
            // рефайнер должен видеть уже починенные термины, а не «исправлять»
            // ослышки по-своему. В лог идут ТОЛЬКО канонические написания
            // из словаря — исходные слова часть распознанного текста,
            // их логировать нельзя (ТЗ 7.4).
            if let terms {
                let corrected = terms.applyReplacements(to: text)
                if !corrected.appliedCanonicals.isEmpty {
                    logger.info("Термины: замен \(corrected.appliedCanonicals.count) — \(corrected.appliedCanonicals.joined(separator: ", "))")
                }
                text = corrected.text
            }

            // 2. Постобработка — опциональный шаг. По контракту refine не бросает
            // и при любой проблеме возвращает исходный текст (ТЗ 5.7).
            if let refiner {
                appState.sessionState = .refining
                let started = Date()
                text = await Self.refine(refiner, text: text, language: sessionLanguage)
                metrics.refinementTime = Date().timeIntervalSince(started)
                try Task.checkCancellation()
            }

            // 3. Вставка. В поля паролей не вставляем никогда (ТЗ 5.6).
            appState.sessionState = .inserting
            guard !inserter.focusedFieldIsSecure() else {
                throw InsertionError.secureFieldRefused
            }
            let insertion = try await inserter.insert(text)
            metrics.insertionTime = insertion.duration
            metrics.endToEndLatency = Date().timeIntervalSince(releasedAt)

            // В лог — только метаданные и тайминги, никогда сам текст (ТЗ 7.4).
            logger.info("Сессия успешна: вставка \(insertion.method.rawValue), язык \(sessionLanguage.rawValue)")
            logger.info("Метрики: \(metrics.summary)")

            concludeSession(with: .completed(insertion.method), idleAfter: 1.2)
        } catch is CancellationError {
            // Esc во время обработки: состояние уже выставил cancelSession().
            logger.info("Обработка прервана отменой")
        } catch {
            // Отмена могла прилететь, пока движок бросал своё, — не затираем «Отменено» ошибкой.
            guard !Task.isCancelled else { return }
            logger.error("Сессия провалилась: \(error.localizedDescription)")
            concludeSession(with: .failed(Self.humanMessage(for: error)), idleAfter: 3.0)
        }
    }

    /// Единая точка завершения: снимает перехват Esc, показывает терминальное
    /// состояние и через паузу возвращает оверлей в idle.
    private func concludeSession(with state: SessionState, idleAfter delay: TimeInterval) {
        hotkeys.endEscapeCapture()
        appState.microphoneLevel = 0
        appState.sessionState = state
        scheduleReturnToIdle(after: delay)
    }

    private func scheduleReturnToIdle(after delay: TimeInterval) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.returnToIdleIfTerminal()
        }
    }

    private func returnToIdleIfTerminal() {
        switch appState.sessionState {
        case .completed, .cancelled, .failed:
            appState.sessionState = .idle
        case .idle, .preparing, .listening, .transcribing, .refining, .inserting:
            break
        }
    }

    // MARK: - Человеческие сообщения об ошибках

    private static func humanMessage(for error: Error) -> String {
        // У ошибок контракта описания уже человеческие и по-русски.
        if let transcription = error as? TranscriptionError {
            return transcription.errorDescription ?? "Ошибка распознавания"
        }
        if let insertion = error as? InsertionError {
            return insertion.errorDescription ?? "Ошибка вставки"
        }
        return "Не получилось: \(error.localizedDescription)"
    }

    // MARK: - Мостики через границу изоляции

    // Nonisolated-статики: тяжёлые вызовы уходят с главного актора,
    // все параметры и результаты Sendable, отмена течёт структурно.
    // Это единственное место, где контрактные объекты покидают главный актор.

    nonisolated private static func warmUp(
        _ engine: UnsafeSendableBox<any TranscriptionEngine>
    ) async throws {
        try await engine.value.warmUp()
    }

    nonisolated private static func transcribe(
        _ engine: UnsafeSendableBox<any TranscriptionEngine>,
        segment: AudioSegment,
        options: TranscriptionOptions
    ) async throws -> Transcript {
        try await engine.value.transcribe(segment, options: options)
    }

    nonisolated private static func refine(
        _ refiner: UnsafeSendableBox<any TextRefining>,
        text: String,
        language: RecognitionLanguage
    ) async -> String {
        await refiner.value.refine(text, language: language)
    }
}
