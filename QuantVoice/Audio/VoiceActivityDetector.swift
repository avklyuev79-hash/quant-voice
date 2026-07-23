//
//  VoiceActivityDetector.swift
//  Quant Voice
//
//  Детектор речи (ТЗ 6.3, веха M1). Зачем:
//  (а) скорость — не декодируем паузы;
//  (б) точность — Whisper на тишине склонен выдумывать текст;
//  (в) границы фраз пригодятся для расстановки пунктуации (ТЗ 5.7, уровень 3).
//
//  На этой вехе — энергетический детектор: адаптивный порог по уровню шума,
//  гистерезис, минимальные длительности речи и паузы. Позже подменяется на
//  Silero VAD в CoreML — для этого весь VAD спрятан за протоколом
//  `VoiceActivityDetecting` (см. ниже): координатор знает только протокол,
//  Silero-реализация станет ещё одним классом за ним же.
//

import Accelerate
import Foundation

// MARK: - Протокол

/// Интервал одной фразы. Секунды ОТ НАЧАЛА обрезанного сегмента
/// (того, что уходит в модель), не от начала исходной записи.
public struct PhraseInterval: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public var duration: TimeInterval { end - start }

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Результат прохода VAD по записи.
public struct VoiceActivityResult: Sendable {
    /// Запись без ведущей и хвостовой тишины. Паузы МЕЖДУ фразами сохранены —
    /// вырезание середины ломало бы тайминги для пунктуации.
    /// nil — речи не найдено вовсе (в модель подавать нечего).
    public let trimmed: AudioSegment?

    /// Найденные фразы в координатах `trimmed`. Пусто, если речи нет.
    public let phrases: [PhraseInterval]

    public var speechDetected: Bool { trimmed != nil }

    public init(trimmed: AudioSegment?, phrases: [PhraseInterval]) {
        self.trimmed = trimmed
        self.phrases = phrases
    }
}

/// Протокол детектора речи. Название выбрано в ряд с контрактными
/// `AudioCapturing` / `HotkeyMonitoring`.
///
/// Контракт: реализация не бросает и не блокирует надолго — это чистая
/// функция над сэмплами. Будущая Silero-реализация (CoreML) обязана
/// уложиться в ту же сигнатуру; если ей понадобится async-прогрев модели,
/// он делается в её собственном init/warmUp, протокол не меняется.
public protocol VoiceActivityDetecting: AnyObject {
    /// Найти речь: вернуть сегмент без ведущей и хвостовой тишины
    /// плюс границы фраз внутри него.
    func process(_ segment: AudioSegment) -> VoiceActivityResult
}

// MARK: - Энергетический детектор

/// Энергетический VAD: кадрирование, RMS-энергия в дБFS, адаптивная оценка
/// шумового пола, гистерезис входа/выхода из речи.
///
/// Почему адаптивный порог, а не фиксированный: «тишина» у встроенного
/// микрофона MacBook в кафе и у гарнитуры в тихом кабинете отличается на
/// десятки дБ. Порог привязан к оценке шумового пола конкретной записи.
///
/// Почему гистерезис: один порог заставляет детектор дребезжать на границе
/// (речь/не-речь каждый кадр). Порог входа выше порога выхода — начали
/// уверенно, держим до явного спада.
///
/// Класс без состояния между вызовами (все поля — let), поэтому Sendable.
public final class EnergyVoiceActivityDetector: VoiceActivityDetecting, Sendable {

    /// Настройки. Дефолты подобраны консервативно: лучше отдать в модель
    /// лишние полсекунды тишины, чем отрезать тихое начало слова.
    public struct Tuning: Sendable {
        /// Длина кадра анализа. 20 мс — стандарт для VAD (и кадр Silero).
        public var frameDuration: TimeInterval = 0.02
        /// Насколько кадр должен быть громче шумового пола, чтобы ВОЙТИ в речь.
        public var enterMarginDB: Float = 9
        /// Насколько громче пола, чтобы ОСТАВАТЬСЯ в речи (гистерезис).
        public var exitMarginDB: Float = 5
        /// Абсолютный пол: тише этого речи не бывает, какой бы низкой ни была
        /// оценка шума. Страхует от «речи» в цифровой тишине заглушенного микрофона.
        public var absoluteFloorDB: Float = -60
        /// Скорость подъёма оценки шума (дБ/с). Вниз оценка падает мгновенно
        /// (тишина — надёжное свидетельство), вверх ползёт медленно, чтобы
        /// длинная фраза не «стала шумом».
        public var noiseRiseDBPerSecond: Float = 3
        /// Всплески короче этого — не речь (щелчок мыши, стук по столу).
        public var minSpeechDuration: TimeInterval = 0.15
        /// Паузы короче этой не разрывают фразу (дыхание, запинка).
        public var minSilenceBetweenPhrases: TimeInterval = 0.30
        /// Отступ вокруг найденной речи — чтобы не срезать тихие согласные
        /// на границах слов.
        public var padding: TimeInterval = 0.15

