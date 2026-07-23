//
//  OnboardingWindowController.swift
//  Quant Voice
//
//  Хостинг окна мастера первого запуска. Как и окно настроек, приложение —
//  LSUIElement на чистом AppKit без main-сцены SwiftUI, поэтому окно создаётся
//  руками как NSWindow с NSHostingController внутри.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    /// Мастер закрыт. `shouldRelaunch` — модель докачали в этой сессии, движок
    /// подхватит её только после перезапуска. Вызывается ровно один раз.
    var onFinished: ((_ shouldRelaunch: Bool) -> Void)?

    private let window: NSWindow
    private let model: OnboardingModel
    private var finished = false

    init(model: OnboardingModel) {
        self.model = model

        // doneHandler заполняется после super.init: замыкание представления
        // захватывает переменную по ссылке, поэтому поздняя привязка работает.
        var doneHandler: () -> Void = {}
        let hosting = NSHostingController(
            rootView: OnboardingView(model: model, onDone: { doneHandler() })
        )

        let window = NSWindow(contentViewController: hosting)
        window.title = "Добро пожаловать в Quant Voice"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // .floating: мастер не должен потеряться под другими окнами при старте.
        window.level = .floating
        self.window = window

        super.init()
        window.delegate = self
        doneHandler = { [weak self] in self?.complete() }
    }

    func show() {
        // LSUIElement неактивно по природе — без активации окно уйдёт под чужие.
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Наблюдение за Accessibility: галку в System Settings мастер должен
        // увидеть сразу, без перезахода.
        model.startObservingAccessibility()
    }

    /// Завершение по кнопке «Готово»/«Позже».
    private func complete() {
        finish()
        window.close()
    }

    /// Общий путь выхода: и кнопка, и красный крестик окна ведут сюда.
    /// Гарантированно один вызов onFinished.
    private func finish() {
        guard !finished else { return }
        finished = true
        model.stopObserving()
        onFinished?(model.needsRelaunch)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Закрытие крестиком — тоже завершение мастера: второй раз не навязываемся.
        finish()
    }
}
