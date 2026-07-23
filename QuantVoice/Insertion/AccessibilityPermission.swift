//
//  AccessibilityPermission.swift
//  Quant Voice
//
//  Право Accessibility: проверка, запрос с системным диалогом, открытие нужного
//  раздела System Settings, наблюдение за изменением статуса.
//
//  Право нужно двум подсистемам сразу: перехвату хоткеев (CGEventTap) и вставке
//  (чтение AX-фокуса, синтетический ⌘V). Пользователь выдаёт его один раз.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - Статус и запрос

@MainActor
public enum AccessibilityPermission {

    /// Есть ли право прямо сейчас. Дёшево, можно опрашивать часто.
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// В терминах общего контракта (Contracts.swift). У Accessibility нет
    /// состояния «не спрашивали»: система знает только «доверен / не доверен».
    public static var status: PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Запросить право с системным диалогом. Диалог показывается один раз
    /// за жизнь приложения в TCC; повторные вызовы просто возвращают статус.
    /// Возвращает текущее состояние (true, если право уже есть).
    @discardableResult
    public static func requestWithSystemPrompt() -> Bool {
        // Константу kAXTrustedCheckOptionPrompt Swift 6 видит как глобальную var
        // из C и отказывается пускать её через границу конкурентности.
        // Значение стабильно и задокументировано — берём литералом.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Открыть System Settings сразу на разделе Privacy & Security → Accessibility.
    /// Каскад URL общий для всех разделов приватности и живёт в
    /// PrivacySettingsPane: раньше здесь была своя копия, вторая — в AppDelegate
    /// (микрофон), и при смене якорей macOS они бы неизбежно разъехались.
    public static func openSystemSettings() {
        PrivacySettingsPane.accessibility.open()
    }
}

// MARK: - Наблюдение за изменением статуса

/// Пользователь выдаёт право в System Settings, НЕ перезапуская приложение, —
/// мы обязаны это заметить и ожить (включить перехват, убрать плашку онбординга).
///
/// Системного колбэка «право изменилось» у Accessibility нет, поэтому:
/// 1. Основной механизм — опрос `AXIsProcessTrusted` таймером. Вызов дешёвый
///    (локальная проверка TCC-кэша), раз в секунду — не нагрузка.
/// 2. Ускоритель — распределённое уведомление `com.apple.accessibility.api`,
///    которое TCC рассылает при изменении базы доверия. Оно недокументированное,
///    поэтому используется только как повод опросить статус немедленно,
///    а не как источник истины.
@MainActor
public final class AccessibilityPermissionObserver {

    /// Вызывается на главном потоке при каждой смене статуса.
    public var onChange: ((Bool) -> Void)?

    /// Последний известный статус.
    public private(set) var isGranted: Bool

    private var timer: Timer?

    // nonisolated(unsafe): токен нужен в deinit (он nonisolated), а
    // removeObserver потокобезопасен. Пишется токен только с главного потока.
    private nonisolated(unsafe) var distributedObserver: (any NSObjectProtocol)?

    public init() {
        isGranted = AXIsProcessTrusted()
    }

    /// Начать наблюдение. Повторный вызов перезапускает.
    public func start(pollInterval: TimeInterval = 1.0) {
        stop()
        isGranted = AXIsProcessTrusted()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] timer in
            // Timer не Sendable, поэтому трогаем его ДО перехода на актор:
            // если затащить параметр внутрь assumeIsolated, Swift 6 справедливо
            // ругается на пересылку значения через границу изоляции.
            guard let self else {
                timer.invalidate() // владелец умер без stop() — гасим сами
                return
            }
            // Таймер запланирован на главном RunLoop — мы гарантированно на MainActor.
            MainActor.assumeIsolated {
                self.refresh()
            }
        }
        // .common — чтобы опрос не замирал, пока открыто меню в menu bar.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Остановить наблюдение. Вызывать при выключении соответствующей логики;
    /// таймер также самоликвидируется, если наблюдатель освобождён без stop().
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            distributedObserver = nil
        }
    }

    deinit {
        // Таймер снимет себя сам при следующем срабатывании (weak self == nil).
        // Подписку на распределённые уведомления снимаем здесь — иначе центр
        // держал бы блок вечно.
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func refresh() {
        let current = AXIsProcessTrusted()
        guard current != isGranted else { return }
        isGranted = current
        onChange?(current)
    }
}
