// swift-tools-version: 6.0
//
//  Package.swift
//  Quant Voice
//
//  Сборка через SwiftPM, БЕЗ Xcode — достаточно Command Line Tools.
//  Так же собирается VoxLocal, и это правильный путь для нашего случая:
//  приложение простое, зависимость одна, а Xcode весит 15+ ГБ и не даёт
//  здесь ничего, кроме удобного редактора.
//
//  SwiftPM собирает только исполняемый файл. Структуру .app-бандла
//  (Contents/MacOS, Info.plist, ad-hoc подпись) собирает scripts/build.sh.
//
//  ⚠️ Deployment target — macOS 14, но SDK нужен 26+: код обращается
//  к системному движку распознавания из macOS 26 за проверками @available.
//  Проверки рантаймовые, поэтому классы должны существовать в SDK на этапе
//  компиляции. С Command Line Tools 26.x всё на месте.
//

import PackageDescription

let package = Package(
    name: "QuantVoice",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Единственная внешняя зависимость (ТЗ 5.2): WhisperKit из монорепозитория
        // Argmax. Пин на точную версию — никаких транзитивных сюрпризов.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.0.0")
    ],
    targets: [
        // Ядро словаря терминов: сопоставление, фонетика, морфология, отбор
        // в промпт. Отдельная библиотека нужна ради тестов — исполняемый
        // таргет тянет AppKit и главный актор, а тестировать надо чистую
        // логику. Здесь только Foundation, поэтому тесты идут и на Linux.
        .target(
            name: "QuantVoiceTerms",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Детерминированный уровень постобработки (ТЗ 5.7): пунктуация,
        // регистр, пробелы. Тоже чистый Foundation и тоже ради тестов —
        // этот слой правит текст пользователя молча.
        .target(
            name: "QuantVoiceText",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuantVoiceTermsTests",
            dependencies: ["QuantVoiceTerms"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "QuantVoiceModels",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuantVoiceModelsTests",
            dependencies: ["QuantVoiceModels"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuantVoiceTextTests",
            dependencies: ["QuantVoiceText"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "QuantVoice",
            dependencies: [
                "QuantVoiceTerms",
                "QuantVoiceText",
                "QuantVoiceModels",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            // Исходники лежат не в Sources/, а в QuantVoice/ — историческая
            // раскладка проекта, менять её ради SwiftPM смысла нет.
            path: "QuantVoice",
            // Info.plist встраивается в бандл скриптом сборки, иконка и фон
            // установщика — исходники для build.sh и build-dmg.sh.
            // Ресурсами SwiftPM они быть не должны.
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.iconset",
                "Resources/AppIcon.svg",
                "Resources/AppIcon-1024.png",
                "Resources/dmg-bg.png",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
