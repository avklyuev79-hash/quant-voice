//
//  MenuBarController.swift
//  Quant Voice
//
//  Иконка и меню в строке меню. Главного окна и Dock-иконки нет (LSUIElement),
//  поэтому вся постоянная поверхность приложения — здесь.
//

import AppKit
import Observation

@MainActor
final class MenuBarController: NSObject {

    private let appState: AppState
    private let logger: any Logging
    private let logsDirectory: URL
    /// Нужен, чтобы качать модели прямо из меню. Опционален: без него
    /// подменю моделей просто не появляется.
    private let modelManager: ModelManager?

    private let statusItem: NSStatusItem
    private let stateMenuItem = NSMenuItem()
    private let engineMenuItem = NSMenuItem()
    private let modelsMenuItem = NSMenuItem()

    /// Идёт ли загрузка модели прямо сейчас — чтобы не запустить вторую.
    private var downloadTask: Task<Void, Never>?

    init(appState: AppState,
         logger: any Logging,
         logsDirectory: URL,
         modelManager: ModelManager? = nil) {
        self.appState = appState
        self.logger = logger
        self.logsDirectory = logsDirectory
        self.modelManager = modelManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()
        observeAppState()
        refreshModelsMenu()
    }

    // MARK: - Меню

    private func buildMenu() {
        let menu = NSMenu()
        // Управляем доступностью пунктов сами: информационные строки выключены,
        // а действия должны работать даже когда приложение не key (LSUIElement).
        menu.autoenablesItems = false

        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)

        engineMenuItem.isEnabled = false
        menu.addItem(engineMenuItem)

        menu.addItem(.separator())

