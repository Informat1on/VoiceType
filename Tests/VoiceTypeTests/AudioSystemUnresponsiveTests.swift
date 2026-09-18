// AudioSystemUnresponsiveTests.swift — VoiceType
//
// docs/plans/coreaudiod-hang-resilience.md, задача 2: доказывает перевод
// AudioCaptureService на AudioHALGateway — порядок отказов на старте, точная
// ошибка при мёртвом демоне, ограниченное ожидание на остановке — без живого
// микрофона и без живого CoreAudio (каждый тест создаёт свой экземпляр
// AudioHALGateway, а не .shared).
//
// Инфраструктура (FakeStartRunner/ManualWatchdogScheduler/makeTestBundle)
// переиспользует форму швов из AudioStartTimeoutTests.swift, но не сами типы:
// они там `private`, а Swift `private` на верхнем уровне файла — file-scoped,
// поэтому здесь заведены собственные, более лёгкие копии.

import XCTest
import AVFoundation
@testable import VoiceType

final class AudioSystemUnresponsiveTests: XCTestCase {

    // MARK: - Инфраструктура

    private final class FakeStartRunner {
        struct Invocation {
            let attemptID: StartAttemptID
            let preferredDeviceUID: String?
            let completion: StartOperationCompletion
        }

        private(set) var invocations: [Invocation] = []

        var runner: StartOperationRunner {
            { [weak self] attemptID, preferredDeviceUID, completion in
                self?.invocations.append(Invocation(attemptID: attemptID, preferredDeviceUID: preferredDeviceUID, completion: completion))
            }
        }

        func resolve(at index: Int, _ outcome: StartOutcome) {
            invocations[index].completion(outcome)
        }
    }

    /// Watchdog на виртуальных часах, который тест стреляет вручную —
    /// нужен только тесту 3 (watchdog при нездоровом шлюзе).
    private final class ManualWatchdogScheduler: WatchdogScheduling {
        private final class Token {}
        private var pending: [ObjectIdentifier: () -> Void] = [:]
        private var order: [ObjectIdentifier] = []

        func scheduleWatchdog(after seconds: TimeInterval, action: @escaping () -> Void) -> AnyObject {
            let token = Token()
            let id = ObjectIdentifier(token)
            pending[id] = action
            order.append(id)
            return token
        }

        func cancelWatchdog(_ token: AnyObject) {
            guard let token = token as? Token else { return }
            pending.removeValue(forKey: ObjectIdentifier(token))
        }

        func fireLatest() {
            guard let id = order.last(where: { pending[$0] != nil }) else { return }
            pending.removeValue(forKey: id)?()
        }
    }

    /// Watchdog, который никогда не стреляет — используется там, где тест
    /// хочет доказать, что исход пришёл ПО ДРУГОЙ причине (шлюз), не по
    /// watchdog'у, и настоящие 4с ждать не готов.
    private final class NeverFiringWatchdogScheduler: WatchdogScheduling {
        func scheduleWatchdog(after seconds: TimeInterval, action: @escaping () -> Void) -> AnyObject { NSObject() }
        func cancelWatchdog(_ token: AnyObject) {}
    }

    private static var nextTestCandidateValue = 0
    private static func makeTestCandidateID() -> SessionCandidateID {
        nextTestCandidateValue += 1
        return SessionCandidateID(value: nextTestCandidateValue)
    }

    /// Настоящий (но никогда не запускавшийся) `StartedBundle` — как в
    /// AudioStartTimeoutTests: `AVCaptureSession`/`AVCaptureAudioDataOutput` не
    /// требуют оборудования для конструирования, `AVAudioFile(forWriting:)` —
    /// обычный временный файл.
    private static func makeTestBundle(deviceUID: String?) throws -> StartedBundle {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSystemUnresponsiveTests-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        return StartedBundle(
            candidateID: makeTestCandidateID(),
            session: AVCaptureSession(),
            output: AVCaptureAudioDataOutput(),
            writer: file,
            writerFormat: format,
            url: url,
            deviceUID: deviceUID,
            deviceName: deviceUID.map { "Test Device \($0)" },
            fallbackReason: nil
        )
    }

