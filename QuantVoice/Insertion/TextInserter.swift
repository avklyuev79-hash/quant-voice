//
//  TextInserter.swift
//  Quant Voice
//
//  Вставка распознанного текста в сфокусированное поле чужого приложения.
//  Каскад строго по ТЗ 5.6: Accessibility API → синтетический ⌘V → буфер + уведомление.
//
//  Главный инвариант: текст пользователя не теряется никогда. Если первые два
//  уровня не сработали, текст в любом случае остаётся в буфере обмена.
//
//  ⚠️ Приватность (ТЗ 7.4): в лог никогда не попадает ни вставляемый текст,
//  ни содержимое буфера обмена. Только bundle id, метод, тайминги и длина.
//

import AppKit
import QuantVoiceText
import ApplicationServices
import Foundation
import UserNotifications

// MARK: - Типобезопасная обёртка над AX C-API

/// Обёртка над `AXUIElement`. Прячет ручную работу с `CFTypeRef`, проверку
/// type id и коды `AXError` за обычными Swift-опционалами.
///
/// Все вызовы AX — только с главного потока: API само по себе потокобезопасно,
/// но мы держим единую дисциплину (протоколы вставки помечены @MainActor),
/// чтобы порядок операций «проверка фокуса → вставка» был атомарен для нас.
@MainActor
struct AXElement {

    let raw: AXUIElement

    /// Системный элемент — точка входа для поиска фокуса во всей системе.
    static var systemWide: AXElement {
        AXElement(raw: AXUIElementCreateSystemWide())
    }

    /// Сфокусированный UI-элемент (поле ввода, веб-область и т.п.).
    /// nil — нет права Accessibility либо фокус через AX не виден.
    var focusedElement: AXElement? {
        element(for: kAXFocusedUIElementAttribute)
    }

    /// PID приложения, которому принадлежит клавиатурный фокус.
    var focusedApplicationPID: pid_t? {
        guard let app = element(for: kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app.raw, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    var role: String? { string(for: kAXRoleAttribute) }
    var subrole: String? { string(for: kAXSubroleAttribute) }

    /// Можно ли программно установить значение атрибута.
    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    func string(for attribute: String) -> String? {
        copyValue(attribute) as? String
    }

    /// Целочисленный атрибут (CFNumber), например kAXNumberOfCharactersAttribute.
    func integer(for attribute: String) -> Int? {
        copyValue(attribute) as? Int
    }

    func element(for attribute: String) -> AXElement? {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Проверка type id выше делает этот каст безопасным: для CF-типов
        // `as!` — это непроверяемый бит-каст, поэтому проверяем сами.
        return AXElement(raw: value as! AXUIElement)
    }

    /// CFRange-атрибут (упакован в AXValue), например kAXSelectedTextRangeAttribute.
    func range(for attribute: String) -> CFRange? {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var result = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &result) else { return nil }
        return result
    }

    /// Установить строковый атрибут. Возвращает сырой AXError — вызывающему
    /// важно отличать успех от отказа, а не просто получить nil.
    @discardableResult
    func setString(_ string: String, for attribute: String) -> AXError {
        AXUIElementSetAttributeValue(raw, attribute as CFString, string as CFString)
    }

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }
}

// MARK: - Снимок буфера обмена

