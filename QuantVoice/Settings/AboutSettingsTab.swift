//
//  AboutSettingsTab.swift
//  Quant Voice
//
//  Раздел «О программе» окна настроек. По образцу Quant Keyboard (AboutView):
//  цветная иконка «Qv», описание продукта и агентства, кликабельные контакты
//  Quant акцентным синим, кнопка-пилюля «Обсудить задачу», версия и лицензия.
//  Это и есть функция «точки входа в агентство»: приложение раздаётся бесплатно
//  и заодно показывает, кто и зачем его сделал.
//
//  Стиль намеренно нативный (SwiftUI без своего дизайн-системного слоя):
//  окно Voice построено на Form/.grouped, отдельный design-system как в
//  Keyboard тут заводить незачем — хватает системных цветов и Link.
//

import SwiftUI
import AppKit

struct AboutSettingsTab: View {

    /// Фирменный синий Quant (#0071E3), общий с Quant Keyboard.
    private static let accent = Color(red: 0 / 255, green: 113 / 255, blue: 227 / 255)

    private static let repoURL = "https://github.com/avklyuev79-hash/quant-voice"

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Цветная иконка: синий скруглённый квадрат, белая «Qv» —
                // тот же бренд, что и в строке меню.
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Self.accent)
                        .frame(width: 96, height: 96)
                    Text("Qv")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.top, 20)

                VStack(spacing: 3) {
                    Text("Quant Voice")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Версия \(version) (beta)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 9) {
                    Text("Нажал горячую клавишу, надиктовал — текст появляется в поле под курсором. Распознавание идёт прямо на этом Mac, без интернета. Бесплатно.")
                    Text("Единственная диктовка, которая по ходу русской речи сама узнаёт англоязычные бренды — Apple, Google, iPhone — и пишет их латиницей, а не кириллицей на слух.")
                        .foregroundColor(Self.accent)
                    Text("Сделали мы, агентство Quant. Мы архитекторы ИИ — звено между бизнесом и искусственным интеллектом: берём процесс, поручаем его ИИ и отвечаем за результат.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

                // Контакты агентства — кликабельны, открываются в браузере.
                GroupBox {
                    VStack(spacing: 0) {
                        contactRow(label: "Сайт", value: "quant-agency.ru",
                                   url: "https://quant-agency.ru")
                        Divider()
                        contactRow(label: "Почта", value: "hello@quant-agency.ru",
                                   url: "mailto:hello@quant-agency.ru")
                        Divider()
                        contactRow(label: "Telegram", value: "@quant_agency_bot",
                                   url: "https://t.me/quant_agency_bot")
                        Divider()
                        contactRow(label: "Исходный код", value: "GitHub",
                                   url: Self.repoURL)
                    }
                }
                .frame(maxWidth: 420)

                // Кнопка-пилюля: прямой призыв к действию для агентства.
                Link(destination: URL(string: "https://quant-agency.ru/brief.html")!) {
                    Text("Обсудить задачу")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 980)
                                .fill(Self.accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Text("Алексей Клюев · Quant · MIT License · © 2026")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private func contactRow(label: String, value: String, url: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Link(value, destination: URL(string: url)!)
                .font(.system(size: 13))
                .foregroundColor(Self.accent)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
