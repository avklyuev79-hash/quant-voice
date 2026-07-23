//
//  OverlayView.swift
//  Quant Voice
//
//  Содержимое плашки состояния: индикатор фазы + текст.
//  Живёт внутри OverlayPanel через NSHostingView.
//

import SwiftUI

struct OverlayView: View {

    /// AppState — @Observable: SwiftUI сам отслеживает прочитанные в body
    /// свойства, никаких @ObservedObject/@State здесь не нужно.
    let appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 28, height: 28)
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .frame(maxWidth: 320)
        // Панель чуть больше карточки — центрируем содержимое в её окне.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Индикатор фазы

    @ViewBuilder
    private var indicator: some View {
        switch appState.sessionState {
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
        case .listening:
            // Живой уровень микрофона. Значение приходит колбэком захвата
            // через AppState — плашка ничего не опрашивает в цикле.
            LevelIndicator(level: appState.microphoneLevel)
        case .transcribing, .refining, .inserting:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.yellow)
        }
    }

    private var statusText: String {
        switch appState.sessionState {
        case .idle:
            return "Готов"
        case .listening:
            return "Слушаю…"
        case .transcribing:
            return "Распознаю…"
        case .refining:
            return "Причёсываю…"
        case .inserting:
            return "Вставляю…"
        case .completed(let method):
            // clipboardOnly — особый случай: текст не в поле, а в буфере,
            // и пользователю нужно действие. Говорим об этом прямо.
            return method == .clipboardOnly ? "Текст в буфере — нажми ⌘V" : "Готово"
        case .cancelled:
            return "Отменено"
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Индикатор уровня микрофона

/// Пять столбиков, высота которых дышит вместе с уровнем сигнала.
/// Профиль высот делает картинку «эквалайзером», а не ровной стеной.
private struct LevelIndicator: View {

    let level: Float

    private static let profile: [CGFloat] = [0.35, 0.7, 1.0, 0.7, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.profile.count, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3,
                           height: 4 + clampedLevel * 20 * Self.profile[index])
            }
        }
        // Короткая линейная анимация сглаживает шаги между колбэками (~20 Гц),
        // не превращая индикатор в кисель.
        .animation(.linear(duration: 0.08), value: level)
    }

    private var clampedLevel: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }
}
