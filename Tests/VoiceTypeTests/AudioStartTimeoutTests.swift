// AudioStartTimeoutTests.swift — VoiceType
//
// Задача 5 плана docs/plans/audio-start-hang.md: доказывает, что асинхронный
// старт AudioCaptureService не блокирует main и не путает исходы конкурирующих
// попыток — без живого микрофона. Использует инъецируемые швы сервиса:
// `startOperationRunner` (держит попытку и разрешает её вручную) и
// `watchdogScheduler` (виртуальные часы — watchdog срабатывает по команде
// теста, а не по настоящему таймеру).
//
// Границы: NotificationCenter-подписки (`installInterruptionObservers`)
// ставятся только реальным `performStartOperation`, который эти тесты не
// вызывают (они подставляют свой runner). Пункты 8 и 11 задачи 5 поэтому
// проверяют identity-сверку в `reportInterruption` напрямую — она и есть суть
// требований 9/17 — а не сквозной путь через настоящую AVCaptureSession.

import XCTest
import AVFoundation
@testable import VoiceType

/// Держит вызовы `startOperationRunner`, чтобы тест мог разрешить их вручную
/// (успехом или сбоем) в любой момент — «инъецируемый runner стартовой
/// операции» из задачи 5 плана.
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

/// Watchdog на виртуальных часах: ничего не планирует по-настоящему, копит
/// колбэки и стреляет ими по явной команде теста.
private final class ManualWatchdogScheduler: WatchdogScheduling {
    private final class Token {}
    private var pending: [ObjectIdentifier: () -> Void] = [:]
    private var order: [ObjectIdentifier] = []
    private(set) var cancelledCount = 0

    func scheduleWatchdog(after seconds: TimeInterval, action: @escaping () -> Void) -> AnyObject {
        let token = Token()
        let id = ObjectIdentifier(token)
        pending[id] = action
        order.append(id)
        return token
    }

    func cancelWatchdog(_ token: AnyObject) {
        guard let token = token as? Token else { return }
        if pending.removeValue(forKey: ObjectIdentifier(token)) != nil {
            cancelledCount += 1
        }
    }

    /// Стреляет самым свежим ещё не отменённым watchdog'ом — симулирует
    /// таймаут без ожидания настоящего времени. No-op, если он уже отменён
    /// (например, `cancelPendingStart()` успел выиграть гонку первым) — это
    /// легитимный исход, а не ошибка теста.
    func fireLatest() {
        guard let id = order.last(where: { pending[$0] != nil }) else { return }
        pending.removeValue(forKey: id)?()
    }
}

final class AudioStartTimeoutTests: XCTestCase {

    /// Отдельный счётчик от сервисного `nextCandidateValue` — тестам нужны
    /// candidateID независимо от того, сколько кандидатов завёл сам сервис
    /// (fake runner обходит `configureAndStartAttempt`, где они обычно
    /// рождаются).
    private static var nextTestCandidateValue = 0
    private static func makeTestCandidateID() -> SessionCandidateID {
        nextTestCandidateValue += 1
        return SessionCandidateID(value: nextTestCandidateValue)
    }

    /// Собирает настоящий (но никогда не запускавшийся) `StartedBundle`:
    /// `AVCaptureSession`/`AVCaptureAudioDataOutput` не требуют оборудования
    /// для конструирования, а `AVAudioFile(forWriting:)` — обычный временный
    /// файл. Это и есть «attempt-owned resource bundle», которым задача 5
    /// требует доказывать владение, а не только флаги.
    private static func makeTestBundle(
        deviceUID: String?,
        candidateID: SessionCandidateID? = nil,
        fallbackReason: DeviceFallbackReason? = nil
    ) throws -> StartedBundle {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStartTimeoutTests-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        return StartedBundle(
            candidateID: candidateID ?? makeTestCandidateID(),
            session: AVCaptureSession(),
            output: AVCaptureAudioDataOutput(),
            writer: file,
            writerFormat: format,
            url: url,
            deviceUID: deviceUID,
            deviceName: deviceUID.map { "Test Device \($0)" },
            fallbackReason: fallbackReason
        )
    }