        public init() {}
    }

    private let tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func process(_ segment: AudioSegment) -> VoiceActivityResult {
        let samples = segment.samples
        let rate = segment.sampleRate
        guard rate > 0, !samples.isEmpty else {
            return VoiceActivityResult(trimmed: nil, phrases: [])
        }

        let frameLength = max(16, Int(rate * tuning.frameDuration))
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else {
            // Короче одного кадра — решать нечего, отдаём как есть.
            return VoiceActivityResult(
                trimmed: segment,
                phrases: [PhraseInterval(start: 0, end: segment.duration)]
            )
        }
        let frameDuration = Double(frameLength) / rate

        // 1. Энергия каждого кадра в дБFS.
        var frameDB = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<frameCount {
                var rms: Float = 0
                vDSP_rmsqv(base + i * frameLength, 1, &rms, vDSP_Length(frameLength))
                // 1e-7 ≈ -140 дБ: защита log10 от нуля в цифровой тишине.
                frameDB[i] = 20 * log10(max(rms, 1e-7))
            }
        }

        // 2. Разметка кадров: адаптивный пол + гистерезис.
        //
        // Начальная оценка пола — минимум по всей записи: работаем офлайн по
        // готовому сегменту, можем себе позволить глобальную статистику.
        // Инициализация первым кадром здесь опасна: если пользователь начал
        // говорить сразу после нажатия хоткея, первый кадр — уже речь,
        // и порог уехал бы вверх на уровень голоса.
        let risePerFrame = tuning.noiseRiseDBPerSecond * Float(frameDuration)
        var noiseFloor = frameDB.min() ?? tuning.absoluteFloorDB
        var speechFlags = [Bool](repeating: false, count: frameCount)
        var inSpeech = false
        for i in 0..<frameCount {
            let db = frameDB[i]
            if db < noiseFloor {
                noiseFloor = db // вниз — мгновенно
            } else if !inSpeech {
                noiseFloor += risePerFrame // вверх — медленно и только вне речи
            }
            let enter = max(noiseFloor + tuning.enterMarginDB, tuning.absoluteFloorDB)
            let exit = max(noiseFloor + tuning.exitMarginDB, tuning.absoluteFloorDB)
            inSpeech = inSpeech ? (db >= exit) : (db >= enter)
            speechFlags[i] = inSpeech
        }

        // 3. Кадры → интервалы речи (в кадрах, end — эксклюзивный).
        var regions: [(start: Int, end: Int)] = []
        var regionStart: Int?
        for i in 0..<frameCount {
            if speechFlags[i] {
                if regionStart == nil { regionStart = i }
            } else if let s = regionStart {
                regions.append((s, i))
                regionStart = nil
            }
        }
        if let s = regionStart {
            regions.append((s, frameCount))
        }

        // 4. Слить регионы через короткие паузы (дыхание не разрывает фразу)…
        let minSilenceFrames = max(1, Int(tuning.minSilenceBetweenPhrases / frameDuration))
        var merged: [(start: Int, end: Int)] = []
        for region in regions {
            if var last = merged.last, region.start - last.end < minSilenceFrames {
                last.end = region.end
                merged[merged.count - 1] = last
            } else {
                merged.append(region)
            }
        }

        // …и выбросить одиночные короткие всплески (щелчки, стуки).
        let minSpeechFrames = max(1, Int(tuning.minSpeechDuration / frameDuration))
        let phraseRegions = merged.filter { $0.end - $0.start >= minSpeechFrames }
        guard let first = phraseRegions.first, let last = phraseRegions.last else {
            return VoiceActivityResult(trimmed: nil, phrases: [])
        }

        // 5. Обрезка: от первой фразы до последней, с отступами.
        // Середина (паузы между фразами) сохраняется — см. VoiceActivityResult.
        let padSamples = Int(tuning.padding * rate)
        let startSample = max(0, first.start * frameLength - padSamples)
        let endSample = min(samples.count, last.end * frameLength + padSamples)
        let trimmedSamples = Array(samples[startSample..<endSample])
        let leadOffset = Double(startSample) / rate
        let trimmedDuration = Double(trimmedSamples.count) / rate

        // startedAt сдвигаем на срезанное начало: точка отсчёта латентности —
        // момент, которому соответствует первый сэмпл сегмента.
        let trimmedSegment = AudioSegment(
            samples: trimmedSamples,
            sampleRate: rate,
            startedAt: segment.startedAt.addingTimeInterval(leadOffset)
        )

        // 6. Границы фраз в координатах обрезанного сегмента, с теми же отступами.
        let phrases = phraseRegions.map { region -> PhraseInterval in
            let start = max(0, Double(region.start * frameLength - padSamples) / rate - leadOffset)
            let end = min(trimmedDuration, Double(region.end * frameLength + padSamples) / rate - leadOffset)
            return PhraseInterval(start: start, end: end)
        }

        return VoiceActivityResult(trimmed: trimmedSegment, phrases: phrases)
    }
}
