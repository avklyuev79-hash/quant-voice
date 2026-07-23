//
//  AudioDeviceManager.swift
//  Quant Voice
//
//  Устройства ввода звука для настроек (ТЗ 5.4): перечисление, выбор,
//  отслеживание изменений списка.
//
//  Почему CoreAudio, а не AVCaptureDevice.DiscoverySession: CoreAudio отдаёт
//  стабильный UID устройства (kAudioDevicePropertyDeviceUID) — то, что нужно
//  для персистентного выбора в настройках. AudioDeviceID меняется между
//  перезагрузками и переподключениями, хранить его нельзя; хранится UID,
//  а ID резолвится по нему на каждом запуске.
//
//  Потоки: класс рассчитан на главный поток (это API для окна настроек и
//  координатора). Колбэки CoreAudio приходят на DispatchQueue.main — она
//  передана при регистрации слушателей.
//

import CoreAudio
import Foundation

/// Одно устройство ввода. Sendable-снимок, безопасно отдавать куда угодно.
public struct AudioInputDevice: Hashable, Identifiable, Sendable {
    /// Стабильный идентификатор для Identifiable/SwiftUI — UID, а не AudioDeviceID.
    public var id: String { uid }

    /// Живой CoreAudio-идентификатор. Валиден только в текущем сеансе.
    public let deviceID: AudioDeviceID
    /// Стабильный UID — то, что сохраняется в настройках.
    public let uid: String
    /// Человекочитаемое имя («MacBook Pro Microphone», «AirPods Pro»).
    public let name: String
    /// Является ли устройство системным дефолтным входом прямо сейчас.
    public let isDefaultInput: Bool
}

public final class AudioDeviceManager: @unchecked Sendable {

    /// Текущий список устройств ввода. Читать с главного потока.
    public private(set) var devices: [AudioInputDevice] = []

    /// Вызывается на главном потоке при любом изменении списка или дефолтного
    /// устройства — чтобы настройки не опрашивали в цикле.
    public var onDevicesChange: (([AudioInputDevice]) -> Void)?

    // Адреса хранятся в свойствах: для снятия слушателя нужен тот же адрес,
    // что и при установке.
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refresh()
        installListeners()
    }

    deinit {
        removeListeners()
    }

    /// Перечитать список устройств. Вызывается автоматически при изменениях;
    /// вручную нужен разве что в тестах.
    public func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))

        let defaultID = Self.defaultInputDeviceID()
        let list = Self.allDeviceIDs().compactMap { id -> AudioInputDevice? in
            // Устройство без входных каналов (колонки, дисплей) — не микрофон.
            guard Self.inputChannelCount(id) > 0 else { return nil }
            let name = Self.stringProperty(of: id, selector: kAudioObjectPropertyName) ?? "Микрофон \(id)"
            let uid = Self.stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
            return AudioInputDevice(deviceID: id, uid: uid, name: name, isDefaultInput: id == defaultID)
        }

        let changed = list != devices
        devices = list
        if changed {
            onDevicesChange?(list)
        }
    }

    /// Найти устройство по сохранённому UID. nil — устройство сейчас не подключено.
    public func device(withUID uid: String) -> AudioInputDevice? {
        devices.first { $0.uid == uid }
    }

    /// Превратить сохранённый выбор пользователя в живой AudioDeviceID
    /// для AudioCapture.preferredDeviceID. nil на входе или не найдено —
    /// nil на выходе, то есть системный дефолт (безопасный фолбэк:
    /// выбранный микрофон унесли — пишем с дефолтного, а не молчим).
    public func resolveDeviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid else { return nil }
        return device(withUID: uid)?.deviceID
    }

    /// Системное дефолтное устройство ввода.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - Слушатели изменений

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Мы на DispatchQueue.main (передана при регистрации) — можно refresh().
            self?.refresh()
        }
        listenerBlock = block

        let systemID = AudioObjectID(kAudioObjectSystemObject)
        // Один блок на два события: изменился список устройств или сменился дефолт.
        _ = AudioObjectAddPropertyListenerBlock(systemID, &devicesAddress, DispatchQueue.main, block)
        _ = AudioObjectAddPropertyListenerBlock(systemID, &defaultInputAddress, DispatchQueue.main, block)
    }

    private func removeListeners() {
        guard let block = listenerBlock else { return }
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        _ = AudioObjectRemovePropertyListenerBlock(systemID, &devicesAddress, DispatchQueue.main, block)
        _ = AudioObjectRemovePropertyListenerBlock(systemID, &defaultInputAddress, DispatchQueue.main, block)
        listenerBlock = nil
    }

    // MARK: - Чтение свойств CoreAudio

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// Число входных каналов устройства. 0 — это не устройство ввода.
    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        // AudioBufferList переменной длины — читаем в сырую память нужного размера.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, listPtr) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(of id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
