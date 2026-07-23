//
//  OverlayPanel.swift
//  Quant Voice
//
//  Панель-плашка состояния диктовки.
//
//  ⚠️ КРИТИЧНО (ТЗ 8, разбор Handy в ТЗ 4.1): панель НИКОГДА не становится
//  key window. Стиль .nonactivatingPanel + canBecomeKey/Main = false.
//  Если панель украдёт фокус, вставка текста уйдёт не в то приложение —
//  это известная поломка аналога, которую мы не повторяем.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class OverlayPanel: NSPanel {

    private let appState: AppState

    /// Желаемая видимость. Отдельный флаг, а не isVisible, потому что во время
    /// анимации исчезновения окно ещё isVisible, но логически уже спрятано.
    private var isShown = false

    /// Отступ плашки от нижнего края видимой области экрана.
    /// Позиция станет настраиваемой позже (ТЗ 8); пока — снизу по центру.
    private static let bottomMargin: CGFloat = 96

    init(appState: AppState) {
        self.appState = appState
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        // Плашка должна быть видна на любом рабочем столе и поверх
        // полноэкранных приложений — диктуют ведь откуда угодно.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // Тень рисует SwiftUI вокруг скруглённой карточки; системная тень
        // на прозрачном окне оставляет прямоугольные артефакты.
        hasShadow = false
        // Это чистый индикатор: клики проходят сквозь него в приложение под ним.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        alphaValue = 0

        contentView = NSHostingView(rootView: OverlayView(appState: appState))

        observeAppState()
    }

    // Ядро защиты от кражи фокуса — см. шапку файла.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Подписка на состояние

    /// Тот же цикл Observation, что в MenuBarController: читаем состояние,
    /// по изменению — перерисовка и повторная подписка на главном акторе.
    private func observeAppState() {
        withObservationTracking {
            apply(state: appState.sessionState)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAppState()
            }
        }
    }

    private func apply(state: SessionState) {
        switch state {
        case .idle:
            hidePanel()
        case .listening, .transcribing, .refining, .inserting,
             .completed, .cancelled, .failed:
            showPanel()
        }
    }

    // MARK: - Показ и скрытие

    private func showPanel() {
        guard !isShown else { return }
        isShown = true
        // Позиционируем только в момент появления: двигать плашку посреди
        // сессии (если пользователь увёл мышь на другой экран) — дёрганье.
        reposition()
        // orderFrontRegardless, а не makeKeyAndOrderFront: показать окно,
        // не активируя ни его, ни приложение.
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit зовёт завершение на главном потоке; фиксируем это для компилятора.
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.orderOut(nil)
            }
        })
    }

    /// Снизу по центру того экрана, где сейчас курсор: диктовка идёт туда,
    /// где пользователь работает, а не на «главный» экран системы.
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - frame.width / 2,
                             y: visible.minY + Self.bottomMargin)
        setFrameOrigin(origin)
    }
}
