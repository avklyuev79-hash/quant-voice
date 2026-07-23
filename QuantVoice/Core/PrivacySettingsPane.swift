//
//  PrivacySettingsPane.swift
//  Quant Voice
//
//  Открытие System Settings на нужном разделе «Конфиденциальность и безопасность».
//
//  Каскад URL один на все разделы: канонический для macOS 14+/26 идентификатор
//  расширения, затем легаси-якорь (маршрутизируется со времён System Preferences),
//  затем корень раздела, в самом конце — просто System Settings, чтобы человек
//  хотя бы оказался в настройках. Раньше этот каскад жил двумя копиями
//  (Accessibility — в AccessibilityPermission, микрофон — в AppDelegate);
//  при следующей смене якорей macOS копии неизбежно разъехались бы,
//  поэтому логика вынесена сюда, а окну настроек она нужна третьим клиентом.
//

import AppKit

@MainActor
public enum PrivacySettingsPane {
    case microphone
    case accessibility

    /// Якорь раздела внутри Privacy & Security. Одинаков в каноническом
    /// и легаси-URL — различаются только идентификаторы панели.
    private var anchor: String {
        switch self {
        case .microphone:    return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        }
    }

    public func open() {
        let candidates = [
            // Канонический для macOS 14+/26 (System Settings на расширениях).
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            // Легаси-якорь, работает с macOS 10.9 и по-прежнему маршрутизируется.
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            // Корень «Конфиденциальность и безопасность», если якорь не распознан.
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Совсем крайний случай: открываем приложение настроек как есть.
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: settingsURL,
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }
}
