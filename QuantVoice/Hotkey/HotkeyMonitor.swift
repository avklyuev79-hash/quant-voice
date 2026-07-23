//
//  HotkeyMonitor.swift
//  Quant Voice
//
//  Глобальный перехват хоткеев через CGEventTap (ТЗ 5.5, веха M1).
//  Реализация `HotkeyMonitoring`. Схема tap'а перенесена из проверенного
//  EventTapController Quant Keyboard: kCGSessionEventTap + headInsert +
//  .defaultTap, лёгкий C-колбэк, переустановка после tapDisabledByTimeout.
//
//  Два режима на одном хоткее, определяются автоматически (ТЗ 5.5):
//  • отпустил раньше 250 мс → toggle: запись продолжается до второго нажатия;
//  • держит дольше 250 мс → hold: отпустил — распознаём.
//
//  ⚠️ Компромисс контракта: `startCapture(mode:)` уходит в момент нажатия,
//  когда режим ещё неизвестен (ждать 250 мс нельзя — потеряем начало речи).
//  Отдаём mode: .hold — в этот момент клавиша физически удерживается.
//  Если нажатие оказалось коротким, событий «режим сменился на toggle»
//  контракт не предусматривает; функционально это ни на что не влияет —
//  finishCapture в toggle просто придёт со вторым нажатием.
//
//  Перехват Esc — ТОЛЬКО между beginEscapeCapture()/endEscapeCapture():
//  вне сессии Esc проходит в систему нетронутым, ломать его нельзя.
//
//  Потоки: tap живёт на выделенном потоке со своим run loop — если главный
//  поток занят (рендер оверлея, SwiftUI-настройки), клавиатура всей системы
//  не должна ждать. Колбэк максимально быстрый: решение по состоянию под
//  замком и диспатч события на главный поток; вся тяжёлая работа — у
//  координатора. Класс @unchecked Sendable: безопасность — вручную, замком.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Ошибки

public enum HotkeyMonitorError: LocalizedError {
    case accessibilityPermissionDenied
    case tapCreationFailed
    case runLoopSetupFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Нет разрешения Accessibility (Универсальный доступ)"
        case .tapCreationFailed:
            return "Не удалось установить перехват клавиатуры"
        case .runLoopSetupFailed:
            return "Не удалось запустить поток перехвата клавиатуры"
        }
    }
}

// MARK: - Монитор

public final class HotkeyMonitor: HotkeyMonitoring, @unchecked Sendable {

