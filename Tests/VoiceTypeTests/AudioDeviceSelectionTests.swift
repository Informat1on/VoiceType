import XCTest
@testable import VoiceType

/// Решения из пути записи, которые нельзя проверить живым микрофоном: выбор
/// устройства при отсутствующей гарнитуре и судьба прерванной записи. Ровно
/// поэтому они и вынесены в чистые функции.
final class AudioDeviceSelectionTests: XCTestCase {

    // MARK: - Выбор устройства

    func testNilPreferenceUsesSystemDefault() {
        let decision = AudioDeviceResolver.resolve(
            preferredUID: nil,
            availableUIDs: ["BuiltInMicrophoneDevice"],
            systemDefaultUID: "BuiltInMicrophoneDevice"
        )
        XCTAssertEqual(decision, .useSystemDefault(uid: "BuiltInMicrophoneDevice"))
    }

    func testAvailablePreferenceIsUsed() {
        let decision = AudioDeviceResolver.resolve(
            preferredUID: "USB-Mic",
            availableUIDs: ["BuiltInMicrophoneDevice", "USB-Mic"],
            systemDefaultUID: "BuiltInMicrophoneDevice"
        )
        XCTAssertEqual(decision, .usePreferred(uid: "USB-Mic"))
    }

    /// Гарнитуру отключили: пишем с системного, но выбор пользователя остаётся
    /// в настройках — устройство вернётся.
    func testMissingPreferenceFallsBackAndReportsWhy() {
        let decision = AudioDeviceResolver.resolve(
            preferredUID: "AirPods",
            availableUIDs: ["BuiltInMicrophoneDevice"],
            systemDefaultUID: "BuiltInMicrophoneDevice"
        )
        XCTAssertEqual(
            decision,
            .fallback(uid: "BuiltInMicrophoneDevice",
                      reason: .selectedDeviceUnavailable(uid: "AirPods"))
        )
    }

    /// Выбранное совпадает с системным: отдельная ветка, потому что откатываться
    /// при сбое некуда, и обещать запасной путь было бы неправдой.
    func testPreferenceEqualToSystemDefaultIsNotAFallbackCase() {
        let decision = AudioDeviceResolver.resolve(
            preferredUID: "BuiltInMicrophoneDevice",
            availableUIDs: ["BuiltInMicrophoneDevice"],
            systemDefaultUID: "BuiltInMicrophoneDevice"
        )
        XCTAssertEqual(decision, .useSystemDefault(uid: "BuiltInMicrophoneDevice"))
    }

    func testNoDevicesAtAll() {
        XCTAssertEqual(
            AudioDeviceResolver.resolve(preferredUID: nil, availableUIDs: [], systemDefaultUID: nil),
            .noDevice
        )
        XCTAssertEqual(
            AudioDeviceResolver.resolve(preferredUID: "AirPods", availableUIDs: [], systemDefaultUID: nil),
            .noDevice
        )
    }

    // MARK: - Прерванная запись

    func testInterruptionWithAudioTranscribesPartial() {
        XCTAssertEqual(
            CaptureInterruptionDecision.decide(isRecording: true, sampleCount: 16000),
            .transcribePartial
        )
    }

    func testInterruptionWithoutAudioShowsError() {
        XCTAssertEqual(
            CaptureInterruptionDecision.decide(isRecording: true, sampleCount: 0),
            .showError
        )
    }

    /// Событие пришло, когда запись уже останавливалась: молчим, иначе
    /// пользователь увидит ошибку на успешно завершённой записи.
    func testInterruptionWhileNotRecordingIsIgnored() {
        XCTAssertEqual(
            CaptureInterruptionDecision.decide(isRecording: false, sampleCount: 16000),
            .ignore
        )
        XCTAssertEqual(
            CaptureInterruptionDecision.decide(isRecording: false, sampleCount: 0),
            .ignore
        )
    }

    // MARK: - Хранение выбора

