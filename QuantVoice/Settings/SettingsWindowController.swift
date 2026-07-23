//
//  SettingsWindowController.swift
//  Quant Voice
//
//  Хостинг окна настроек. Приложение — LSUIElement на чистом AppKit,
//  без main-сцены SwiftUI, поэтому сцены Settings/Window недоступны:
//  окно создаётся руками как NSWindow с NSHostingController внутри.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки Quant Voice"
        // Без .resizable: размер задаёт SwiftUI-контент, тянуть окно нечем и незачем.
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Окном владеем мы, а не AppKit: иначе после первого закрытия
        // повторное открытие обратилось бы к уже освобождённому объекту.
        window.isReleasedWhenClosed = false
        self.window = window

        super.init()
        window.delegate = self
    }

    func show(selecting tab: SettingsTab? = nil) {
        if let tab { model.selectedTab = tab }
        // LSUIElement-приложение неактивно по природе: без явной активации
        // окно откроется ПОД чужими окнами, и человек его не увидит.
        NSApp.activate()
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        // Состояние мира могло измениться, пока окно было закрыто:
        // модель докачали из меню, права выдали в System Settings.
        model.refreshPermissions()
        model.refreshModels()
    }

    /// Возврат из System Settings после выдачи права — самый частый сценарий
    /// повторной активации окна; обновляем статусы, чтобы «выдан» появился сразу.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
    }
}