    // MARK: - 1. Порядок отказов: .idle + шлюз мёртв → audioSystemUnresponsive, runner не вызван

    func testStartWithUnresponsiveGatewayFailsImmediatelyWithoutRunner() {
        let gateway = AudioHALGateway(label: "test.idle.\(UUID().uuidString)", defaultTimeout: 2.0, log: { _ in })
        let stall = AudioHALStallToken(label: "unresponsive")
        gateway.beginStall(stall)

        let service = AudioCaptureService()
        service.halGateway = gateway
        var runnerCalled = false
        service.startOperationRunner = { _, _, _ in runnerCalled = true }

        let exp = expectation(description: "audioSystemUnresponsive")
        service.startRecording(preferredDeviceUID: nil, timeout: 4.0) { result in
            guard case .failure(.audioSystemUnresponsive) = result else { return XCTFail("expected audioSystemUnresponsive, got \(result)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(runnerCalled, "beginSessionAttempt must never run while the gateway is already dead")

        // Сервис остался .idle сам по себе (не "занят") — после того, как
        // демон отпустят, тот же старт нормально доходит до runner'а.
        gateway.endStall(stall)
        var secondRunnerCalled = false
        let secondExp = expectation(description: "next start reaches runner")
        service.startOperationRunner = { _, _, completion in
            secondRunnerCalled = true
            completion(.failure(.sessionDidNotStart))
        }
        service.startRecording(preferredDeviceUID: nil, timeout: 4.0) { _ in secondExp.fulfill() }
        wait(for: [secondExp], timeout: 1)
        XCTAssertTrue(secondRunnerCalled, "service must still be .idle, not stuck")
    }

    // MARK: - Порядок отказов: .recording игнорирует здоровье шлюза (план, задача 2, п.2)

    func testStartWhileRecordingIgnoresUnhealthyGatewayAndKeepsRecording() throws {
        let gateway = AudioHALGateway(label: "test.recording.\(UUID().uuidString)", defaultTimeout: 2.0, log: { _ in })
        let runner = FakeStartRunner()
        let service = AudioCaptureService()
        service.halGateway = gateway
        service.watchdogScheduler = NeverFiringWatchdogScheduler()
        service.startOperationRunner = runner.runner

        let bundle = try Self.makeTestBundle(deviceUID: "dev-A")
        let startExp = expectation(description: "started")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            startExp.fulfill()
        }
        runner.resolve(at: 0, .success(bundle))
        wait(for: [startExp], timeout: 1)

        // Демон "умирает" уже ПОСЛЕ того, как сервис реально пишет — нельзя
        // отдать «система мертва», пока идёт настоящая запись.
        let stall = AudioHALStallToken(label: "external")
        gateway.beginStall(stall)

        let busyExp = expectation(description: "alreadyRecording despite unhealthy gateway")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .failure(.alreadyRecording) = result else { return XCTFail("expected alreadyRecording, got \(result)") }
            busyExp.fulfill()
        }
        wait(for: [busyExp], timeout: 1)

        // .recording не тронуто — обычная остановка всё ещё проходит штатно.
        gateway.endStall(stall)
        XCTAssertNoThrow(try service.stopRecording())
    }

    // MARK: - 2. Реальный beginSessionAttempt с заблокированной очередью шлюза → audioSystemUnresponsive

    func testRealBeginSessionAttemptWithBlockedGatewayQueueYieldsAudioSystemUnresponsive() {
        let blockSemaphore = DispatchSemaphore(value: 0)
        let gateway = AudioHALGateway(label: "test.blocked.\(UUID().uuidString)", defaultTimeout: 0.15, log: { _ in })
        // Занимает очередь шлюза ДО того, как beginSessionAttempt поставит туда
        // resolveDevices — симулирует зависший CoreAudio-вызов другого клиента.
        gateway.enqueueCleanup("occupyQueue") { blockSemaphore.wait() }

        let service = AudioCaptureService()
        service.halGateway = gateway
        service.watchdogScheduler = NeverFiringWatchdogScheduler()
        // startOperationRunner НЕ подменяется — реальный performStartOperation
        // уходит на sessionQueue и вызывает настоящий beginSessionAttempt.

        let exp = expectation(description: "audioSystemUnresponsive via real beginSessionAttempt")
        service.startRecording(preferredDeviceUID: nil, timeout: 4.0) { result in
            guard case .failure(.audioSystemUnresponsive) = result else { return XCTFail("expected audioSystemUnresponsive, got \(result)") }
            exp.fulfill()
        }
        // Срок шлюза 0.15с — исход приходит быстро; watchdog (никогда не
        // стреляющий в этом тесте) не участвует вовсе.
        wait(for: [exp], timeout: 2)

        blockSemaphore.signal() // освобождаем occupyQueue, чтобы не утекал поток
    }

    // MARK: - 3. Watchdog при нездоровом шлюзе → audioSystemUnresponsive, не sessionStartTimedOut

    func testWatchdogFiresAudioSystemUnresponsiveWhenGatewayUnhealthy() {
        let gateway = AudioHALGateway(label: "test.watchdog.\(UUID().uuidString)", defaultTimeout: 2.0, log: { _ in })
        let scheduler = ManualWatchdogScheduler()
        let runner = FakeStartRunner()
        let service = AudioCaptureService()
        service.halGateway = gateway
        service.watchdogScheduler = scheduler
        service.startOperationRunner = runner.runner

        let exp = expectation(description: "audioSystemUnresponsive from watchdog")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.audioSystemUnresponsive) = result else { return XCTFail("expected audioSystemUnresponsive, got \(result)") }
            exp.fulfill()
        }
        XCTAssertEqual(runner.invocations.count, 1)