    /// Порог hold/toggle из ТЗ 5.5. Настраиваемый на будущее, дефолт менять
    /// не планируем — это часть UX, которую пользователь не должен трогать.
    public var holdThreshold: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _holdThreshold }
        set { lock.lock(); defer { lock.unlock() }; _holdThreshold = newValue }
    }

    /// Привязки хоткеев к языкам. Меняются из настроек, вступают в силу
    /// со следующего нажатия — перезапуск монитора не нужен.
    public var assignments: [HotkeyAssignment] {
        get { lock.lock(); defer { lock.unlock() }; return _assignments }
        set { lock.lock(); defer { lock.unlock() }; _assignments = newValue }
    }

    /// Язык для удержания 🌐. Отдельно от `assignments`: у клавиши-модификатора
    /// нет вариантов с ⇧ и прочими, поэтому язык у неё ровно один.
    public var globeLanguage: RecognitionLanguage {
        get { lock.lock(); defer { lock.unlock() }; return _globeLanguage }
        set { lock.lock(); defer { lock.unlock() }; _globeLanguage = newValue }
    }

    /// Включена ли диктовка по удержанию 🌐. Выключатель нужен тем, кто
    /// оставляет за 🌐 системное действие (смена раскладки, эмодзи) — для них
    /// случайные старты записи при удержании клавиши были бы помехой.
    /// Меняется из настроек на живом мониторе, перезапуск не нужен.
    public var globeHoldEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _globeHoldEnabled }
        set { lock.lock(); defer { lock.unlock() }; _globeHoldEnabled = newValue }
    }

    // MARK: HotkeyMonitoring

    public var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoring
    }

    public var onEvent: ((HotkeyEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEvent }
        set { lock.lock(); defer { lock.unlock() }; _onEvent = newValue }
    }

    // MARK: - Состояние (всё под `lock`)

    /// Фаза сессии с точки зрения физики клавиш.
    private enum Phase {
        case idle
        /// Хоткей нажат, ждём отпускания, чтобы классифицировать hold/toggle.
        case pressed(downAt: CFAbsoluteTime, keyCode: UInt16)
        /// Был короткий тап — toggle-запись идёт, ждём второго нажатия.
        case toggleArmed
    }

    private let lock = NSLock()
    private var _onEvent: ((HotkeyEvent) -> Void)?
    private var _assignments: [HotkeyAssignment] = HotkeyAssignment.defaults
    private var _holdThreshold: TimeInterval = 0.25
    /// Язык, на котором пишем при удержании 🌐. Основной язык пользователя.
    private var _globeLanguage: RecognitionLanguage = .russian
    private var _globeHoldEnabled = true
    private var _isMonitoring = false
    private var phase: Phase = .idle
    private var escapeCaptureActive = false
    /// Клавиши, чей keyDown мы проглотили: их keyUp обязан быть проглочен
    /// тоже, каким бы ни было состояние к этому моменту. Иначе приложение
    /// под курсором получит keyUp без keyDown. Заодно решает классическую
    /// проблему «Option отпустили раньше Space»: keyUp матчится по коду
    /// клавиши, а не по уже изменившимся флагам.
    private var suppressedKeyDowns: Set<UInt16> = []

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    /// Логгер нужен именно здесь: без него отладка хоткеев идёт вслепую —
    /// непонятно, встал ли tap, доходят ли события, совпадает ли комбинация.
    ///
    /// ⚠️ Логируем ТОЛЬКО события-кандидаты (с нашими модификаторами или 🌐).
    /// Писать в лог все нажатия нельзя — это превратило бы приложение
    /// в кейлоггер, что несовместимо с ТЗ 7.4.
    private let logger: (any Logging)?

    public init(logger: (any Logging)? = nil) {
        self.logger = logger
    }

    deinit {
        // Владелец (координатор) держит монитор весь срок жизни приложения,
        // поэтому в колбэке достаточно passUnretained — как в Quant Keyboard.
        // stop() здесь — страховка на случай пересоздания в тестах.
        stop()
    }

    // MARK: - Запуск/остановка

    public func start() throws {
        lock.lock()
        let alreadyRunning = _isMonitoring
        lock.unlock()
        guard !alreadyRunning else { return } // идемпотентность

        // Без Accessibility tap не встанет (или встанет listen-only мёртвым
        // грузом) — честно бросаем сразу (ТЗ 5.5).
        guard AXIsProcessTrusted() else {
            logger?.error("Хоткеи: нет права Accessibility, перехват не встанет")
            throw HotkeyMonitorError.accessibilityPermissionDenied
        }

        // flagsChanged слушаем ради клавиши 🌐 (fn): она не порождает
        // keyDown/keyUp, только смену флага maskSecondaryFn. Это единственная
        // причина держать здесь третий тип события.
        let mask: CGEventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        // .defaultTap (активный): нам нужно ГЛОТАТЬ хоткей, чтобы ⌥Space
        // не печатал неразрывный пробел в приложении под курсором.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: quantVoiceHotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw HotkeyMonitorError.tapCreationFailed
        }

        // Источник кладём в свойство ДО старта потока: поток заберёт его
        // через self, чтобы не тащить CF-объект через Sendable-замыкание.
        lock.lock()
        tapPort = port
        runLoopSource = source
        phase = .idle
        suppressedKeyDowns.removeAll()
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            self.lock.lock()
            self.tapRunLoop = CFRunLoopGetCurrent()
            let source = self.runLoopSource
            self.lock.unlock()

            guard let source else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            ready.signal()
            // Крутимся, пока источник жив; stop() инвалидирует источник
            // и останавливает run loop — поток завершается сам.
            CFRunLoopRun()
        }
        thread.name = "com.quant.voice.hotkey-tap"
        // Пользовательский ввод — это интерактив: поток не должен уступать
        // фоновым задачам (иначе клавиатура «залипает» под нагрузкой).
        thread.qualityOfService = .userInteractive
        thread.start()

        guard ready.wait(timeout: .now() + 2) == .success else {
            lock.lock()
            tapPort = nil
            runLoopSource = nil
            lock.unlock()
            CFMachPortInvalidate(port)
            throw HotkeyMonitorError.runLoopSetupFailed
        }

        CGEvent.tapEnable(tap: port, enable: true)

        lock.lock()
        _isMonitoring = true
        let bindings = _assignments
            .map { "\($0.hotkey.displayString)→\($0.language.rawValue)" }
            .joined(separator: ", ")
        let globeInfo = _globeHoldEnabled ? "удержание 🌐 → \(_globeLanguage.rawValue)" : "удержание 🌐 выключено"
        lock.unlock()

        logger?.info("Хоткеи: перехват встал. Клавиатурные: \(bindings). Также \(globeInfo)")
    }

    public func stop() {
        lock.lock()
        let port = tapPort
        let source = runLoopSource
        let loop = tapRunLoop
        tapPort = nil
        runLoopSource = nil
        tapRunLoop = nil
        phase = .idle
        escapeCaptureActive = false
        suppressedKeyDowns.removeAll()
        _isMonitoring = false
        lock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
    }

    // MARK: - Перехват Esc

    /// Включается координатором на время сессии записи. Вне этого окна
    /// Esc проходит в систему нетронутым (ТЗ 5.5) — глобально сломанный
    /// Esc пользователь не простит.
    public func beginEscapeCapture() {
        lock.lock()
        escapeCaptureActive = true
        lock.unlock()
    }

    public func endEscapeCapture() {
        lock.lock()
        escapeCaptureActive = false
        lock.unlock()
    }

    // MARK: - Разрешения

    public static func permissionStatus() -> PermissionStatus {
        // У Accessibility нет состояния «не спрашивали» в публичном API:
        // AXIsProcessTrusted отвечает только да/нет, поэтому .notDetermined
        // здесь не бывает.
        AXIsProcessTrusted() ? .granted : .denied
    }

    public static func openPermissionSettings() {
        // Каскад URL общий и живёт в PrivacySettingsPane — своя копия здесь
        // разъехалась бы с остальными при следующей смене якорей macOS.
        // Task вместо DispatchQueue.main.async + assumeIsolated: на связке
        // этих двух конструкций компилятор Swift 6.3 падает с внутренней
        // ошибкой «failed to produce diagnostic». Здесь нужен просто переход
        // на главный актор — Task его и делает, без вложенных замыканий.
        Task { @MainActor in
            PrivacySettingsPane.accessibility.open()
        }
    }

    // MARK: - Обработка (вызывается C-колбэком на tap-потоке)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Система выключила tap (таймаут колбэка или пользовательский ввод
        // при разборках с правами) — включаем обратно, иначе «хоткей перестал
        // работать через час» (ТЗ 5.5, опыт Quant Keyboard).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reinstallAfterTimeout()
            return Unmanaged.passUnretained(event)
        }

        // Клавиша 🌐 (fn) — отдельная ветка: она приходит только сменой флага.
        if type == .flagsChanged {
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == KeyCodes.globe else {
                return Unmanaged.passUnretained(event)
            }
            let isDown = event.flags.contains(.maskSecondaryFn)

            lock.lock()
            let hotkeyEvent = handleGlobeLocked(isDown: isDown)
            lock.unlock()

            logger?.debug("Хоткеи: 🌐 \(isDown ? "нажата" : "отпущена")\(hotkeyEvent.map { " → \($0)" } ?? "")")

            if let hotkeyEvent {
                emit(hotkeyEvent)
            }
            // flagsChanged НИКОГДА не глотаем: fn — модификатор, через него
            // работают F-клавиши и стрелки. Проглотив его, мы сломали бы
            // половину клавиатуры. Системное действие самой 🌐 (эмодзи или
            // смена языка) отключается в настройках клавиатуры — так надёжнее,
            // чем воевать с системой за событие.
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = HotkeyConfiguration.Modifiers(cgFlags: event.flags)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        lock.lock()
        let decision = decideLocked(
            type: type,
            keyCode: keyCode,
            modifiers: modifiers,
            isAutorepeat: isAutorepeat
        )
        lock.unlock()

        // Логируем только события-кандидаты: те, что несут наши модификаторы,
        // либо те, на которые мы отреагировали. Писать в лог весь ввод нельзя —
        // это был бы кейлоггер (ТЗ 7.4).
        if decision.event != nil || (!modifiers.isEmpty && type == .keyDown && !isAutorepeat) {
            let combo = modifiers.displayString + HotkeyConfiguration.keyName(for: keyCode)
            if let hotkeyEvent = decision.event {
                logger?.debug("Хоткеи: \(combo) → \(hotkeyEvent)")
            } else {
                logger?.debug("Хоткеи: \(combo) не совпал ни с одной привязкой")
            }
        }

        if let hotkeyEvent = decision.event {
            emit(hotkeyEvent)
        }
        return decision.suppress ? nil : Unmanaged.passUnretained(event)
    }

    /// Обработка клавиши 🌐 (fn). Вызывается строго под `lock`.
    ///
    /// Режим только один — удержание: зажал, сказал, отпустил. Toggle здесь
    /// не делаем сознательно. Короткое нажатие 🌐 — это системный жест
    /// (эмодзи, смена языка), перехватывать его нельзя, поэтому запись,
    /// начатую случайным тапом, мы отменяем.
    ///
    /// Запись стартует сразу по нажатию, а не после порога удержания: иначе
    /// потерялись бы первые 250 мс речи у тех, кто начинает говорить сразу.
    /// Цена — короткий тап породит пару «старт, отмена», которая ничего
    /// не вставит и ничего не сломает.
    private func handleGlobeLocked(isDown: Bool) -> HotkeyEvent? {
        if isDown {
            // Выключатель проверяем только на нажатии: если 🌐 выключили,
            // пока клавишу держали, начатую запись честно доигрываем —
            // оборвать её на полуслове хуже, чем завершить.
            guard _globeHoldEnabled else { return nil }
            guard case .idle = phase else { return nil }
            phase = .pressed(downAt: CFAbsoluteTimeGetCurrent(), keyCode: KeyCodes.globe)
            // Именно `_globeLanguage`, а не публичное свойство: мы уже под
            // замком, а он не рекурсивный — обращение к геттеру повесило бы поток.
            return .startCapture(mode: .hold, language: _globeLanguage)
        }

        guard case .pressed(let downAt, let keyCode) = phase, keyCode == KeyCodes.globe else {
            return nil
        }
        phase = .idle

        let heldFor = CFAbsoluteTimeGetCurrent() - downAt
        // Не дотянул до порога — считаем, что человек не диктовал,
        // а нажал 🌐 по своим делам.
        return heldFor < _holdThreshold ? .cancel : .finishCapture
    }

    /// Чистая машина состояний. Вызывается строго под `lock`.
    /// Возвращает: какое событие отдать координатору и глотать ли CGEvent.
    private func decideLocked(
        type: CGEventType,
        keyCode: UInt16,
        modifiers: HotkeyConfiguration.Modifiers,
        isAutorepeat: Bool
    ) -> (event: HotkeyEvent?, suppress: Bool) {

        if type == .keyDown {
            // Автоповтор удерживаемого хоткея глотаем без реакции — иначе
            // система напечатает очередь пробелов, пока держат ⌥Space.
            // Автоповтор чужих клавиш не трогаем.
            if isAutorepeat {
                return (nil, suppressedKeyDowns.contains(keyCode))
            }

            // Esc — только в окне сессии, иначе проходит нетронутым.
            if escapeCaptureActive && keyCode == KeyCodes.escape {
                suppressedKeyDowns.insert(keyCode)
                phase = .idle // сессия отменена; keyUp зажатого хоткея съест suppressedKeyDowns
                return (.cancel, true)
            }

            if let match = _assignments.first(where: { $0.hotkey.matches(keyCode: keyCode, modifiers: modifiers) }) {
                switch phase {
                case .idle:
                    // Запись стартует сразу, не дожидаясь классификации
                    // hold/toggle — см. компромисс в шапке файла.
                    phase = .pressed(downAt: CFAbsoluteTimeGetCurrent(), keyCode: keyCode)
                    suppressedKeyDowns.insert(keyCode)
                    return (.startCapture(mode: .hold, language: match.language), true)

                case .toggleArmed:
                    // Второе нажатие (любого из хоткеев) завершает toggle-запись.
                    phase = .idle
                    suppressedKeyDowns.insert(keyCode)
                    return (.finishCapture, true)

                case .pressed:
                    // Второй хоткей, пока держат первый, — физически странно;
                    // глотаем (чтобы не напечатать пробел), но не реагируем.
                    suppressedKeyDowns.insert(keyCode)
                    return (nil, true)
                }
            }
            return (nil, false)
        }

        // keyUp: глотаем только пары к проглоченным keyDown.
        guard suppressedKeyDowns.contains(keyCode) else {
            return (nil, false)
        }
        suppressedKeyDowns.remove(keyCode)

        if case .pressed(let downAt, let pressedKeyCode) = phase, pressedKeyCode == keyCode {
            let heldFor = CFAbsoluteTimeGetCurrent() - downAt
            if heldFor < _holdThreshold {
                // Короткий тап → toggle: запись продолжается до второго нажатия.
                phase = .toggleArmed
                return (nil, true)
            }
            // Держали дольше порога → hold: отпустили — распознаём.
            phase = .idle
            return (.finishCapture, true)
        }
        return (nil, true)
    }

    /// События координатору — строго на главном потоке (контракт).
    private func emit(_ event: HotkeyEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onEvent?(event)
        }
    }

    /// Дешёвая переустановка после tapDisabledByTimeout: сначала просто
    /// tapEnable; полное пересоздание — только если порт умер, и обязательно
    /// вне колбэка (подход Quant Keyboard).
    private func reinstallAfterTimeout() {
        lock.lock()
        let port = tapPort
        lock.unlock()
        guard let port else { return }

        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stop()
                try? self.start() // права на месте — не выйдет разве что при их отзыве
            }
        }
    }
}

// MARK: - C-колбэк

/// C-колбэк CGEventTap: только достаёт монитор из userInfo и делегирует.
/// Никакой логики здесь — каждая миллисекунда в колбэке задерживает
/// клавиатуру всей системы.
private func quantVoiceHotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
