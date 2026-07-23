//
//  OnboardingView.swift
//  Quant Voice
//
//  Экран мастера первого запуска. Четыре шага, брендовая шапка «Qv», внизу —
//  точки прогресса и навигация. Хостится в NSWindow через OnboardingWindowController
//  (приложение живёт на AppKit без main-сцены SwiftUI).
//

import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    /// Завершение мастера (кнопка «Готово» или «Позже»). Подставляет контроллер.
    let onDone: () -> Void

    /// Фирменный синий Quant (#0071E3).
    private static let accent = Color(red: 0 / 255, green: 113 / 255, blue: 227 / 255)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.step {
                    case .welcome:       welcomeStep
                    case .model:         modelStep
                    case .microphone:    microphoneStep
                    case .accessibility: accessibilityStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Self.accent)
                    .frame(width: 52, height: 52)
                Text("Qv")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Quant Voice")
                    .font(.system(size: 17, weight: .semibold))
                Text(stepTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var stepTitle: String {
        switch model.step {
        case .welcome:       return "Знакомство"
        case .model:         return "Шаг 1 из 3 · Модель распознавания"
        case .microphone:    return "Шаг 2 из 3 · Доступ к микрофону"
        case .accessibility: return "Шаг 3 из 3 · Универсальный доступ"
        }
    }

    // MARK: - Шаг: приветствие

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Голосовой ввод, который работает на вашем Mac")
                .font(.system(size: 16, weight: .semibold))
            Text("Нажали горячую клавишу, надиктовали — текст появляется в поле под курсором. Распознавание идёт прямо на этом компьютере, без интернета. Звук никуда не отправляется.")
                .foregroundStyle(.secondary)
            Text("Единственная диктовка, которая по ходу русской речи сама узнаёт англоязычные бренды — Apple, Google, iPhone — и пишет их латиницей, а не кириллицей на слух.")
                .foregroundColor(Self.accent)
            Text("Настройка занимает минуту: скачать модель распознавания и выдать два разрешения. Сейчас пройдём это по шагам.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Шаг: модель

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Модель превращает речь в текст локально. Без неё диктовка не работает. Скачивается один раз, дальше всё офлайн.")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $model.selectedProfile) {
                ForEach(ModelManager.catalog) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.profile)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.isDownloading)

            Text(model.descriptor.details)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.selectedModelInstalled {
                statusLine(ok: true, text: "Модель уже на диске — можно идти дальше.")
            } else if model.isDownloading {
                ProgressView(value: model.downloadProgress) {
                    Text("Загрузка… \(Int(model.downloadProgress * 100))%")
                        .font(.system(size: 12))
                }
            } else {
                Button("Скачать (~\(model.descriptor.approximateSizeMB) МБ)") {
                    model.download()
                }
            }

            if let error = model.downloadError {
                Text("Не удалось загрузить: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Скачать можно и позже — из меню «Qv» → «Модель распознавания».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Шаг: микрофон

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Без доступа к микрофону Quant Voice не слышит речь. Звук обрабатывается на этом Mac и никуда не отправляется.")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            permissionStatusView(model.microphoneStatus)

            switch model.microphoneStatus {
            case .granted:
                EmptyView()
            case .notDetermined:
                Button("Разрешить доступ к микрофону") { model.requestMicrophone() }
            case .denied:
                Button("Открыть системные настройки") { model.openMicrophoneSettings() }
            }
        }
    }

    // MARK: - Шаг: Универсальный доступ

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Универсальный доступ нужен, чтобы поймать горячую клавишу и вставить текст в поле под курсором. Приложение подхватит право само, перезапуск не нужен.")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            permissionStatusView(model.accessibilityStatus)

            if model.accessibilityStatus != .granted {
                Button("Открыть «Универсальный доступ»") { model.openAccessibility() }
                Text("Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включить QuantVoice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.readyToDictate {
                statusLine(ok: true, text: "Всё готово. Нажми горячую клавишу и продиктуй первую фразу.")
            }
        }
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack {
            if model.step.isFirst {
                Button("Позже") { onDone() }
            } else {
                Button("Назад") { model.back() }
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == model.step ? Self.accent : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            if model.step.isLast {
                Button("Готово") { onDone() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Далее") { model.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Общее

    private func permissionStatusView(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:       return statusLine(ok: true, text: "Доступ выдан.")
        case .denied:        return statusLine(ok: false, text: "Доступа нет — включи его в системных настройках.")
        case .notDetermined: return statusLine(ok: false, text: "Доступ ещё не выдан.")
        }
    }

    private func statusLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ok ? .primary : .secondary)
            Spacer(minLength: 0)
        }
    }
}