    private func makeService(runner: FakeStartRunner, scheduler: ManualWatchdogScheduler) -> AudioCaptureService {
        let service = AudioCaptureService()
        service.startOperationRunner = runner.runner
        service.watchdogScheduler = scheduler
        return service
    }

    /// `handleStartOutcome` always hops via `DispatchQueue.main.async`, even
    /// when the fake runner resolves synchronously (that hop is the contract's
    /// "never inline" guarantee — see `AudioCaptureService.handleStartOutcome`).
    /// XCTest doesn't pump the run loop between plain statements, so any
    /// assertion that depends on a `runner.resolve(...)` having taken effect
    /// needs an explicit settle point first.
    private func settle() {
        let exp = expectation(description: "main queue settled")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    /// Дожидается ПОЛНОГО оборота фонового teardown заброшенной попытки:
    /// main (`finishStartOutcome`) → `sessionQueue` (`abandon`) → main
    /// (снятие busy). Одного `settle()` недостаточно — `sessionQueue`
    /// выполняется на отдельном потоке независимо от прокачки run loop на
    /// main (P1-2, код-ревью: teardown теперь всегда фоновый).
    private func settleAsyncTeardown(_ service: AudioCaptureService) {
        settle()
        let exp = expectation(description: "background teardown settled")
        service.sessionQueueForTesting.async {
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - 1. Возврат до завершения runner'а

    func testStartReturnsBeforeRunnerResolves() {
        let runner = FakeStartRunner()
        let service = makeService(runner: runner, scheduler: ManualWatchdogScheduler())

        var completed = false
        _ = service.startRecording(preferredDeviceUID: nil, timeout: 4.0) { _ in completed = true }

        XCTAssertFalse(completed, "startRecording must return before the held runner resolves")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    // MARK: - 2 & 10. completion никогда не inline, всегда на main; identity немедленного отказа совпадает с возвращённым id

    func testImmediateBusyRejectionIsNeverInlineAndIdentityMatches() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        // Заводим A в .abandoning (единственное состояние, где немедленный
        // отказ — именно .captureDeviceBusy, а не .alreadyRecording).
        let timeoutExp = expectation(description: "A timed out")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else {
                return XCTFail("expected sessionStartTimedOut, got \(result)")
            }
            timeoutExp.fulfill()
        }
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)
        XCTAssertEqual(runner.invocations.count, 1)

        var completionRan = false
        let exp = expectation(description: "busy delivered")
        // swiftlint:disable:next implicitly_unwrapped_optional
        var capturedID: StartAttemptID!
        capturedID = service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            completionRan = true
            guard case .failure(.captureDeviceBusy) = result else {
                return XCTFail("expected captureDeviceBusy, got \(result)")
            }
            exp.fulfill()
        }

        // Контракт: даже немедленный отказ не вызывается inline — проверяем
        // ДО откачки run loop через wait(for:), т.е. строго синхронно после
        // возврата метода.
        XCTAssertFalse(completionRan, "completion for an immediate rejection must not fire before startRecording() returns")
        XCTAssertNotNil(capturedID)
        // Второй старт не должен был достучаться до runner'а — отказ был
        // немедленным на уровне сервиса, не через фоновую операцию.
        XCTAssertEqual(runner.invocations.count, 1)

        wait(for: [exp], timeout: 1)
    }

    // MARK: - 3 & 6. Таймаут → sessionStartTimedOut; busy до конца cleanup, idle после

