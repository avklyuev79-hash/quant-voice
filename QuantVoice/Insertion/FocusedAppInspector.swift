//
//  FocusedAppInspector.swift
//  Quant Voice
//
//  Определение приложения, в которое идёт вставка. Нужно для двух вещей:
//  (а) лог совместимости — какой уровень каскада сработал в каком приложении
//      (ТЗ 9.4, InsertionCompatibilityLog);
//  (б) задел на M5 — контекстный отбор терминов для prompt-biasing по
//      активному приложению (ТЗ 6.6).
//
//  ⚠️ Приватность (ТЗ 7.4): наружу отдаются только bundle id, имя и pid.
//  Ни заголовки окон, ни содержимое полей, ни вставляемый текст здесь
//  не читаются и не логируются.
//

import AppKit
import ApplicationServices
import Foundation

/// Минимальный слепок приложения-получателя. Только идентификация, ничего лишнего.
public struct FocusedAppInfo: Sendable {
    /// Bundle id, например "com.apple.Safari". nil у безбандловых процессов.
    public let bundleID: String?
    /// Человекочитаемое имя, например "Safari".
    public let name: String?
    public let processID: pid_t

    /// Строка для логов: bundle id, при его отсутствии — имя, дальше pid.
    public var displayID: String {
        bundleID ?? name ?? "pid:\(processID)"
    }

    public init(bundleID: String?, name: String?, processID: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
    }
}

@MainActor
public final class FocusedAppInspector {

    private let logger: Logging?

    public init(logger: Logging? = nil) {
        self.logger = logger
    }

    /// Приложение, которому сейчас принадлежит клавиатурный фокус.
    ///
    /// Порядок источников:
    /// 1. AX (kAXFocusedApplicationAttribute) — кто РЕАЛЬНО владеет фокусом.
    ///    Это точнее, чем frontmost: оверлеи вроде Spotlight забирают клавиатуру,
    ///    не всегда становясь «фронтальным» приложением в терминах NSWorkspace.
    /// 2. NSWorkspace.frontmostApplication — фолбэк, работает и без права
    ///    Accessibility (например, до онбординга).
    public func focusedApp() -> FocusedAppInfo? {
        if let pid = AXElement.systemWide.focusedApplicationPID {
            if let app = NSRunningApplication(processIdentifier: pid) {
                return FocusedAppInfo(bundleID: app.bundleIdentifier,
                                      name: app.localizedName,
                                      processID: pid)
            }
            // PID есть, а NSRunningApplication нет — процесс без Launch Services
            // (редкость). Отдаём хотя бы pid, чтобы лог совместимости не слеп.
            return FocusedAppInfo(bundleID: nil, name: nil, processID: pid)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            logger?.debug("Инспектор: AX-фокус недоступен, берём frontmost-приложение")
            return FocusedAppInfo(bundleID: app.bundleIdentifier,
                                  name: app.localizedName,
                                  processID: app.processIdentifier)
        }

        logger?.debug("Инспектор: не удалось определить приложение-получатель")
        return nil
    }
}