        // Подменю моделей: пока нет окна настроек (веха M8), это единственный
        // способ скачать модель распознавания, без которой WhisperKit не работает.
        modelsMenuItem.title = "Модель распознавания"
        menu.addItem(modelsMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Настройки…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logsItem = NSMenuItem(title: "Открыть логи",
                                  action: #selector(openLogs),
                                  keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        let aboutItem = NSMenuItem(title: "О программе Quant Voice",
                                   action: #selector(openAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выйти из Quant Voice",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Подписка на состояние

    /// Классический цикл Observation для AppKit: читаем нужные свойства внутри
    /// withObservationTracking, по первому изменению перерисовываемся и
    /// подписываемся заново. onChange приходит не на главном акторе — прыгаем
    /// через Task { @MainActor }.
    private func observeAppState() {
        withObservationTracking {
            render(state: appState.sessionState, engineName: appState.engineName)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAppState()
            }
        }
    }

    private func render(state: SessionState, engineName: String?) {
        stateMenuItem.title = "Состояние: \(stateDescription(for: state))"

        if let engineName {
            engineMenuItem.title = "Движок: \(engineName)"
            engineMenuItem.isHidden = false
        } else {
            // Движок ещё не отчитался о готовности — обычно это значит,
            // что модель не загружена. Честно говорим об этом, а не прячем
            // за видимостью работоспособности.
            engineMenuItem.title = "Движок не готов — нужна модель"
            engineMenuItem.isHidden = false
        }

        if let button = statusItem.button {
            button.image = icon(for: state)
            button.toolTip = "Quant Voice — \(stateDescription(for: state))"
        }
    }

    private func stateDescription(for state: SessionState) -> String {
        switch state {
        case .idle:                 return "готов"
        case .listening:            return "слушаю"
        case .transcribing:         return "распознаю"
        case .refining:             return "причёсываю"
        case .inserting:            return "вставляю"
        case .completed(let method):
            return method == .clipboardOnly ? "текст в буфере (⌘V)" : "готово"
        case .cancelled:            return "отменено"
        case .failed(let message):  return "ошибка — \(message)"
        }
    }

    /// Иконка отражает фазу сессии. Все символы существуют с macOS 11 —
    /// на целевой macOS 14 доступны гарантированно.
    private func icon(for state: SessionState) -> NSImage? {
        let symbolName: String
        switch state {
        case .idle, .cancelled:
            // В покое — фирменная «Qv», как «Q» у Quant Keyboard: в строке меню
            // приложение должно узнаваться по бренду, а не по общему микрофону.
            // Во всех рабочих фазах бренд уступает место состоянию: пользователю
            // там важно, слушают его или уже печатают.
            return Self.brandIcon()
        case .listening:
            symbolName = "mic.fill"
        case .transcribing, .refining, .inserting:
            symbolName = "waveform"
        case .completed:
            symbolName = "checkmark.circle"
        case .failed:
            symbolName = "mic.slash"
        }
        let image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "Quant Voice")
        // Template-режим: система сама красит иконку под светлый/тёмный бар.
        image?.isTemplate = true
        return image
    }

    /// Фирменная «Qv» для строки меню.
    ///
    /// Рисуется кодом, а не грузится из ресурсов: в бандле SwiftPM ресурсы
    /// лежат в отдельном .bundle, и путь к ним зависит от способа сборки —
    /// текст же одинаково чёток на любом экране и в любом размере панели.
    /// Шрифт системный: в строке меню он и должен выглядеть системно.
    private static func brandIcon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "Qv", attributes: attributes)
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(x: (rect.width - glyphSize.width) / 2,
                                   y: (rect.height - glyphSize.height) / 2))
            return true
        }
        // Template — система красит под светлую и тёмную панель сама.
        image.isTemplate = true
        return image
    }

    // MARK: - Модели

    /// Перестраивает подменю моделей: что установлено, что можно скачать.
    /// Зовётся при старте и после каждой загрузки.
    private func refreshModelsMenu() {
        guard let modelManager else {
            modelsMenuItem.isHidden = true
            return
        }
        modelsMenuItem.isHidden = false

        Task { @MainActor in
            let installed = await modelManager.installedModels().map(\.variant)

            let submenu = NSMenu()
            submenu.autoenablesItems = false

            for descriptor in ModelManager.catalog {
                let isInstalled = installed.contains(descriptor.variant)
                let item = NSMenuItem(
                    title: isInstalled
                        ? "✓ \(descriptor.displayName)"
                        : "Загрузить: \(descriptor.displayName)",
                    action: isInstalled ? nil : #selector(self.downloadModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.isEnabled = !isInstalled && self.downloadTask == nil
                item.toolTip = descriptor.details
                // Вариант модели кладём в представленный объект — так действие
                // узнает, что именно качать, без разбора заголовка пункта.
                item.representedObject = descriptor.variant
                submenu.addItem(item)
            }

            if installed.isEmpty {
                submenu.addItem(.separator())
                let hint = NSMenuItem(title: "Без модели распознавание не работает",
                                      action: nil,
                                      keyEquivalent: "")
                hint.isEnabled = false
                submenu.addItem(hint)
            }

            self.modelsMenuItem.submenu = submenu
        }
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let modelManager,
              let variant = sender.representedObject as? String,
              let descriptor = ModelManager.catalog.first(where: { $0.variant == variant }),
              downloadTask == nil
        else { return }

        logger.info("Модели: пользователь запросил загрузку «\(variant)»")

        // Прогресс показываем в заголовке пункта меню: отдельного окна ещё нет,
        // а гонять пользователя в логи за процентами — плохо.
        modelsMenuItem.title = "Загрузка модели… 0%"

        downloadTask = Task { @MainActor in
            defer {
                self.downloadTask = nil
                self.modelsMenuItem.title = "Модель распознавания"
                self.refreshModelsMenu()
            }
            do {
                _ = try await modelManager.download(descriptor) { [weak self] fraction in
                    // Колбэк @Sendable и приходит не с главного потока, поэтому
                    // захватывать здесь NSMenuItem нельзя — он не Sendable.
                    // Захватываем сам контроллер (он @MainActor, а значит Sendable)
                    // и достаём пункт меню уже на главном акторе.
                    Task { @MainActor in
                        self?.modelsMenuItem.title = "Загрузка модели… \(Int(fraction * 100))%"
                    }
                }
                self.logger.info("Модели: «\(variant)» загружена")
                self.notify(title: "Модель загружена",
                            text: "\(descriptor.displayName). Перезапусти Quant Voice, чтобы движок её подхватил.")
            } catch {
                self.logger.error("Модели: загрузка не удалась: \(error.localizedDescription)")
                self.notify(title: "Не удалось загрузить модель",
                            text: error.localizedDescription)
            }
        }
    }

    private func notify(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    // MARK: - Действия

    /// Открытие окна настроек подставляет владелец (AppDelegate): окну нужны
    /// зависимости — менеджер моделей, селектор движков, монитор хоткеев, —
    /// которых у меню нет и быть не должно.
    var onOpenSettings: (() -> Void)?

    /// Открыть настройки сразу на вкладке «О программе». Подставляет AppDelegate.
    var onOpenAbout: (() -> Void)?

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openAbout() {
        onOpenAbout?()
    }

    @objc private func openLogs() {
        // Папка могла ещё не появиться, если логгер не успел ничего записать.
        try? FileManager.default.createDirectory(at: logsDirectory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDirectory)
        logger.debug("Открыта папка логов")
    }

    @objc private func quit() {
        logger.info("Выход по команде из меню")
        NSApp.terminate(nil)
    }
}
