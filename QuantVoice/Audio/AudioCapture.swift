//
//  AudioCapture.swift
//  Quant Voice
//
//  Захват звука с микрофона (ТЗ 5.4, веха M1). Реализация `AudioCapturing`.
//
//  • AVAudioEngine + installTap на input node: нужен потоковый доступ к буферам.
//    AVAudioRecorder пишет в файл — запрещён по ТЗ 7.1 («аудио не пишется на диск»).
//  • Устройство отдаёт что угодно (44.1/48 кГц, стерео) — ресемплим на лету
//    в 16 кГц моно float32 через AVAudioConverter. Один конвертер на всю запись:
//    ресемплер хранит состояние фильтра, пересоздавать его на каждый буфер нельзя —
//    будут щелчки на стыках.
//  • Накопление — кольцевой буфер на 5 минут, только в памяти. После stop()/cancel()
//    внутренний буфер затирается нулями (ТЗ 7.1). Снимок, отданный наружу как
//    AudioSegment, живёт до конца распознавания — за его жизненный цикл отвечает
//    координатор.
//  • Уровень: RMS → дБFS → 0…1, сглаживание с быстрой атакой и медленным спадом,
//    эмит ~20 раз в секунду строго на главном потоке.
//  • Смена устройства на лету (воткнули наушники) — ловим
//    AVAudioEngineConfigurationChange и переустанавливаем tap с новым форматом,
//    не теряя уже накопленное.
//
//  Потоки: tap-колбэк приходит на внутреннем аудиопотоке AVAudioEngine.
//  Внутри колбэка — никакого UI и ничего тяжёлого; общее состояние защищено
//  короткими секциями NSLock. Класс помечен @unchecked Sendable: безопасность
//  обеспечена замками вручную, компилятор это проверить не может.
//
//  ⚠️ Для работы нужен ключ NSMicrophoneUsageDescription в Info.plist.
//

import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Ошибки

public enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case deviceUnavailable
    case converterInitFailed
    case engineStartFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону"
        case .deviceUnavailable:
            return "Устройство ввода недоступно"
        case .converterInitFailed:
            return "Не удалось настроить преобразование аудио"
        case .engineStartFailed(let error):
            return "Не удалось запустить захват звука: \(error.localizedDescription)"
        }
    }
}

// MARK: - Кольцевой буфер

/// Кольцевой буфер float-сэмплов фиксированной ёмкости.
///
/// Почему кольцевой, а не просто Array.append: ёмкость ограничена заранее
/// (запись длиннее лимита не раздувает память — старое перезаписывается),
/// и есть явный `erase()`, который физически затирает содержимое нулями (ТЗ 7.1).
/// Потокобезопасность — снаружи (владелец держит замок).
private final class FloatRingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var storedCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Сколько сэмплов накоплено (не больше ёмкости).
    var count: Int { storedCount }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard var src = samples.baseAddress else { return }
        var remaining = samples.count
        guard remaining > 0 else { return }

        // Кусок длиннее всей ёмкости — имеет смысл хранить только его хвост.
        if remaining >= capacity {
            src += remaining - capacity
            remaining = capacity
            writeIndex = 0
            storedCount = 0
        }

        storage.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            var n = remaining
            var offset = 0
            while n > 0 {
                let chunk = min(n, capacity - writeIndex)
                (dstBase + writeIndex).update(from: src + offset, count: chunk)
                writeIndex = (writeIndex + chunk) % capacity
                offset += chunk
                n -= chunk
            }
        }
        storedCount = min(storedCount + remaining, capacity)
    }

    /// Копия накопленного в хронологическом порядке.
    func snapshot() -> [Float] {
        guard storedCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: storedCount)
        storage.withUnsafeBufferPointer { srcBuf in
            guard let src = srcBuf.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { dstBuf in
                guard let dst = dstBuf.baseAddress else { return }
                if storedCount < capacity {
                    // Ещё не заворачивались — данные лежат с нуля.
                    dst.update(from: src, count: storedCount)
                } else {
                    // Завернулись: сначала хвост от writeIndex, потом начало.
                    let tail = capacity - writeIndex
                    dst.update(from: src + writeIndex, count: tail)
                    (dst + tail).update(from: src, count: writeIndex)
                }
            }
        }
        return out
    }

    /// Физически затереть содержимое (ТЗ 7.1), а не просто сбросить индексы.
    func erase() {
        storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        writeIndex = 0
        storedCount = 0
    }
}

