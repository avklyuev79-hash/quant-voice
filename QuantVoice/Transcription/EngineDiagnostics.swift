//
//  EngineDiagnostics.swift
//  Quant Voice
//
//  Диагностический прогон: какие движки доступны, какие языки поддерживают,
//  версия macOS, чип, наличие Apple Intelligence.
//
//  Запускается при первом старте (или по команде из меню отладки) и пишет
//  всё в лог уровня info. Именно этот лог закрывает открытые вопросы ТЗ 13:
//  прежде всего №1 — есть ли русский в SpeechTranscriber.supportedLocales.
//
//  ⚠️ Никакой сети: только чтение состояния системы и диска.
//  ⚠️ Никакого пользовательского контента в логе (ТЗ 7.4) — здесь его и нет.
//

import Foundation
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct EngineDiagnostics: Sendable {

    private let modelManager: ModelManager
    private let selector: EngineSelector
    private let logger: any Logging

    public init(modelManager: ModelManager,
                selector: EngineSelector,
                logger: any Logging) {
        self.modelManager = modelManager
        self.selector = selector
        self.logger = logger
    }

    /// Полный прогон. Возвращает отчёт строкой (для показа в окне «Диагностика»)
    /// и параллельно пишет его в лог построчно — чтобы отчёт попал в файл лога
    /// даже если пользователь окно не открывал.
    @discardableResult
    public func run(defaultLanguage: RecognitionLanguage = .russian) async -> String {
        var lines: [String] = []
        lines.append("=== Диагностика Quant Voice ===")

        // — Система —
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Чип: \(Self.chipName())")
        lines.append("Архитектура: \(Self.isAppleSilicon() ? "Apple Silicon" : "Intel")")
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        lines.append(String(format: "Память: %.0f ГБ", ramGB))

        // — Apple Intelligence (нужна для постобработки Foundation Models, ТЗ 5.7) —
        lines.append("Apple Intelligence: \(await Self.appleIntelligenceStatus())")

        // — Системный движок: ГЛАВНЫЙ ответ (открытый вопрос №1 из ТЗ 13) —
        let system = await selector.system
        if SystemSpeechEngine.isRuntimeAvailable {
            lines.append("SpeechAnalyzer: API доступен (macOS 26+)")
            // warmUp системного движка сам логирует полный список локалей —
            // это и есть искомый ответ. Ошибка прогрева — тоже ответ, не авария.
            do {
                try await system.warmUp()
                lines.append("SpeechAnalyzer: прогрев успешен")
            } catch {
                lines.append("SpeechAnalyzer: прогрев не удался — \(error.localizedDescription)")
            }
            let installed = await system.supportedLanguages()
            let downloadable = await system.downloadableLanguages()
            lines.append("SpeechAnalyzer: языки установлены: [\(Self.list(installed))], можно докачать: [\(Self.list(downloadable))]")
            lines.append("SpeechAnalyzer: русский готов к работе: \(installed.contains(.russian) ? "ДА" : "НЕТ")")
        } else {
            lines.append("SpeechAnalyzer: недоступен — требуется macOS 26, работаем только через WhisperKit")
        }

        // — WhisperKit: модели на диске —
        let installedModels = await modelManager.installedModels()
        if installedModels.isEmpty {
            lines.append("WhisperKit: моделей на диске нет (каталог: \(modelManager.modelsRootURL.path))")
        } else {
            for model in installedModels {
                let sizeMB = Double(model.sizeOnDisk) / 1_048_576
                lines.append(String(format: "WhisperKit: установлена «%@» (%.0f МБ)", model.variant, sizeMB))
            }
        }
        let whisper = await selector.whisper
        lines.append("WhisperKit: языки: [\(Self.list(await whisper.supportedLanguages()))]")

        // — Итог селектора —
        lines.append(await selector.summary(defaultLanguage: defaultLanguage))
        lines.append("=== Конец диагностики ===")

        let report = lines.joined(separator: "\n")
        for line in lines {
            logger.info(line)
        }
        return report
    }

    // MARK: - Железо

    /// Маркетинговое имя чипа через sysctl. На Apple Silicon это «Apple M4 Pro»
    /// и т.п. — ровно то, что нужно видеть в отчёте для интерпретации замеров.
    private static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "неизвестен"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "неизвестен"
        }
        return String(cString: buffer)
    }

    private static func isAppleSilicon() -> Bool {
        // hw.optional.arm64 существует и равен 1 только на ARM-маках
        // (в том числе для x86_64-процесса под Rosetta — нам важно железо, не режим).
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    // MARK: - Apple Intelligence

    /// Статус системной LLM (Foundation Models). Нужен для решения по
    /// постобработке (ТЗ 5.7): доступна — причёсываем ей, нет — Ollama/детерминизм.
    private static func appleIntelligenceStatus() async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "доступен (Foundation Models готовы)"
            case .unavailable(let reason):
                // Причину отдаём как есть — «не включён в настройках» против
                // «модель ещё качается» требуют разных подсказок пользователю.
                return "недоступен: \(String(describing: reason))"
            @unknown default:
                return "статус неизвестен (новый кейс API)"
            }
        } else {
            return "недоступен (требуется macOS 26)"
        }
        #else
        // SDK без FoundationModels (сборка старым Xcode) — честно сообщаем.
        return "недоступен (приложение собрано без FoundationModels)"
        #endif
    }

    // MARK: - Утилиты

    private static func list(_ languages: [RecognitionLanguage]) -> String {
        languages.map(\.rawValue).joined(separator: ", ")
    }
}