        let stall = AudioHALStallToken(label: "external")
        gateway.beginStall(stall) // демон "умирает" пока попытка ещё .starting

        scheduler.fireLatest()
        wait(for: [exp], timeout: 1)

        gateway.endStall(stall)
    }

    // MARK: - 4. Остановка с зависшим sessionStopper: ограниченное ожидание, .abandoning, восстановление

    func testStopWithHangingSessionStopperAbandonsWithinTimeoutAndRecoversAfterRelease() throws {
        let gateway = AudioHALGateway(label: "test.stop.\(UUID().uuidString)", defaultTimeout: 2.0, log: { _ in })
        let runner = FakeStartRunner()
        let service = AudioCaptureService()
        service.halGateway = gateway
        service.watchdogScheduler = NeverFiringWatchdogScheduler()
        service.startOperationRunner = runner.runner
        service.stopTimeout = 0.2

        let hangSemaphore = DispatchSemaphore(value: 0)
        service.sessionStopper = { _ in hangSemaphore.wait() }

        let bundle = try Self.makeTestBundle(deviceUID: "dev-A")
        let startExp = expectation(description: "started")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            startExp.fulfill()
        }
        runner.resolve(at: 0, .success(bundle))
        wait(for: [startExp], timeout: 1)

        // Остановка обязана вернуться за stopTimeout + запас — sessionStopper
        // никогда не возвращается, main не вправе ждать его вечно.
        let before = Date()
        let samples = try service.stopRecording()
        let elapsed = Date().timeIntervalSince(before)
        XCTAssertLessThan(elapsed, 0.6, "stop must return within stopTimeout + margin, not hang")
        XCTAssertEqual(samples, [], "no real audio was ever fed through the fake pipeline — empty is the honest result")

        // Гейт открыл внешний застой: шлюз .unresponsive сразу после возврата
        // (beginStall вызван синхронно до выхода из stopRecordingCore).
        guard case .unresponsive = gateway.health else { return XCTFail("expected gateway unresponsive after stop timeout") }

        // Следующий старт: state == .abandoning + шлюз мёртв → audioSystemUnresponsive.
        let busyExp = expectation(description: "audioSystemUnresponsive while abandoning")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .failure(.audioSystemUnresponsive) = result else { return XCTFail("expected audioSystemUnresponsive, got \(result)") }
            busyExp.fulfill()
        }
        wait(for: [busyExp], timeout: 1)
        XCTAssertEqual(runner.invocations.count, 1, "must not reach the runner while still abandoning")

        // Отпускаем зависший стоппер — фоновый блок закрывает застой сам.
        hangSemaphore.signal()

        let recoveredExp = expectation(description: "gateway healthy again")
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in
            if case .healthy = gateway.health { recoveredExp.fulfill() }
        }
        wait(for: [recoveredExp], timeout: 1)
        NotificationCenter.default.removeObserver(observer)

        // Сервис снова .idle — следующий старт достигает runner'а.
        let acceptedExp = expectation(description: "accepted after recovery")
        service.startRecording(preferredDeviceUID: "dev-C", timeout: 4.0) { _ in acceptedExp.fulfill() }
        XCTAssertEqual(runner.invocations.count, 2, "service must be idle again — reaches the runner")
        runner.resolve(at: 1, .failure(.sessionDidNotStart))
        wait(for: [acceptedExp], timeout: 1)
    }

    // MARK: - 5. Гонка на границе stopTimeout: сходимость без "вечного" .abandoning и без утёкшего застоя

    func testStopRaceAtTimeoutBoundaryNeverLeavesStuckAbandoningOrLeakedStall() throws {
        for trial in 0..<5 {
            let gateway = AudioHALGateway(label: "test.race.\(trial).\(UUID().uuidString)", defaultTimeout: 2.0, log: { _ in })
            let runner = FakeStartRunner()
            let service = AudioCaptureService()
            service.halGateway = gateway
            service.watchdogScheduler = NeverFiringWatchdogScheduler()
            service.startOperationRunner = runner.runner
            service.stopTimeout = 0.1
            // Стоппер финиширует ровно на границе stopTimeout — гонка шага 4 плана
            // между main-таймаутом и фоновым завершением sessionStopper.
            service.sessionStopper = { _ in Thread.sleep(forTimeInterval: 0.1) }

            let bundle = try Self.makeTestBundle(deviceUID: "dev-\(trial)")
            let startExp = expectation(description: "started \(trial)")
            service.startRecording(preferredDeviceUID: "dev-\(trial)", timeout: 4.0) { result in
                guard case .success = result else { return XCTFail("expected success, got \(result)") }
                startExp.fulfill()
            }
            runner.resolve(at: 0, .success(bundle))
            wait(for: [startExp], timeout: 1)

            XCTAssertNoThrow(try service.stopRecording(), "trial \(trial): stop must not throw at the timeout boundary")

            // Сходимость: либо шлюз уже .healthy (успели в срок), либо фоновый
            // блок шага 3 закроет "свой" застой чуть позже — но НИКОГДА не
            // остаётся открытым (требование плана: никогда не .abandoning навсегда).
            let healthyExp = expectation(description: "healthy eventually \(trial)")
            var observer: NSObjectProtocol?
            if case .healthy = gateway.health {
                healthyExp.fulfill()
            } else {
                observer = NotificationCenter.default.addObserver(
                    forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
                ) { _ in
                    if case .healthy = gateway.health { healthyExp.fulfill() }
                }
            }
            wait(for: [healthyExp], timeout: 1)
            if let observer { NotificationCenter.default.removeObserver(observer) }

            // Сервис сходится к .idle — следующий старт всегда достигает runner'а,
            // не остаётся подвешенным без ответа.
            let acceptedExp = expectation(description: "idle after race \(trial)")
            service.startRecording(preferredDeviceUID: "dev-\(trial)-next", timeout: 4.0) { _ in acceptedExp.fulfill() }
            XCTAssertEqual(runner.invocations.count, 2, "trial \(trial): must converge to .idle — next start reaches the runner")
            runner.resolve(at: 1, .failure(.sessionDidNotStart))
            wait(for: [acceptedExp], timeout: 1)
        }
    }
}
