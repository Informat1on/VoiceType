// AudioDeviceService.swift — VoiceType
//
// Перечисление входных аудиоустройств для пикера микрофона в Settings.
//
// Зачем вообще выбор устройства: это единственный рычаг продукта, который чинит
// ВХОД, а не выход. Bluetooth-гарнитура в режиме гарнитуры (HFP, 8–16 кГц)
// съедает безударные слоги, и никакая постобработка этого не лечит — информация
// потеряна до распознавания. Виртуальные микрофоны (Camo, OBS) дают ту же беду
// молча: в scripts/record-bench.sh это уже ловили, там жёсткое `:0` регулярно
// оказывалось виртуальным устройством.
//
// Почему CoreAudio, а не AVCaptureDevice.DiscoverySession, хотя захват идёт
// через AVCaptureSession: DiscoverySession показывает агрегатные устройства
// (замерено 2026-07-27: `CADefaultDeviceAggregate-69606-0` рядом со встроенным
// микрофоном), которых пользователь у себя в списке не выбирал и в пикере видеть
// не должен. Само по себе перечисление CoreAudio этого не гарантирует —
// у агрегата есть входные каналы, — поэтому отсев делает явный фильтр по
// `kAudioDevicePropertyIsHidden` (см. `isHidden`). При этом UID у обоих API
// один и тот же — проверено на `BuiltInMicrophoneDevice`, — поэтому список
// строится здесь, а устройство для захвата берётся тем же uid через
// `AVCaptureDevice(uniqueID:)`.
//
// Почему идентификатор — UID, а не AudioDeviceID: AudioDeviceID выдаётся
// системой заново и после переподключения устройства меняется. Сохранять в
// настройках можно только UID.

import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    /// UID и есть идентичность: он переживает переподключение и перезапуск.
    var id: String { uid }
    let uid: String
    let name: String
}

enum AudioDeviceError: Error {
    /// Сбой CoreAudio. Отдельно от пустого списка намеренно: «микрофонов нет»
    /// и «спросить не удалось» требуют разного поведения от вызывающего.
    case coreAudioFailed(OSStatus)
}

enum AudioDeviceService {

    /// Устройства с ненулевым числом ВХОДНЫХ каналов. Пустой массив означает,
    /// что входов в системе нет; сбой опроса — это throw, а не пустой массив.
    static func inputDevices() throws -> [AudioInputDevice] {
        try deviceIDs().compactMap { deviceID in
            guard hasInputChannels(deviceID), !isHidden(deviceID) else { return nil }
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty else { return nil }
            let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// UID системного устройства по умолчанию; nil означает, что устройства по
    /// умолчанию нет. Сбой опроса — throw, по той же причине, что и в
    /// `inputDevices()`: «микрофона нет» и «спросить не удалось» ведут к разному
    /// поведению, и склеивать их в один nil значит терять эту разницу.
    static func systemDefaultInputUID() throws -> String? {
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
        guard status == noErr else { throw AudioDeviceError.coreAudioFailed(status) }
        guard deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Слушает И состав устройств, И смену системного устройства по умолчанию:
    /// пикер, открытый в момент подключения гарнитуры, обязан её показать, а
    /// строка «System Default» — перестать врать о том, что за ней стоит.
    /// Обработчик всегда вызывается на main.
    static func observeChanges(_ handler: @escaping () -> Void) -> AudioDeviceObservation {
        AudioDeviceObservation(selectors: [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice
        ], handler: handler)
    }

    // MARK: - CoreAudio

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr else { throw AudioDeviceError.coreAudioFailed(sizeStatus) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { throw AudioDeviceError.coreAudioFailed(status) }
        return ids
    }

    /// Входное устройство — то, у которого в input-scope есть хотя бы один
    /// канал. Наушники и динамики в списке присутствуют, но каналов на вход
    /// у них нет, и в пикер микрофона они попадать не должны.
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Скрытые устройства в пикер не идут. Именно так отсеиваются приватные
    /// агрегаты вроде `CADefaultDeviceAggregate-…`, которые система заводит для
    /// своих нужд: у них есть входные каналы, поэтому фильтр по каналам их не
    /// ловит — а пользователь такого устройства не выбирал и в списке видеть не
    /// должен. Агрегаты, собранные пользователем в Audio MIDI Setup, не скрыты
    /// и остаются в списке: их как раз выбирали осознанно.
    private static func isHidden(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isHidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isHidden)
        // Свойства может не быть — тогда устройство не скрыто.
        return status == noErr && isHidden != 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}

/// Подписка на изменения состава устройств. Отписывается по `cancel()` или при
/// освобождении — забытый слушатель CoreAudio переживает окно настроек и
/// продолжает дёргать замыкание, удерживающее уже закрытый экран.
final class AudioDeviceObservation {

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var isCancelled = false

    init(selectors: [AudioObjectPropertySelector], handler: @escaping () -> Void) {
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            if status == noErr {
                listeners.append((address, block))
            }
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        for (address, block) in listeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &mutableAddress, DispatchQueue.main, block
            )
        }
        listeners.removeAll()
    }

    deinit { cancel() }
}
