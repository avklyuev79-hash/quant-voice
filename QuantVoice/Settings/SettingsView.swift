//
//  SettingsView.swift
//  Quant Voice
//
//  Окно настроек на SwiftUI (веха M8, базовый объём для беты):
//  распознавание, права, горячие клавиши. Хостится в обычном NSWindow
//  через NSHostingController — см. SettingsWindowController: сцены SwiftUI
//  (Settings/Window) не годятся, приложение живёт на AppKit без main-сцены.
//

import SwiftUI

/// Вкладки окна настроек. Нужны как теги для программного выбора вкладки:
/// пункт меню «О программе Quant Voice» должен открывать окно сразу на ней.
enum SettingsTab: Hashable {
    case recognition, terms, permissions, hotkeys, about
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            RecognitionSettingsTab(model: model)
                .tabItem { Label("Распознавание", systemImage: "waveform") }
                .tag(SettingsTab.recognition)
            TermsSettingsTab(store: model.termsStore)
                .tabItem { Label("Термины", systemImage: "character.book.closed") }
                .tag(SettingsTab.terms)
            PermissionsSettingsTab(model: model)
                .tabItem { Label("Права", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            HotkeysSettingsTab(model: model)
                .tabItem { Label("Горячие клавиши", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)
            AboutSettingsTab()
                .tabItem { Label("О программе", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Фиксированный размер: окно без .resizable, содержимое известно.
        .frame(width: 560, height: 520)
        .alert("Ошибка", isPresented: $model.showError) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }
}

// MARK: - Распознавание

private struct RecognitionSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Модель распознавания") {
                Picker("Профиль", selection: $model.selectedProfile) {
                    ForEach(ModelManager.catalog) { descriptor in
                        // Двухэтажная подпись: имя профиля + живой статус.
                        // radioGroup принимает произвольные представления.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                            Text(model.statusLine(for: descriptor))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(descriptor.profile)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: model.selectedProfile) { model.profileChanged() }

                modelActions

                Text("Профиль применяется при следующем запуске: модель загружается в память один раз на старте, иначе первая фраза ловила бы холодный старт.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Движок") {
                Picker("Движок распознавания", selection: $model.enginePreference) {
                    Text("Автоматически").tag(EnginePreference.automatic)
                    Text("Системный (Apple)").tag(EnginePreference.system)
                    Text("WhisperKit").tag(EnginePreference.whisperKit)
                }
                .onChange(of: model.enginePreference) { model.enginePreferenceChanged() }

                Text("Применяется сразу, без перезапуска. «Автоматически» берёт системный движок Apple, когда он знает язык, иначе WhisperKit. Русского в системном движке нет — фактически работает WhisperKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Язык по умолчанию") {
                Picker("Язык", selection: $model.defaultLanguage) {
                    ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .onChange(of: model.defaultLanguage) { model.defaultLanguageChanged() }

                Text("Язык каждой диктовки фиксируется хоткеем. Это значение — для удержания 🌐 (применяется сразу) и прогрева движка на старте (после перезапуска).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Логи") {
                Picker("Уровень логирования", selection: $model.logLevel) {
                    Text("Отладка (debug)").tag(LogLevel.debug)
                    Text("Обычный (info)").tag(LogLevel.info)
                    Text("Предупреждения (warning)").tag(LogLevel.warning)
                    Text("Только ошибки (error)").tag(LogLevel.error)
                }
                .onChange(of: model.logLevel) { model.logLevelChanged() }

                Text("Вступает в силу после перезапуска. «Отладка» пишет замеры латентности — она нужна, пока идёт настройка скорости (веха M4).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.needsRestart {
                Section {
                    HStack {
                        Text("Изменения вступят в силу после перезапуска.")
                        Spacer()
                        Button("Перезапустить Quant Voice") { model.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshModels() }
        .confirmationDialog("Удалить модель с диска?",
                            isPresented: $model.showRemoveConfirmation) {
            Button("Удалить", role: .destructive) { model.removeConfirmed() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Файлы можно будет загрузить заново в любой момент. Если модель сейчас в памяти, она продолжит работать до перезапуска.")
        }
    }

    /// Действия для выбранного профиля: загрузка с прогрессом или удаление.
    @ViewBuilder
    private var modelActions: some View {
        let descriptor = ModelManager.descriptor(for: model.selectedProfile)
        if model.downloadingVariant == descriptor.variant {
            ProgressView(value: model.downloadProgress) {
                Text("Загрузка… \(Int(model.downloadProgress * 100))%")
            }
        } else if model.isInstalled(descriptor.variant) {
            Button("Удалить модель с диска…", role: .destructive) {
                model.pendingRemovalVariant = descriptor.variant
                model.showRemoveConfirmation = true
            }
            .disabled(model.downloadingVariant != nil)
        } else {
            // Размер показываем ДО загрузки — явное согласие на сеть (ТЗ 7.2).
            Button("Загрузить (~\(descriptor.approximateSizeMB) МБ)") {
                model.download(descriptor)
            }
            .disabled(model.downloadingVariant != nil)
        }
    }
}

// MARK: - Права

private struct PermissionsSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Микрофон") {
                LabeledContent("Статус") {
                    Text(statusText(model.microphoneStatus))
                        .foregroundStyle(statusColor(model.microphoneStatus))
                }
                if model.microphoneStatus == .notDetermined {
                    Button("Запросить доступ") { model.requestMicrophoneAccess() }
                }
                Button("Открыть системные настройки") {
                    PrivacySettingsPane.microphone.open()
                }
                Text("Без микрофона диктовка не слышит речь. Звук обрабатывается на этом Mac и никуда не отправляется.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Универсальный доступ") {
                LabeledContent("Статус") {
                    Text(statusText(model.accessibilityStatus))
                        .foregroundStyle(statusColor(model.accessibilityStatus))
                }
                Button("Открыть системные настройки") {
                    AccessibilityPermission.openSystemSettings()
                }
                Text("Нужен, чтобы видеть хоткей и вставлять текст в поле под курсором. Приложение подхватит право само, перезапуск не нужен.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Статусы дешёвые — обновляем при каждом показе вкладки; возврат
        // из System Settings дополнительно ловит windowDidBecomeKey контроллера.
        .onAppear { model.refreshPermissions() }
    }

    private func statusText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted:       return "выдан"
        case .denied:        return "нет доступа"
        case .notDetermined: return "не запрашивался"
        }
    }

    private func statusColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted:       return .green
        case .denied:        return .red
        case .notDetermined: return .orange
        }
    }
}

// MARK: - Горячие клавиши

private struct HotkeysSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Действующие сочетания") {
                ForEach(model.assignments, id: \.self) { assignment in
                    LabeledContent(assignment.hotkey.displayString,
                                   value: "диктовка — \(languageName(assignment.language))")
                }
                if model.globeHoldEnabled {
                    LabeledContent("Удержание 🌐 (fn)",
                                   value: "диктовка — \(languageName(model.defaultLanguage))")
                }
                Text("Короткое нажатие хоткея включает запись до второго нажатия, удержание — запись, пока клавиша нажата. Esc отменяет. Свой рекордер сочетаний появится в следующих версиях.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Клавиша 🌐") {
                Toggle("Диктовка по удержанию 🌐 (fn)", isOn: $model.globeHoldEnabled)
                    .onChange(of: model.globeHoldEnabled) { model.globeHoldChanged() }

                Text("Применяется сразу. Чтобы 🌐 заодно не дёргала системное действие, отключи его: Системные настройки → Клавиатура → «При нажатии 🌐» → «Ничего не делать».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Причёсывание текста") {
                Toggle("Базовое причёсывание", isOn: $model.textRefinementEnabled)
                    .onChange(of: model.textRefinementEnabled) { model.textRefinementChanged() }

                Text("Точка в конце фразы, заглавная после точки, лишние пробелы, звуковые «эээ». Работает офлайн, занимает доли миллисекунды. Выключи, если надиктовываешь куски внутрь готового текста — там точка и заглавная мешают.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Общее

/// Имена языков для UI. Живёт на уровне файла: нужна всем трём вкладкам.
private func languageName(_ language: RecognitionLanguage) -> String {
    switch language {
    case .russian: return "русский"
    case .english: return "английский"
    case .auto:    return "автоопределение"
    }
}