/// Полный снимок NSPasteboard — все элементы со всеми типами, не только строка.
/// Пользователь мог держать в буфере картинку, файл или rich text — после
/// синтетического ⌘V мы обязаны вернуть всё как было.
///
/// @unchecked Sendable: снимок — неизменяемые значения (Data и строковые ключи
/// PasteboardType), он честно передаваем между изоляциями; unchecked нужен лишь
/// потому, что NSPasteboard.PasteboardType не аннотирован Sendable в SDK.
/// Это позволяет захватить снимок в отложенную задачу восстановления буфера.
/// Сами вызовы init/restore трогают NSPasteboard — делаются только с MainActor.
struct PasteboardSnapshot: @unchecked Sendable {

    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(of pasteboard: NSPasteboard) {
        // data(forType:) материализует «ленивые» (promised) данные — например,
        // при скопированном из другого приложения большом объекте. Это цена
        // честного восстановления; вставка происходит редко, задержка приемлема.
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var typedData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typedData[type] = data
                }
            }
            return typedData
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return } // буфер был пуст — оставляем пустым
        let restored = items.map { typedData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typedData {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

// MARK: - Вставка текста

/// Реализация `TextInserting` (Contracts.swift). Каскад из трёх уровней,
/// деградация без потери текста.
@MainActor
public final class TextInserter: TextInserting {

    // MARK: Тайминги уровня 2 (синтетический ⌘V)

    /// Почему именно такие значения — см. комментарии к каждому. Это самое
    /// тонкое место каскада: слишком раннее восстановление буфера означает,
    /// что приложение вставит СТАРОЕ содержимое (или ничего) — потеря текста,
    /// худший исход. Слишком позднее — окно, в котором пользователь видит
    /// «подменённый» буфер.
    private enum Timing {
        /// Пауза между keyDown и keyUp синтетического ⌘V.
        /// Мгновенный up вслед за down часть приложений (Java, некоторые
        /// Electron) обрабатывает ненадёжно; 20 мс имитирует быстрое живое
        /// нажатие и не заметно в общей латентности.
        static let keyEventGapNs: UInt64 = 20_000_000 // 20 мс

        /// Задержка от keyUp до восстановления прежнего буфера.
        /// Приложение читает буфер в момент обработки keyDown в своём главном
        /// потоке: у нативных приложений это единицы-десятки миллисекунд после
        /// доставки события, у Electron/JVM под нагрузкой наблюдаются хвосты
        /// ~100–200 мс. 300 мс — с запасом выше хвоста. Заметить подмену за
        /// это окно пользователь физически не успевает: он только что диктовал
        /// и не обращается к буферу в те же треть секунды. Перед восстановлением
        /// дополнительно сверяется changeCount — если буфер уже изменил кто-то
        /// другой, ничего не трогаем.
        static let pasteboardRestoreDelayNs: UInt64 = 300_000_000 // 300 мс
    }

    /// kVK_ANSI_V. Константа из Carbon, продублирована, чтобы не тянуть импорт
    /// ради одного числа. Виртуальный код не зависит от раскладки.
    private static let keyCodeV: CGKeyCode = 9

    private let logger: Logging?
    private let compatibilityLog: InsertionCompatibilityLog?
    private let appInspector: FocusedAppInspector

    /// Своя предыдущая вставка — чтобы не склеить с ней следующую фразу.
    /// Живёт в памяти процесса и никуда не пишется: это контекст сессии,
    /// а не состояние (и уж точно не то, что стоит сохранять на диск, —
    /// здесь лежит текст пользователя, ТЗ 7.4).
    private var lastInsertion: InsertionSpacing.Previous?

    /// Отложенное восстановление буфера после ⌘V. Хранится, чтобы следующая
    /// вставка не сняла снимок с нашего же ещё-не-восстановленного буфера.
    private var pendingRestore: Task<Void, Never>?

    public init(logger: Logging? = nil,
                compatibilityLog: InsertionCompatibilityLog? = nil,
                appInspector: FocusedAppInspector? = nil) {
        self.logger = logger
        self.compatibilityLog = compatibilityLog
        self.appInspector = appInspector ?? FocusedAppInspector(logger: logger)
    }

    // MARK: TextInserting

    public func insert(_ text: String) async throws -> InsertionResult {
        let startedAt = DispatchTime.now()

        // Пустую строку не вставляем: через AX установка пустого AXSelectedText
        // СТЁРЛА бы текущее выделение пользователя. Координатор и так отсеивает
        // пустые транскрипты (Transcript.isEmpty), это страховка.
        guard !text.isEmpty else {
            logger?.debug("Вставка: пустой текст, ничего не делаем")
            return InsertionResult(method: .accessibility, duration: elapsed(since: startedAt))
        }

        // Защита secure fields (ТЗ 5.6): в поле пароля не вставляем НИ ОДНИМ
        // из уровней — ни AX, ни ⌘V, ни даже в буфер. Осознанное решение:
        // мы не автозаполняем пароли.
        if focusedFieldIsSecure() {
            logger?.warning("Вставка отклонена: сфокусировано поле ввода пароля")
            throw InsertionError.secureFieldRefused
        }

        // Приложение-получатель снимаем ДО вставки: сразу после ⌘V фокус тот же,
        // но надёжнее зафиксировать заранее. Логируется только bundle id (ТЗ 7.4).
        let app = appInspector.focusedApp()

        // Разделитель с предыдущей вставкой. Фразы, надиктованные подряд,
        // склеивались встык — «…распознается.Специально говорю…» (живой баг
        // 20.07.2026). Знать, что стоит слева от каретки, мы не можем: AX-путь
        // в целевом приложении не работает, вставка идёт через ⌘V вслепую.
        // Поэтому помним свою же предыдущую вставку — правила в InsertionSpacing.
        let payload = InsertionSpacing.separator(for: text,
                                                 previous: lastInsertion,
                                                 application: app?.bundleID) + text
        lastInsertion = InsertionSpacing.Previous(text: payload,
                                                  application: app?.bundleID,
                                                  at: Date())

        // Уровень 1 — Accessibility API. Быстро, буфер не тронут, ничего не мигает.
        if insertViaAccessibility(payload) {
            return finish(.accessibility, app: app, startedAt: startedAt, textLength: payload.count)
        }

        // Уровень 2 — синтетический ⌘V с восстановлением буфера.
        if await insertViaPaste(payload) {
            return finish(.paste, app: app, startedAt: startedAt, textLength: payload.count)
        }

        // Уровень 3 — последняя линия обороны: текст в буфер, уведомление.
        // Прежний буфер осознанно НЕ сохраняем: восстановление тут же уничтожило
        // бы текст пользователя, а он важнее прежнего содержимого (ТЗ 5.6).
        // В буфер кладём текст БЕЗ разделителя: пользователь вставит его сам,
        // и ведущий пробел ему там не нужен.
        try placeInClipboard(text)
        notifyClipboardFallback()
        return finish(.clipboardOnly, app: app, startedAt: startedAt, textLength: text.count)
    }

    public func focusedFieldIsSecure() -> Bool {
        guard let focused = AXElement.systemWide.focusedElement else {
            // Без права Accessibility поле не проверить — но без него не сработают
            // и уровни 1–2: текст просто ляжет в буфер, автозаполнения не будет.
            return false
        }
        // Стандартный признак: role AXTextField + subrole AXSecureTextField.
        // Так репортят и нативные поля (NSSecureTextField), и <input type="password">
        // в WebKit/Blink. Некоторые приложения кладут секьюрность прямо в role —
        // проверяем оба места.
        if focused.subrole == kAXSecureTextFieldSubrole { return true }
        if focused.role == "AXSecureTextField" { return true }
        return false
    }

    // MARK: Уровень 1 — Accessibility

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focused = AXElement.systemWide.focusedElement else {
            logger?.debug("AX: фокус не найден (нет права или элемент не виден), падаем на ⌘V")
            return false
        }

        // Гейт на редактируемость. Единственный признак, который работает и для
        // обычных полей, и для contenteditable в веб-вью (там role — AXWebArea,
        // а не AXTextField): можно ли программно установить AXSelectedText.
        // Роли не проверяем намеренно — список редактируемых ролей неполон и
        // отсеял бы рабочие случаи.
        guard focused.isSettable(kAXSelectedTextAttribute) else {
            logger?.debug("AX: AXSelectedText не settable, падаем на ⌘V")
            return false
        }

        // Снимаем признаки «до», чтобы после вставки отличить успех от тихого
        // игнора (бывают приложения, отвечающие .success и не делающие ничего).
        let rangeBefore = focused.range(for: kAXSelectedTextRangeAttribute)
        let countBefore = focused.integer(for: kAXNumberOfCharactersAttribute)

        // Ключевой приём: установка kAXSelectedTextAttribute ЗАМЕНЯЕТ текущее
        // выделение, а при пустом выделении вставляет в позицию каретки.
        // Ровно та семантика, что нам нужна, одним вызовом.
        let error = focused.setString(text, for: kAXSelectedTextAttribute)
        guard error == .success else {
            logger?.debug("AX: вставка не удалась (AXError \(error.rawValue)), падаем на ⌘V")
            return false
        }

        // Верификация. AX-вызовы синхронны (IPC с ответом), поэтому состояние
        // элемента сразу после set — уже итоговое, читать его безопасно.
        let rangeAfter = focused.range(for: kAXSelectedTextRangeAttribute)
        let countAfter = focused.integer(for: kAXNumberOfCharactersAttribute)

        // Каретка сдвинулась или длина текста изменилась — вставка точно была.
        if let before = rangeBefore, let after = rangeAfter,
           before.location != after.location || before.length != after.length {
            return true
        }
        if let before = countBefore, let after = countAfter, before != after {
            return true
        }

        // Оба признака читаются и оба не изменились — приложение молча
        // проигнорировало вставку. Честно уходим на уровень 2.
        if rangeBefore != nil, rangeAfter != nil, countBefore != nil, countAfter != nil {
            logger?.debug("AX: .success, но ни каретка, ни длина не изменились — считаем, что вставки не было")
            return false
        }

        // Признаки прочитать не удалось — доверяем .success. Здесь перестраховка
        // опаснее недострахованности: ложное «не вставилось» привело бы к
        // ДВОЙНОЙ вставке через ⌘V, а это заметнее и хуже редкого фолбэка.
        return true
    }

    // MARK: Уровень 2 — синтетический ⌘V

    private func insertViaPaste(_ text: String) async -> Bool {
        // Синтетические клавиатурные события требуют того же права Accessibility.
        // Без него post() молча уходит в никуда — проверяем явно, чтобы не
        // разрушить буфер впустую.
        guard AXIsProcessTrusted() else {
            logger?.info("⌘V: нет права Accessibility, уходим на буфер с уведомлением")
            return false
        }

        // Если от прошлой вставки ещё не восстановлен буфер — дожидаемся.
        // Иначе снимок захватил бы НАШ прошлый текст вместо пользовательского.
        if let pending = pendingRestore {
            await pending.value
            pendingRestore = nil
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: false)
        else {
            logger?.warning("⌘V: не удалось создать CGEvent")
            return false
        }
        // Флаги задаём явно и ровно ⌘: пользователь в этот момент может ещё
        // физически удерживать модификаторы хоткея (⌥ в hold-режиме), и они
        // не должны примешаться к синтетическому событию.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)

        pasteboard.clearContents()
        // Маркер org.nspasteboard.TransientType — конвенция nspasteboard.org:
        // менеджеры буфера (Maccy, Paste и др.) не сохраняют помеченное в историю.
        // Наш текст лежит в буфере треть секунды служебно — ему в истории не место.
        // На уровне 3 маркер НЕ ставим: там буфер — конечное место доставки.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard pasteboard.setString(text, forType: .string) else {
            // Буфер не принял текст — вернём как было и уйдём на уровень 3.
            snapshot.restore(to: pasteboard)
            logger?.warning("⌘V: буфер не принял текст")
            return false
        }
        let ourChangeCount = pasteboard.changeCount

        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: Timing.keyEventGapNs)
        keyUp.post(tap: .cghidEventTap)

        // Восстановление — отложенной задачей: вставка у получателя уже
        // происходит, держать вызывающего (и оверлей «вставляю…») ещё 300 мс
        // незачем. Гонки закрыты: (а) следующий ⌘V сначала дожидается этой
        // задачи; (б) перед восстановлением сверяется changeCount — если буфер
        // уже изменили (пользователь, другой процесс, наш же уровень 3),
        // чужое новое содержимое важнее снимка, не трогаем.
        pendingRestore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Timing.pasteboardRestoreDelayNs)
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == ourChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }

        // Подтверждения доставки у ⌘V принципиально нет: считаем успехом сам
        // факт отправки событий. Приложения, которые кладут ⌘V мимо, ловятся
        // ручным чек-листом совместимости (ТЗ 9.4). Остаточный риск потери
        // здесь принят ТЗ 5.6 — уровень 2 существует именно для приложений,
        // где AX не работает, и без восстановления буфера потерял бы смысл.
        return true
    }

    // MARK: Уровень 3 — буфер + уведомление

    private func placeInClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // Сюда попадаем практически никогда; но контракт требует честно
            // сообщить, если текст не удалось сохранить даже в буфере.
            throw InsertionError.clipboardUnavailable
        }
    }

    /// Ненавязчивое уведомление «текст в буфере». Дополняет оверлей: оверлей
    /// показывает SessionState.completed(.clipboardOnly) и исчезает, а
    /// уведомление остаётся в Центре уведомлений, пока пользователь не вставил.
    private func notifyClipboardFallback() {
        // UNUserNotificationCenter работает только внутри полноценного .app-бандла.
        guard Bundle.main.bundleIdentifier != nil else {
            logger?.warning("Уведомление о буфере пропущено: запуск вне .app-бандла")
            return
        }
        let log = logger
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Self.postClipboardNotification()
                    } else {
                        log?.info("Уведомления отклонены — текст в буфере, статус виден в оверлее")
                    }
                }
            case .denied:
                log?.info("Уведомления запрещены пользователем — полагаемся на оверлей")
            default:
                Self.postClipboardNotification()
            }
        }
    }

    /// Запросить право на уведомления заранее (для онбординга), чтобы системный
    /// диалог не выскочил в самый неподходящий момент — при первом фолбэке.
    public nonisolated static func requestClipboardNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private nonisolated static func postClipboardNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Quant Voice"
        content.body = "Текст в буфере обмена. Вставь его: ⌘V"
        // Фиксированный идентификатор: повторные фолбэки заменяют уведомление,
        // а не копят стопку.
        let request = UNNotificationRequest(identifier: "quantvoice.insertion.clipboard-fallback",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: Служебное

    private func finish(_ method: InsertionMethod,
                        app: FocusedAppInfo?,
                        startedAt: DispatchTime,
                        textLength: Int) -> InsertionResult {
        let result = InsertionResult(method: method, duration: elapsed(since: startedAt))
        compatibilityLog?.record(app: app, method: method)
        // Только метаданные: метод, тайминг, длина, bundle id. Никогда — сам текст (ТЗ 7.4).
        logger?.info(String(format: "Вставка: %@ · %.0f мс · %ld симв. · %@",
                            method.rawValue,
                            result.duration * 1000,
                            textLength,
                            app?.displayID ?? "неизвестное приложение"))
        return result
    }

    private func elapsed(since start: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
