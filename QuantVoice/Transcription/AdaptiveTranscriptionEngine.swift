//
//  AdaptiveTranscriptionEngine.swift
//  Quant Voice
//
//  Мост между акторным EngineSelector и синхронным протоколом TranscriptionEngine.
//
//  Зачем нужен. Координатор по контракту принимает ОДИН движок и читает у него
//  синхронные `displayName` / `isReady`. Селектор же — актор: он выбирает движок
//  асинхронно и может переключаться на лету (системный Apple, если язык есть,
//  иначе WhisperKit). Напрямую эти два мира не стыкуются — синхронный геттер
//  не может ждать актора.
//
//  Решение: этот класс сам реализует TranscriptionEngine, делегирует работу
//  селектору и кэширует те два свойства, которые обязаны отвечать мгновенно.
//  Кэш обновляется на каждом обращении к селектору — то есть всегда отражает
//  движок, который реально работал последним.
//
//  Побочный выигрыш: смена движка в настройках не требует пересборки
//  конвейера — координатор продолжает держать этот же объект.
//

import Foundation

public final class AdaptiveTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {

    private let selector: EngineSelector
    private let logger: any Logging

    /// Язык, с которым будем греться при старте, и он же — дефолт для выбора
    /// движка до первой фразы.
    private let defaultLanguage: RecognitionLanguage

    /// Кэш синхронных свойств протокола. Защищён замком: читается с главного
    /// актора (оверлей, меню), пишется из задач распознавания.
    private let lock = NSLock()
    private var _cachedName: String = "определяется…"
    private var _cachedReady: Bool = false

    public init(selector: EngineSelector,
                defaultLanguage: RecognitionLanguage = .russian,
                logger: any Logging) {
        self.selector = selector
        self.defaultLanguage = defaultLanguage
        self.logger = logger
    }

    // MARK: - TranscriptionEngine

    public var displayName: String {
        lock.lock(); defer { lock.unlock() }
        return _cachedName
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cachedReady
    }

    public func supportedLanguages() async -> [RecognitionLanguage] {
        // Объединение возможностей обоих движков: пользователю важно,
        // поддерживается ли язык хоть чем-то, а не конкретной реализацией.
        let engine = await selector.engine(for: defaultLanguage)
        return await engine.supportedLanguages()
    }

    public func warmUp() async throws {
        await selector.warmUpSelected(defaultLanguage: defaultLanguage)
        await refreshCache(for: defaultLanguage)

        // Прогрев в селекторе не бросает — он логирует и деградирует.
        // Но координатору важно знать, готовы ли мы на самом деле.
        guard isReady else {
            throw TranscriptionError.engineNotReady
        }
        logger.info("Движок распознавания готов: \(displayName)")
    }

    public func transcribe(_ audio: AudioSegment,
                           options: TranscriptionOptions) async throws -> Transcript {
        let engine = await selector.engine(for: options.language)
        updateCache(name: engine.displayName, ready: engine.isReady)

        // Прогрев прогретого движка — бесплатный no-op, но страхует случай,
        // когда селектор переключился на движок, который ещё не грелся
        // (например, пользователь сменил предпочтение в настройках).
        if !engine.isReady {
            logger.info("Движок «\(engine.displayName)» не прогрет — греем перед фразой")
            try await engine.warmUp()
            updateCache(name: engine.displayName, ready: engine.isReady)
        }

        return try await engine.transcribe(audio, options: options)
    }

    public func unload() {
        // Выгрузка синхронная по контракту, а селектор — актор.
        // Отправляем задачу и не ждём: выгрузка не критична по времени,
        // её единственная цель — освободить память при долгом простое.
        let selector = self.selector
        let language = self.defaultLanguage
        Task.detached { [weak self] in
            let engine = await selector.engine(for: language)
            engine.unload()
            self?.updateCache(name: engine.displayName, ready: false)
        }
    }

    // MARK: - Кэш

    private func refreshCache(for language: RecognitionLanguage) async {
        let engine = await selector.engine(for: language)
        updateCache(name: engine.displayName, ready: engine.isReady)
    }

    private func updateCache(name: String, ready: Bool) {
        lock.lock()
        _cachedName = name
        _cachedReady = ready
        lock.unlock()
    }
}
