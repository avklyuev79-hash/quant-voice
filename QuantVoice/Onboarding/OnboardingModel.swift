//
//  OnboardingModel.swift
//  Quant Voice
//
//  Состояние мастера первого запуска (остаток M8). Ведёт человека через четыре
//  шага: приветствие → модель распознавания → микрофон → Универсальный доступ.
//  Без этого свежая установка оставляет человека один на один с пустыми
//  настройками: надо самому догадаться скачать модель и выдать два разрешения.
//
//  Живёт на главном акторе: читает и меняет UI-состояние, права и модели.
//

import AppKit
import Observation

@MainActor
@Observable
final class OnboardingModel {

    /// Шаги мастера. rawValue — порядок и заодно индекс для точек прогресса.
    enum Step: Int, CaseIterable {
        case welcome, model, microphone, accessibility

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .accessibility }
    }

    var step: Step = .welcome

    // MARK: - Модель распознавания

    /// Профиль, который человек выбрал скачать. Дефолт — тот, что уже прописан
    /// в настройках (обычно `standard`), чтобы мастер и настройки не спорили.
    var selectedProfile: WhisperModelProfile = Preferences.modelProfile()

    /// Варианты, реально лежащие на диске. Обновляется после сканирования.
    private(set) var installedVariants: Set<String> = []

    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?

    /// Скачали ли модель прямо в этой сессии. Если да — движок подхватит её
    /// только после перезапуска (модель грузится в память один раз на старте),
    /// поэтому завершение мастера предложит перезапуск.
    private(set) var didDownloadThisSession = false

    var descriptor: WhisperModelDescriptor {
        ModelManager.descriptor(for: selectedProfile)
    }

    var selectedModelInstalled: Bool {
        installedVariants.contains(descriptor.variant)
    }

    var anyModelInstalled: Bool { !installedVariants.isEmpty }

    // MARK: - Права

    var microphoneStatus: PermissionStatus
    var accessibilityStatus: PermissionStatus

    /// Всё ли готово к работе: модель на диске и оба права выданы.
    var readyToDictate: Bool {
        anyModelInstalled
            && microphoneStatus == .granted
            && accessibilityStatus == .granted
    }

    /// Нужен ли перезапуск при завершении — только если модель докачали сейчас.
    var needsRelaunch: Bool { didDownloadThisSession }

    // MARK: - Зависимости

    private let modelManager: ModelManager
    private let appState: AppState
    private let logger: any Logging
    private var accessibilityObserver: AccessibilityPermissionObserver?

    init(modelManager: ModelManager, appState: AppState, logger: any Logging) {
        self.modelManager = modelManager
        self.appState = appState
        self.logger = logger
        self.microphoneStatus = AudioCapture.permissionStatus()
        self.accessibilityStatus = AccessibilityPermission.status
        refreshInstalled()
    }

    // MARK: - Навигация

    func next() {
        guard let nextStep = Step(rawValue: step.rawValue + 1) else { return }
        step = nextStep
    }

    func back() {
        guard let prevStep = Step(rawValue: step.rawValue - 1) else { return }
        step = prevStep
    }

    // MARK: - Модель

    func refreshInstalled() {
        Task {
            let list = await modelManager.installedModels()
            self.installedVariants = Set(list.map(\.variant))
        }
    }

    func download() {
        guard !isDownloading else { return }
        let descriptor = self.descriptor
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        logger.info("Онбординг: загрузка модели «\(descriptor.variant)»")

        Task {
            do {
                _ = try await modelManager.download(descriptor) { [weak self] fraction in
                    // Колбэк приходит не с главного потока — прыгаем на актор.
                    Task { @MainActor in self?.downloadProgress = fraction }
                }
                self.didDownloadThisSession = true
                Preferences.setModelProfile(self.selectedProfile)
                self.refreshInstalled()
                self.logger.info("Онбординг: модель «\(descriptor.variant)» установлена")
            } catch {
                self.downloadError = error.localizedDescription
                self.logger.error("Онбординг: модель не загрузилась: \(error.localizedDescription)")
            }
            self.isDownloading = false
        }
    }

    // MARK: - Микрофон

    func requestMicrophone() {
        Task {
            let granted = await AudioCapture.requestPermission()
            self.microphoneStatus = granted ? .granted : .denied
            self.appState.microphonePermission = self.microphoneStatus
            self.logger.info("Онбординг: микрофон \(granted ? "разрешён" : "отклонён")")
            // Если отказали (или система уже помнит отказ) — вести в настройки
            // руками, диалог второй раз не покажется.
            if !granted { PrivacySettingsPane.microphone.open() }
        }
    }

    func openMicrophoneSettings() {
        PrivacySettingsPane.microphone.open()
    }

    // MARK: - Универсальный доступ

    /// Право выдаётся в System Settings без перезапуска — наблюдаем за статусом,
    /// чтобы «выдан» появился в мастере сразу, как человек поставил галку.
    func startObservingAccessibility() {
        accessibilityStatus = AccessibilityPermission.status
        guard accessibilityObserver == nil else { return }
        let observer = AccessibilityPermissionObserver()
        observer.onChange = { [weak self] granted in
            guard let self else { return }
            self.accessibilityStatus = granted ? .granted : .denied
            self.appState.accessibilityPermission = self.accessibilityStatus
        }
        observer.start()
        accessibilityObserver = observer
    }

    func openAccessibility() {
        AccessibilityPermission.requestWithSystemPrompt()
        AccessibilityPermission.openSystemSettings()
    }

    func stopObserving() {
        accessibilityObserver?.stop()
        accessibilityObserver = nil
    }
}
