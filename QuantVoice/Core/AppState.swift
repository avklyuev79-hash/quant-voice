//
//  AppState.swift
//  Quant Voice
//
//  Наблюдаемое состояние приложения — единственный источник правды для UI.
//

import Foundation
import Observation

/// Состояние приложения, на которое подписаны menu bar и оверлей.
///
/// Правило записи: сюда пишет только `SessionCoordinator` (и точка сборки
/// в `AppDelegate` — при старте). UI это состояние только читает. Так у нас
/// один направленный поток данных, и не бывает спора двух писателей.
///
/// Всё под `@MainActor`: и AppKit, и SwiftUI читают с главного актора,
/// а писатель (координатор) сам живёт на нём же.
@MainActor
@Observable
final class AppState {

    /// Текущая фаза сессии диктовки. `.idle` — оверлей спрятан.
    var sessionState: SessionState = .idle

    /// Уровень микрофона 0…1 для живого индикатора в оверлее.
    /// Обновляется колбэком из захвата (~20 раз в секунду), не опросом.
    var microphoneLevel: Float = 0

    /// Имя активного движка распознавания. nil, пока движок не подключён —
    /// на вехе M0 это нормальное состояние каркаса.
    var engineName: String?

    /// Статусы системных разрешений. Обновляются модулями по мере их подключения;
    /// до этого честно висят в `.notDetermined`.
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined

    /// Идёт ли сейчас активная сессия (от нажатия хоткея до вставки).
    /// Терминальные состояния (completed/cancelled/failed) — уже не активная.
    var isSessionActive: Bool {
        switch sessionState {
        case .listening, .transcribing, .refining, .inserting:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }
}