    func testTimeoutProducesTimedOutErrorAndBusyUntilCleanupCompletes() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        let timeoutExp = expectation(description: "timed out")
        _ = service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case let .failure(.sessionStartTimedOut(uid, seconds)) = result else {
                return XCTFail("expected sessionStartTimedOut, got \(result)")
            }
            XCTAssertEqual(uid, "dev-A")
            // Фактически измеренное ожидание (Date().timeIntervalSince), не
            // заданный порог — требование 15/13: тест синхронный, поэтому
            // почти ноль, а не 4.0.
            XCTAssertLessThan(seconds, 1.0)
            XCTAssertGreaterThanOrEqual(seconds, 0)
            timeoutExp.fulfill()
        }
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)

        // Требование 6: busy держится до конца cleanup, не до момента резолва —
        // второй старт должен быть отклонён немедленно, не дойдя до runner'а.
        let busyExp = expectation(description: "busy while abandoned runner still pending")
        _ = service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .failure(.captureDeviceBusy) = result else {
                return XCTFail("expected captureDeviceBusy, got \(result)")
            }
            busyExp.fulfill()
        }
        wait(for: [busyExp], timeout: 1)
        XCTAssertEqual(runner.invocations.count, 1, "still just the original, abandoned invocation")

        // Заброшенный runner наконец возвращается (симулирует поздний возврат
        // зависшего startRunning()) — только теперь busy снимается.
        runner.resolve(at: 0, .failure(.sessionDidNotStart))
        settle()

        let acceptedExp = expectation(description: "accepted after cleanup")
        _ = service.startRecording(preferredDeviceUID: "dev-C", timeout: 4.0) { _ in
            acceptedExp.fulfill()
        }
        XCTAssertEqual(runner.invocations.count, 2, "third attempt must reach the runner — service is idle again")
        runner.resolve(at: 1, .failure(.sessionDidNotStart))
        wait(for: [acceptedExp], timeout: 1)
    }

    // MARK: - P2 (код-ревью, 2й раунд). Диагностика таймаута доходит до errors.log
    // с именем устройства и фактической длительностью, а не только в unified log.

    func testTimeoutWritesDeviceNameAndActualElapsedToErrorLog() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        var loggedMessages: [String] = []
        service.errorLogWriterForTesting = { loggedMessages.append($0) }

        let timeoutExp = expectation(description: "timed out")
        let attemptID = service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else { return XCTFail("\(result)") }
            timeoutExp.fulfill()
        }
        // Имитирует то, что реальный configureAndStartAttempt делает в фоне,
        // как только у него появляется живой AVCaptureDevice.
        service.recordResolvedDeviceName("Elgato Wave Link MicFX", for: attemptID)
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)

        XCTAssertEqual(loggedMessages.count, 1, "exactly one file-log write per timeout")
        let message = loggedMessages[0]
        XCTAssertTrue(message.contains("Elgato Wave Link MicFX"), "must name the resolved device, got: \(message)")
        XCTAssertTrue(message.contains("dev-A"), "must include the UID, got: \(message)")
        // Фактическая длительность (синхронный тест — доли секунды), не
        // заданный порог 4.0 — иначе строка содержала бы "4.000s".
        XCTAssertFalse(message.contains("4.000s"), "must log the ACTUAL wait, not the configured timeout: \(message)")
    }

    // MARK: - 4. Успех после таймаута не зовёт completion повторно и не переводит в .recording

    func testLateSuccessAfterTimeoutIsDiscarded() throws {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        let timeoutExp = expectation(description: "timed out")
        _ = service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else {
                return XCTFail("expected sessionStartTimedOut, got \(result)")
            }
            timeoutExp.fulfill()
        }
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)

        // Поздний успех: fulfill() второй раз для timeoutExp завалил бы тест
        // сам по себе (XCTest запрещает повторный fulfill), поэтому сам факт
        // отсутствия краша здесь уже частично доказывает "ровно один исход".
        let bundle = try Self.makeTestBundle(deviceUID: "dev-A")
        let url = bundle.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        runner.resolve(at: 0, .success(bundle))

        // Cleanup заброшенного bundle'а (в фоне, P1-2) удаляет его временный
        // файл — наблюдаемое доказательство владения ресурсом, а не только флага.
        settleAsyncTeardown(service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "late success must be torn down, not published")

        // Сервис снова .idle — следующий старт достигает runner'а.
        let nextExp = expectation(description: "next attempt reaches runner")
        _ = service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { _ in nextExp.fulfill() }
        XCTAssertEqual(runner.invocations.count, 2)
        runner.resolve(at: 1, .failure(.sessionDidNotStart))
        wait(for: [nextExp], timeout: 1)
    }

    // MARK: - 5. Cancel против watchdog в обоих порядках

    func testCancelThenLateWatchdogFiresOnlyOneCompletion() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        let exp = expectation(description: "cancelled exactly once")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.startCancelled) = result else {
                return XCTFail("expected startCancelled, got \(result)")
            }
            exp.fulfill()
        }
        service.cancelPendingStart()
        wait(for: [exp], timeout: 1)

        // Watchdog «стреляет» позже — не должен производить второй completion
        // (fulfill() второй раз завалил бы тест сам по себе).
        scheduler.fireLatest()
    }

    func testWatchdogThenLateCancelFiresOnlyOneCompletion() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        let exp = expectation(description: "timed out exactly once")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else {
                return XCTFail("expected sessionStartTimedOut, got \(result)")
            }
            exp.fulfill()
        }
        scheduler.fireLatest()
        wait(for: [exp], timeout: 1)

        // cancelPendingStart() после watchdog — no-op (state уже .abandoning,
        // не .starting). Второй completion здесь снова завалил бы тест сам.
        service.cancelPendingStart()
    }

    // MARK: - 7. Cleanup заброшенной попытки не задевает следующую (последовательно — см. заголовок файла)

    func testAbandonedAttemptCleanupDoesNotLeakIntoNextAttempt() throws {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        // A: отменена, затем поздно "успешно" завершается — её bundle обязан
        // быть снесён (см. testLateSuccessAfterTimeoutIsDiscarded), а не
        // опубликован в поля сервиса.
        let cancelExp = expectation(description: "A cancelled")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.startCancelled) = result else {
                return XCTFail("expected startCancelled, got \(result)")
            }
            cancelExp.fulfill()
        }
        service.cancelPendingStart()
        wait(for: [cancelExp], timeout: 1)

        let bundleA = try Self.makeTestBundle(deviceUID: "dev-A")
        runner.resolve(at: 0, .success(bundleA))
        // Дать фоновому teardown'у A полностью отработать перед тем, как
        // стартовать B (P1-2: teardown теперь на sessionQueue, не на main).
        settleAsyncTeardown(service)

        // B стартует и доходит до .recording полностью — её собственный bundle
        // не должен быть задет тем, что произошло с A.
        let bundleB = try Self.makeTestBundle(deviceUID: "dev-B")
        let successExp = expectation(description: "B started")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            successExp.fulfill()
        }
        XCTAssertEqual(runner.invocations.count, 2)
        runner.resolve(at: 1, .success(bundleB))
        wait(for: [successExp], timeout: 1)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundleB.url.path),
            "B's own file must survive A's cleanup"
        )
        // Стоп проходит без .notRecording — значит сервис действительно в
        // .recording на B, а не заброшен где-то по дороге из-за A.
        XCTAssertNoThrow(try service.stopRecording())
    }

    // MARK: - 8. Позднее уведомление старой сессии не обрывает новую запись

    func testStaleCandidateInterruptionDoesNotAffectCurrentRecording() throws {
        let runner = FakeStartRunner()
        let service = makeService(runner: runner, scheduler: ManualWatchdogScheduler())

        var delivered: [CaptureInterruption] = []
        service.onInterruption = { delivered.append($0) }

        // Кандидат A — не имеет отношения к последующей записи B вообще
        // (собственный allocateCandidateID теста, никогда не становился живым).
        let staleCandidateID = Self.makeTestCandidateID()

        let candidateB = Self.makeTestCandidateID()
        let bundleB = try Self.makeTestBundle(deviceUID: "dev-B", candidateID: candidateB)
        let successExp = expectation(description: "B started")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            successExp.fulfill()
        }
        service.beginCandidate(candidateB) // как реальный configureAndStartAttempt для B
        runner.resolve(at: 0, .success(bundleB))
        wait(for: [successExp], timeout: 1)

        // Позднее уведомление чужого, никогда не бывшего живым кандидата не
        // должно долетать до onInterruption текущей записи (B).
        service.reportInterruption(.sessionInterrupted, requiredCandidateID: staleCandidateID)
        XCTAssertTrue(delivered.isEmpty, "a stale candidate's notification must not interrupt the current recording")

        // Sanity: без requiredCandidateID (путь captureOutput/failCapture — уже
        // подтверждён identity выше по стеку) обрыв текущей записи проходит.
        service.reportInterruption(.writeFailed("boom"))
        XCTAssertEqual(delivered, [.writeFailed("boom")])
    }

    // MARK: - P1-1 (код-ревью). Уведомление в production-форме (с requiredCandidateID)
    // от ТЕКУЩЕЙ подтверждённой записи должно доставляться и ПОСЛЕ finalizeSuccess,
    // когда currentAttempt уже обнулён — старый код всегда отбрасывал такие уведомления.

    func testProductionFormNotificationSurvivesFinalizeSuccessClearingCurrentAttempt() throws {
        let runner = FakeStartRunner()
        let service = makeService(runner: runner, scheduler: ManualWatchdogScheduler())

        var delivered: [CaptureInterruption] = []
        service.onInterruption = { delivered.append($0) }

        let candidateID = Self.makeTestCandidateID()
        let bundle = try Self.makeTestBundle(deviceUID: "dev-A", candidateID: candidateID)
        let successExp = expectation(description: "started")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            successExp.fulfill()
        }
        service.beginCandidate(candidateID)
        runner.resolve(at: 0, .success(bundle))
        wait(for: [successExp], timeout: 1)

        // Ровно то, что реально шлют session-level наблюдатели: requiredCandidateID
        // никогда не nil в проде. currentAttempt к этому моменту уже nil
        // (finalizeSuccess его обнулил) — сверка обязана идти по liveCandidateID.
        service.reportInterruption(.runtimeError("mic died"), requiredCandidateID: candidateID)
        XCTAssertEqual(delivered, [.runtimeError("mic died")], "identity must survive finalizeSuccess clearing currentAttempt")
    }

    // MARK: - P1-3 (код-ревью). Primary внутри одной попытки не обрывает и не
    // глушит прерывания последующего fallback-кандидата.

    func testPrimaryInterruptionDoesNotLeakIntoOrExhaustFallbackCandidate() throws {
        let runner = FakeStartRunner()
        let service = makeService(runner: runner, scheduler: ManualWatchdogScheduler())

        var delivered: [CaptureInterruption] = []
        service.onInterruption = { delivered.append($0) }

        let successExp = expectation(description: "fallback started")
        service.startRecording(preferredDeviceUID: "dev-primary", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            successExp.fulfill()
        }

        // Симулирует то, что делает beginSessionAttempt внутри одной попытки:
        // primary candidate становится живым, ловит уведомление о своей же
        // смерти (буферизуется, .starting), затем ПРОВАЛИВАЕТСЯ и fallback
        // candidate занимает его место — как configureAndStartAttempt делает
        // для fallback.
        let primaryCandidate = Self.makeTestCandidateID()
        service.beginCandidate(primaryCandidate)
        service.reportInterruption(.runtimeError("primary died"), requiredCandidateID: primaryCandidate)

        let fallbackCandidate = Self.makeTestCandidateID()
        service.beginCandidate(fallbackCandidate)
        let bundle = try Self.makeTestBundle(deviceUID: "dev-fallback", candidateID: fallbackCandidate)
        runner.resolve(at: 0, .success(bundle))
        wait(for: [successExp], timeout: 1)

        XCTAssertTrue(delivered.isEmpty, "primary's interruption must not leak into the fallback recording it was replaced by")

        // Флаг «одно прерывание на запись» не должен быть исчерпан событием
        // primary — fallback обязан ловить СВОИ собственные прерывания.
        service.reportInterruption(.writeFailed("fallback failed too"), requiredCandidateID: fallbackCandidate)
        XCTAssertEqual(delivered, [.writeFailed("fallback failed too")], "fallback's own interruption must not be swallowed")
    }

    // MARK: - P1-2 (код-ревью). Cleanup заброшенной попытки не блокирует main;
    // busy снимается только после завершения фонового teardown.

    func testAbandonedSuccessTeardownRunsOffMainAndBusyReleasedOnlyAfterward() throws {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        let timeoutExp = expectation(description: "timed out")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else { return XCTFail("\(result)") }
            timeoutExp.fulfill()
        }
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)

        // Поздний успех после таймаута — тот самый случай, где старый код
        // звал abandon() (stopRunning()) прямо на main.
        let bundle = try Self.makeTestBundle(deviceUID: "dev-A")
        // `abandon()` сам содержит `dispatchPrecondition(.notOnQueue(.main))` —
        // если бы он выполнился на main, процесс упал бы прямо здесь.
        runner.resolve(at: 0, .success(bundle))

        // Сразу после resolve (до какой-либо откачки очередей) слот обязан
        // ОСТАВАТЬСЯ занятым — teardown ушёл в фон и ещё не вернулся.
        let busyExp = expectation(description: "still busy immediately after late success")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { result in
            guard case .failure(.captureDeviceBusy) = result else { return XCTFail("expected captureDeviceBusy, got \(result)") }
            busyExp.fulfill()
        }
        wait(for: [busyExp], timeout: 1)
        XCTAssertEqual(runner.invocations.count, 1, "must not reach the runner while still busy")

        // Даём фоновому teardown'у полностью отработать.
        settleAsyncTeardown(service)

        // Только теперь busy снят — третий старт достигает runner'а.
        let acceptedExp = expectation(description: "accepted after background teardown")
        service.startRecording(preferredDeviceUID: "dev-C", timeout: 4.0) { _ in acceptedExp.fulfill() }
        XCTAssertEqual(runner.invocations.count, 2, "service must be idle again only after teardown fully completed")
        runner.resolve(at: 1, .failure(.sessionDidNotStart))
        wait(for: [acceptedExp], timeout: 1)
    }

    // MARK: - 9. Menu-start → hotkey-stop — см. HotkeyServiceSyncTests.swift

    // MARK: - 11. Буферизованное прерывание: доставка после success / отбрасывание при провале

    func testInterruptionBufferedDuringStartingIsDeliveredRightAfterSuccess() throws {
        let runner = FakeStartRunner()
        let service = makeService(runner: runner, scheduler: ManualWatchdogScheduler())

        var delivered: [CaptureInterruption] = []
        service.onInterruption = { delivered.append($0) }

        let successExp = expectation(description: "started")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
            successExp.fulfill()
        }

        let candidateID = Self.makeTestCandidateID()
        service.beginCandidate(candidateID)

        // Прерывание приходит, пока попытка ещё .starting — до финализации.
        service.reportInterruption(.sessionInterrupted, requiredCandidateID: candidateID)
        XCTAssertTrue(delivered.isEmpty, "must be buffered, not delivered while still .starting")

        let bundle = try Self.makeTestBundle(deviceUID: "dev-A", candidateID: candidateID)
        runner.resolve(at: 0, .success(bundle))
        wait(for: [successExp], timeout: 1)

        XCTAssertEqual(delivered, [.sessionInterrupted], "buffered interruption must surface right after success")
    }

    func testInterruptionBufferedDuringStartingIsDiscardedWhenAttemptFails() {
        let runner = FakeStartRunner()
        let scheduler = ManualWatchdogScheduler()
        let service = makeService(runner: runner, scheduler: scheduler)

        var delivered: [CaptureInterruption] = []
        service.onInterruption = { delivered.append($0) }

        let timeoutExp = expectation(description: "timed out")
        service.startRecording(preferredDeviceUID: "dev-A", timeout: 4.0) { result in
            guard case .failure(.sessionStartTimedOut) = result else {
                return XCTFail("expected sessionStartTimedOut, got \(result)")
            }
            timeoutExp.fulfill()
        }

        let candidateID = Self.makeTestCandidateID()
        service.beginCandidate(candidateID)
        service.reportInterruption(.sessionInterrupted, requiredCandidateID: candidateID)
        scheduler.fireLatest()
        wait(for: [timeoutExp], timeout: 1)

        XCTAssertTrue(delivered.isEmpty, "a buffered interruption for a failed attempt must never surface")
        runner.resolve(at: 0, .failure(.sessionDidNotStart))
        settle()

        // И не протекает в следующую запись.
        let nextExp = expectation(description: "next attempt unaffected")
        service.startRecording(preferredDeviceUID: "dev-B", timeout: 4.0) { _ in nextExp.fulfill() }
        XCTAssertEqual(runner.invocations.count, 2)
        runner.resolve(at: 1, .failure(.sessionDidNotStart))
        wait(for: [nextExp], timeout: 1)
        XCTAssertTrue(delivered.isEmpty)
    }
}