// MARK: - Захват

public final class AudioCapture: AudioCapturing, @unchecked Sendable {

    /// 5 минут при 16 кГц ≈ 4.8 млн сэмплов ≈ 19 МБ. Разумный потолок:
    /// диктовка длиннее — экзотика, а память предсказуема.
    private static let ringCapacity = Int(AudioFormat.sampleRate) * 60 * 5

    /// 2048 кадров при 48 кГц ≈ 43 мс — даёт ~23 колбэка в секунду,
    /// как раз под требуемые ~20 обновлений индикатора. Система может
    /// округлить по-своему — это ориентир, а не гарантия.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    /// Ниже этого уровня индикатор считается нулём. -50 дБFS — типичный
    /// шумовой пол комнаты на встроенном микрофоне.
    private static let levelFloorDB: Float = -50

    private let engine = AVAudioEngine()

    /// Защищает capturing / ring / converter / startedAt.
    /// Держится только на короткие операции; вложенных захватов нет.
    private let stateLock = NSLock()
    private var capturing = false
    private var ring: FloatRingBuffer?
    private var converter: AVAudioConverter?
    private var startedAt: Date?

    /// Защищает сглаживание уровня (пишет аудиопоток, сбрасывают start/stop).
    private let levelLock = NSLock()
    private var smoothedLevel: Float = 0
    private var lastLevelEmit: CFAbsoluteTime = 0

    /// Устройство ввода для следующего start(). nil — системный дефолт.
    /// Берётся из AudioDeviceManager (настройки). Меняется только между записями.
    public var preferredDeviceID: AudioDeviceID?

    private var configObserver: (any NSObjectProtocol)?

    // MARK: AudioCapturing

    public private(set) var level: Float = 0 // читается/пишется на главном потоке
    public var onLevelChange: ((Float) -> Void)? // назначать с главного потока

