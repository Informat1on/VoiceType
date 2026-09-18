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
    ///
    /// Синхронная и `throws` — но вызывать её напрямую с main нельзя: HAL
    /// виснет навсегда, если coreaudiod мёртв (docs/plans/
    /// coreaudiod-hang-resilience.md). Единственный легальный путь — через
    /// `AudioHALGateway` (см. `loadInputDevices(via:completion:)` ниже);
    /// precondition это закрепляет, а не полагается на дисциплину вызывающих.
    static func inputDevices() throws -> [AudioInputDevice] {
        precondition(AudioHALGateway.isOnGatewayQueue, "HAL — только через AudioHALGateway")
        return try deviceIDs().compactMap { deviceID in
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
        precondition(AudioHALGateway.isOnGatewayQueue, "HAL — только через AudioHALGateway")
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

    /// Через шлюз; completion на main ровно один раз. Единственный легальный
    /// способ для UI спросить список устройств — `inputDevices()` синхронный
    /// и предполагает уже быть на очереди шлюза (precondition выше).
    static func loadInputDevices(
        via gateway: AudioHALGateway = .shared,
        completion: @escaping (Result<[AudioInputDevice], AudioHALError>) -> Void
    ) {
        gateway.perform("loadInputDevices", { try inputDevices() }, completion: completion)
    }

    /// Слушает И состав устройств, И смену системного устройства по умолчанию:
    /// пикер, открытый в момент подключения гарнитуры, обязан её показать, а
    /// строка «System Default» — перестать врать о том, что за ней стоит.
    /// Обработчик всегда вызывается на main. Регистрация/снятие listener'ов
    /// идут через `gateway`, вне main — см. `AudioDeviceObservation`.
    static func observeChanges(via gateway: AudioHALGateway = .shared, _ handler: @escaping () -> Void) -> AudioDeviceObservation {
        AudioDeviceObservation(
            gateway: gateway,
            selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice],
            handler: handler
        )
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

/// Один зарегистрированный CoreAudio listener: адрес + блок, которым его
/// сняли обратно.
private typealias DeviceListenerEntry = (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

/// Подставная (в тестах) или живая функция add/removePropertyListener —
/// вынесены typealias'ами, чтобы сигнатура `init` ниже укладывалась в
/// построчный лимит.
typealias DeviceListenerAdder = (AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
typealias DeviceListenerRemover = (AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> OSStatus

/// Учёт РЕАЛЬНО зарегистрированных listener'ов одной подписки — отдельно от
/// completion шлюза (план, требование 6, ревью раунд 3 P2): `gateway.perform`
/// может отбросить свой результат по таймауту, но регистрация внутри work всё
/// равно продолжает выполняться и добавляет listener'ы в систему — снять их
/// обязан именно этот реестр, а не что-то завязанное на completion.
/// Reference type со своим замком: регистрация (на очереди шлюза) и cleanup
/// (тоже на очереди шлюза, но позже по FIFO) обращаются к нему из разных
/// замыканий.
private final class DeviceListenerRegistry {
    private let lock = NSLock()
    private var isCancelled = false
    private var entries: [DeviceListenerEntry] = []

    /// Проверяется перед КАЖДЫМ `Add…` — если отменено, регистрация дальше не идёт.
    func canRegister() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCancelled
    }

    func recordRegistered(_ entry: DeviceListenerEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        entries.append(entry)
    }

    /// Идемпотентно: помечает отменённым и отдаёт всё, что накопилось К
    /// МОМЕНТУ своего вызова, — включая listener'ы, добавленные регистрацией
    /// уже ПОСЛЕ того, как шлюз отбросил её completion по таймауту. Второй
    /// вызов возвращает пустой список — снимать нечего и незачем дважды.
    func cancelAndDrain() -> [DeviceListenerEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return [] }
        isCancelled = true
        defer { entries.removeAll() }
        return entries
    }
}

/// Подписка на изменения состава устройств. Отписывается по `cancel()` или при
/// освобождении — забытый слушатель CoreAudio переживает окно настроек и
/// продолжает дёргать замыкание, удерживающее уже закрытый экран.
///
/// Регистрация и снятие идут ИСКЛЮЧИТЕЛЬНО через `gateway` — сам HAL с main
/// (или любого другого потока) эта подписка не трогает. `addListener`/
/// `removeListener` — тестовый шов (требование 9 плана): подставные
/// счётчики вместо живого CoreAudio.
final class AudioDeviceObservation {

    private let gateway: AudioHALGateway
    private let registry = DeviceListenerRegistry()
    private let removeListener: DeviceListenerRemover

    init(
        gateway: AudioHALGateway,
        selectors: [AudioObjectPropertySelector],
        handler: @escaping () -> Void,
        addListener: @escaping DeviceListenerAdder = AudioDeviceObservation.liveAddListener,
        removeListener: @escaping DeviceListenerRemover = AudioDeviceObservation.liveRemoveListener
    ) {
        self.gateway = gateway
        self.removeListener = removeListener

        let registry = self.registry
        let registerListeners: () -> Void = {
            for selector in selectors {
                guard registry.canRegister() else { return }
                let address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                // Сам блок HAL не трогает — только вызывает handler на main.
                let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
                if addListener(address, block) == noErr {
                    registry.recordRegistered((address, block))
                }
            }
        }
        // Результат не используется для учёта регистрации — см. doc
        // DeviceListenerRegistry выше.
        gateway.perform("observeDeviceChanges", registerListeners, completion: { _ in })
    }

    /// С main HAL не трогает — снятие уходит в очередь шлюза и выполнится,
    /// когда та освободится (даже если сейчас `.unresponsive`).
    func cancel() {
        let registry = self.registry
        let removeListener = self.removeListener
        gateway.enqueueCleanup("cancelDeviceObservation") {
            for entry in registry.cancelAndDrain() {
                _ = removeListener(entry.0, entry.1)
            }
        }
    }

    deinit { cancel() }

    /// Очередь доставки — `DispatchQueue.main`: обработчик листенера
    /// (переданный CoreAudio-блок) сам HAL не трогает, только зовёт handler.
    private static func liveAddListener(
        _ address: AudioObjectPropertyAddress,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var mutableAddress = address
        return AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &mutableAddress, DispatchQueue.main, block
        )
    }

    private static func liveRemoveListener(
        _ address: AudioObjectPropertyAddress,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var mutableAddress = address
        return AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &mutableAddress, DispatchQueue.main, block
        )
    }
}