    @MainActor
    func testPreferredDeviceRoundTripsThroughDefaults() throws {
        let suiteName = "voicetype.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.preferredInputDeviceUID, "по умолчанию — системное устройство")

        settings.preferredInputDeviceUID = "USB-Mic"
        XCTAssertEqual(defaults.string(forKey: "preferredInputDeviceUID"), "USB-Mic")
        XCTAssertEqual(AppSettings(defaults: defaults).preferredInputDeviceUID, "USB-Mic")
    }

    /// nil обязан удалять ключ, а не писать пустую строку: иначе «не выбрано» и
    /// «выбрано пустое» разойдутся при следующем чтении.
    @MainActor
    func testClearingPreferredDeviceRemovesTheKey() throws {
        let suiteName = "voicetype.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.preferredInputDeviceUID = "USB-Mic"
        settings.preferredInputDeviceUID = nil

        XCTAssertNil(defaults.object(forKey: "preferredInputDeviceUID"))
        XCTAssertNil(AppSettings(defaults: defaults).preferredInputDeviceUID)
    }

    // MARK: - Перечисление устройств

    /// Живая проверка на машине разработчика: встроенный микрофон есть всегда,
    /// и его UID обязан совпадать с тем, по которому захват берёт устройство.
    ///
    /// `AudioDeviceService.inputDevices()` теперь требует очереди
    /// `AudioHALGateway` (precondition, docs/plans/coreaudiod-hang-resilience.md,
    /// задача 1) — идёт через НЕстандартный экземпляр шлюза, не `.shared`, чтобы
    /// не делить состояние здоровья с прочими тестами. Если coreaudiod не
    /// отвечает, тест не виснет — сам шлюз укладывается в срок и отдаёт
    /// `.unresponsive`, дальше `XCTSkip`.
    func testCoreAudioEnumerationReturnsUsableUIDs() throws {
        let testGateway = AudioHALGateway(
            label: "test.audio.hal.enumeration.\(UUID().uuidString)",
            defaultTimeout: 4.0
        )
        let exp = expectation(description: "devices loaded")
        var loadedResult: Result<[AudioInputDevice], AudioHALError>?
        AudioDeviceService.loadInputDevices(via: testGateway) { result in
            loadedResult = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        switch try XCTUnwrap(loadedResult) {
        case .success(let devices):
            XCTAssertFalse(devices.isEmpty, "на машине с микрофоном список не может быть пустым")
            for device in devices {
                XCTAssertFalse(device.uid.isEmpty)
                XCTAssertFalse(device.name.isEmpty)
                XCTAssertEqual(device.id, device.uid)
            }
        case .failure(.unresponsive):
            throw XCTSkip("coreaudiod не отвечает")
        case .failure(.failed(let message)):
            XCTFail("CoreAudio enumeration failed: \(message)")
        }
    }

    /// Второй живой тест (план, требование 9): `performSync` реального
    /// `AudioDeviceService.systemDefaultInputUID()` на очереди подставленного
    /// шлюза не трапает на precondition — доказывает, что проверка
    /// `isOnGatewayQueue` смотрит на очередь ЛЮБОГО шлюза, а не только
    /// `.shared`. `performSync` запрещён на main — гоним с фоновой очереди.
    func testSystemDefaultInputUIDViaGatewayPerformSyncDoesNotTrapOnPrecondition() throws {
        let testGateway = AudioHALGateway(
            label: "test.audio.hal.default.\(UUID().uuidString)",
            defaultTimeout: 4.0
        )
        let exp = expectation(description: "performSync completed off main")
        var outcome: Result<String?, AudioHALError>?
        DispatchQueue.global().async {
            outcome = testGateway.performSync("systemDefaultInputUID") {
                try AudioDeviceService.systemDefaultInputUID()
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        switch try XCTUnwrap(outcome) {
        case .success:
            break // отсутствие trap'а на precondition — и есть то, что тест доказывает.
        case .failure(.unresponsive):
            throw XCTSkip("coreaudiod не отвечает")
        case .failure(.failed(let message)):
            XCTFail("systemDefaultInputUID failed: \(message)")
        }
    }
}