    public var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return capturing
    }

    public init() {
        // Смена конфигурации движка = сменилось устройство ввода или его формат
        // (воткнули наушники, отвалился USB-микрофон). Обрабатываем на главном
        // потоке — переустановка tap не должна гоняться со start()/stop().
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        stateLock.lock()
        let wasCapturing = capturing
        capturing = false
        ring?.erase() // затираем даже при аварийном сносе объекта (ТЗ 7.1)
        ring = nil
        converter = nil
        stateLock.unlock()
        if wasCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    public func start() throws {
        stateLock.lock()
        let alreadyCapturing = capturing
        stateLock.unlock()
        guard !alreadyCapturing else { return } // идемпотентность: повторный start — no-op

        guard Self.permissionStatus() == .granted else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let inputNode = engine.inputNode

        // Явно выбранное устройство подключаем через audio unit входного узла —
        // это единственный способ увести AVAudioEngine с системного дефолта на macOS.
        // Неудача не фатальна: остаёмся на дефолтном устройстве, запись важнее.
        if let deviceID = preferredDeviceID, let unit = inputNode.audioUnit {
            var device = deviceID
            _ = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        // Нулевая частота — микрофона нет вовсе (или доступ отозван на ходу).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.deviceUnavailable
        }
        guard let target = Self.makeTargetFormat(),
              let newConverter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.converterInitFailed
        }

        stateLock.lock()
        converter = newConverter
        ring = FloatRingBuffer(capacity: Self.ringCapacity)
        startedAt = Date()
        capturing = true
        stateLock.unlock()

        levelLock.lock()
        smoothedLevel = 0
        lastLevelEmit = 0
        levelLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Откатываем всё, чтобы объект остался в пригодном состоянии.
            inputNode.removeTap(onBus: 0)
            stateLock.lock()
            capturing = false
            ring?.erase()
            ring = nil
            converter = nil
            startedAt = nil
            stateLock.unlock()
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }
    }

    public func stop() -> AudioSegment? {
        stateLock.lock()
        guard capturing else {
            stateLock.unlock()
            return nil
        }
        capturing = false // с этого момента tap-колбэк ничего не пишет
        let started = startedAt ?? Date()
        let samples = ring?.snapshot() ?? []
        ring?.erase() // внутренний буфер затирается сразу (ТЗ 7.1)
        ring = nil
        converter = nil
        startedAt = nil
        stateLock.unlock()

        tearDownEngine()
        resetLevelIndicator()

        guard !samples.isEmpty else { return nil }
        // ⚠️ Если запись была длиннее ёмкости кольца, начало потеряно и startedAt
        // формально «раньше» первого сэмпла. Для замеров латентности это не мешает.
        return AudioSegment(samples: samples, startedAt: started)
    }

    public func cancel() {
        stateLock.lock()
        let wasCapturing = capturing
        capturing = false
        ring?.erase() // выбрасываем и затираем, наружу не отдаём ничего
        ring = nil
        converter = nil
        startedAt = nil
        stateLock.unlock()

        if wasCapturing {
            tearDownEngine()
            resetLevelIndicator()
        }
    }

    public static func permissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Внутреннее

    private static func makeTargetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AudioFormat.channelCount,
            interleaved: false
        )
    }

    private func tearDownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Вызывается на аудиопотоке AVAudioEngine. Быстро: конвертация, запись
    /// в кольцо, расчёт уровня. Никаких аллокаций сверх выходного буфера,
    /// никаких обращений к UI.
    private func processTap(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard capturing, let converter else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        // Конвертация вне замка: старый конвертер не трогается никем другим,
        // даже если параллельно на главном потоке его уже заменили новым.
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        // Одноразовый источник: отдаём буфер ровно один раз, дальше .noDataNow —
        // иначе конвертер зациклится, запрашивая ещё данные.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else {
            return
        }

        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))

        stateLock.lock()
        ring?.append(samples)
        stateLock.unlock()

        updateLevel(with: samples)
    }

    /// RMS → дБFS → 0…1, сглаживание, троттлинг эмита до ~20 Гц.
    /// Быстрая атака (индикатор мгновенно реагирует на голос) и медленный спад
    /// (не дёргается на паузах между словами).
    private func updateLevel(with samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }

        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        let db = 20 * log10(max(rms, 1e-7))
        let target = max(0, min(1, (db - Self.levelFloorDB) / -Self.levelFloorDB))

        levelLock.lock()
        let alpha: Float = target > smoothedLevel ? 0.55 : 0.20
        smoothedLevel += (target - smoothedLevel) * alpha
        let value = smoothedLevel
        let now = CFAbsoluteTimeGetCurrent()
        let shouldEmit = now - lastLevelEmit >= 0.05
        if shouldEmit { lastLevelEmit = now }
        levelLock.unlock()

        guard shouldEmit else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.level = value
            self.onLevelChange?(value)
        }
    }

    private func resetLevelIndicator() {
        levelLock.lock()
        smoothedLevel = 0
        lastLevelEmit = 0
        levelLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.level = 0
            self.onLevelChange?(0)
        }
    }

    /// Сменилось устройство ввода или его формат посреди записи.
    /// Задача — не упасть и не потерять накопленное: переустанавливаем tap
    /// с новым форматом и новым конвертером, кольцо продолжает ту же запись.
    private func handleConfigurationChange() {
        stateLock.lock()
        let active = capturing
        stateLock.unlock()
        guard active else { return }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let newFormat = inputNode.inputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0,
              let target = Self.makeTargetFormat(),
              let newConverter = AVAudioConverter(from: newFormat, to: target) else {
            // Устройство пропало совсем (выдернули единственный микрофон).
            // Не падаем и не выбрасываем накопленное: запись «замирает»,
            // всё записанное отдастся при stop(). Индикатор — в ноль.
            engine.stop()
            resetLevelIndicator()
            return
        }

        stateLock.lock()
        converter = newConverter
        stateLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: newFormat) { [weak self] buffer, _ in
            self?.processTap(buffer)
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start() // не вышло — поведение как при пропаже устройства
        }
    }
}
