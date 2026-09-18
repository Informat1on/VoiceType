// AudioHALGatewayTests.swift — VoiceType
//
// docs/plans/coreaudiod-hang-resilience.md, задача 1. Доказывает контракт
// AudioHALGateway (perform/performSync/beginStall/endStall/enqueueCleanup) и
// AudioDeviceObservation (реестр listener'ов, требование 6) — без живого
// CoreAudio: каждый тест создаёт свой экземпляр шлюза с короткими сроками
// (0.1–0.3 с) и блокирует work через DispatchSemaphore, который тест
// отпускает вручную, симулируя зависший coreaudiod.
//
// Логирование во всех тестах перехватывается (`log:` в init) — ни один тест
// не должен коснуться реального ~/Library/Logs/VoiceType/errors.log.

import XCTest
import CoreAudio
@testable import VoiceType

final class AudioHALGatewayTests: XCTestCase {

    /// Потокобезопасный накопитель строк лога — `log` шлюза зовётся с фоновых
    /// очередей.
    private final class LogSink {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }
        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            _lines.append(line)
        }
    }

    private func makeGateway(timeout: TimeInterval = 0.2) -> (gateway: AudioHALGateway, log: LogSink) {
        let sink = LogSink()
        let gateway = AudioHALGateway(
            label: "test.audio.hal.\(UUID().uuidString)",
            defaultTimeout: timeout,
            log: { sink.append($0) }
        )
        return (gateway, sink)
    }

    /// Один тик main-очереди — main.async, поставленный ПОСЛЕ синхронного
    /// вызова, который сам уже поставил что-то на main (переход
    /// healthy↔unresponsive постит уведомление синхронно внутри вызова
    /// begin/endStall), гарантированно выполняется позже него (FIFO одной
    /// последовательной очереди).
    private func settleMain() {
        let exp = expectation(description: "main settled")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - perform: успех

    func testPerformSuccessDeliversOnMainExactlyOnceNotInline() {
        let (gateway, _) = makeGateway()
        var completionCount = 0
        var receivedValue: Int?
        var ranOnMain = false
        let exp = expectation(description: "delivered")

        gateway.perform("op", { 42 }, completion: { result in
            completionCount += 1
            ranOnMain = Thread.isMainThread
            if case .success(let value) = result { receivedValue = value }
            exp.fulfill()
        })

        // "Не inline" — сразу после возврата perform(), до прокачки run loop.
        XCTAssertEqual(completionCount, 0, "completion must not fire before perform() returns")

        wait(for: [exp], timeout: 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(ranOnMain)
        XCTAssertEqual(receivedValue, 42)
    }

    // MARK: - perform: throw → .failed

    func testPerformWorkThrowsMapsToFailed() throws {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "Boom" }
        }
        let (gateway, _) = makeGateway()
        let exp = expectation(description: "failed")
        var received: Result<Int, AudioHALError>?

        gateway.perform("op", { () throws -> Int in throw Boom() }, completion: { result in
            received = result
            exp.fulfill()
        })
        wait(for: [exp], timeout: 1)

        guard case .failure(.failed(let message)) = try XCTUnwrap(received) else {
            return XCTFail("expected .failed, got \(String(describing: received))")
        }
        XCTAssertTrue(message.contains("Boom"), "message must describe the thrown error, got: \(message)")
    }

    // MARK: - perform: таймаут

    func testPerformTimeoutMarksUnresponsiveWithOneLogLineAndOneNotification() {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, log) = makeGateway(timeout: 0.15)

        var notificationCount = 0
        let notifExp = expectation(description: "health notification")
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in
            notificationCount += 1
            notifExp.fulfill()
        }

        let exp = expectation(description: "timed out")
        let blockedWork: () -> Int = { semaphore.wait(); return 1 }
        gateway.perform("blockedOp", blockedWork, completion: { result in
            guard case .failure(.unresponsive) = result else { return XCTFail("expected .unresponsive, got \(result)") }
            exp.fulfill()
        })

        wait(for: [exp, notifExp], timeout: 1)
        guard case .unresponsive = gateway.health else { return XCTFail("expected unresponsive health") }
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(log.lines.count, 1, "exactly one log line per transition, got: \(log.lines)")
        // Дальше в этом тесте нас интересовал только переход в .unresponsive —
        // снимаем наблюдателя ДО освобождения зависшей work, иначе recovery
        // (второй переход) вызовет уже сработавший notifExp повторно.
        NotificationCenter.default.removeObserver(observer)

        semaphore.signal() // отпускаем зависшую work — иначе поток течёт до конца процесса теста
        settleMain()
    }

    // MARK: - perform: fail-fast при уже .unresponsive

    func testPerformFailsFastWithoutRunningWorkWhenAlreadyUnresponsive() {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, log) = makeGateway(timeout: 0.15)

        let firstTimedOut = expectation(description: "first timed out")
        let blockedWork: () -> Int = { semaphore.wait(); return 1 }
        gateway.perform("blockedOp", blockedWork, completion: { result in
            guard case .failure(.unresponsive) = result else { return XCTFail("\(result)") }
            firstTimedOut.fulfill()
        })
        wait(for: [firstTimedOut], timeout: 1)
        XCTAssertEqual(log.lines.count, 1)

        var secondWorkRan = false
        let secondExp = expectation(description: "second fails fast")
        let secondWork: () -> Int = { secondWorkRan = true; return 2 }
        gateway.perform("secondOp", secondWork, completion: { result in
            guard case .failure(.unresponsive) = result else { return XCTFail("\(result)") }
            secondExp.fulfill()
        })
        wait(for: [secondExp], timeout: 1)
        XCTAssertFalse(secondWorkRan, "work must not run while gateway is unresponsive")
        // Повторный fail-fast-отказ не пишет вторую строку лога.
        XCTAssertEqual(log.lines.count, 1)

        semaphore.signal()
        settleMain()
    }

    // MARK: - Восстановление и отбрасывание позднего результата

    func testReleasingStuckWorkRecoversHealthAndDiscardsLateResult() {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, log) = makeGateway(timeout: 0.15)

        var notificationCount = 0
        let recoveredExp = expectation(description: "recovered notification")
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in
            notificationCount += 1
            if case .healthy = gateway.health { recoveredExp.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var completionCount = 0
        let timedOutExp = expectation(description: "timed out")
        let blockedWork: () -> Int = { semaphore.wait(); return 99 }
        gateway.perform("blockedOp", blockedWork, completion: { result in
            completionCount += 1
            guard case .failure(.unresponsive) = result else { return XCTFail("\(result)") }
            timedOutExp.fulfill()
        })
        wait(for: [timedOutExp], timeout: 1)

        semaphore.signal() // поздний возврат — должен закрыть застой, не доставить completion
        wait(for: [recoveredExp], timeout: 1)

        guard case .healthy = gateway.health else { return XCTFail("expected healthy after recovery") }
        XCTAssertEqual(notificationCount, 2, "one for unresponsive, one for the recovery")
        XCTAssertEqual(completionCount, 1, "late success must not deliver a second completion")
        XCTAssertEqual(log.lines.count, 2, "one unresponsive line + one recovered line, got: \(log.lines)")
        XCTAssertTrue(log.lines.last?.contains("recovered after") ?? false)
    }

    // MARK: - performSync с фоновой очереди

    func testPerformSyncFromBackgroundQueueSucceeds() throws {
        let (gateway, _) = makeGateway(timeout: 0.5)
        let exp = expectation(description: "sync success")
        var result: Result<Int, AudioHALError>?
        DispatchQueue.global().async {
            result = gateway.performSync("op") { 7 }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        guard case .success(let value) = try XCTUnwrap(result) else {
            return XCTFail("expected success, got \(String(describing: result))")
        }
        XCTAssertEqual(value, 7)
    }

    func testPerformSyncFromBackgroundQueueTimesOut() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, log) = makeGateway(timeout: 0.15)
        let exp = expectation(description: "sync timeout")
        var result: Result<Int, AudioHALError>?
        DispatchQueue.global().async {
            result = gateway.performSync("blockedOp") { () -> Int in
                semaphore.wait()
                return 1
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        guard case .failure(.unresponsive) = try XCTUnwrap(result) else {
            return XCTFail("expected .unresponsive, got \(String(describing: result))")
        }
        XCTAssertEqual(log.lines.count, 1)

        semaphore.signal()
        settleMain()
    }

    // MARK: - beginStall / endStall

    func testHealthStaysUnresponsiveUntilAllStallsClose() {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, _) = makeGateway(timeout: 0.15)

        let timedOutExp = expectation(description: "internal timeout")
        let blockedWork: () -> Int = { semaphore.wait(); return 1 }
        gateway.perform("blockedOp", blockedWork, completion: { result in
            guard case .failure(.unresponsive) = result else { return XCTFail("\(result)") }
            timedOutExp.fulfill()
        })
        wait(for: [timedOutExp], timeout: 1)
        guard case .unresponsive = gateway.health else { return XCTFail("expected unresponsive") }

        let externalToken = AudioHALStallToken(label: "externalStall")
        gateway.beginStall(externalToken)

        semaphore.signal() // отпускаем внутреннюю work — её застой должен закрыться сам
        let settleExp = expectation(description: "internal stall closed")
        gateway.enqueueCleanup("settle") { settleExp.fulfill() }
        wait(for: [settleExp], timeout: 1)

        // Внутренний застой закрылся, но внешний ещё открыт — health остаётся unresponsive.
        guard case .unresponsive = gateway.health else {
            return XCTFail("expected unresponsive while external stall is still open")
        }

        gateway.endStall(externalToken)
        guard case .healthy = gateway.health else { return XCTFail("expected healthy after closing the last stall") }
    }

    func testEndStallIsIdempotent() {
        let (gateway, _) = makeGateway()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let token = AudioHALStallToken(label: "ext")
        gateway.beginStall(token)
        settleMain()
        XCTAssertEqual(notificationCount, 1)

        gateway.endStall(token)
        settleMain()
        XCTAssertEqual(notificationCount, 2)
        guard case .healthy = gateway.health else { return XCTFail("expected healthy") }

        gateway.endStall(token) // повторный вызов — no-op
        settleMain()
        XCTAssertEqual(notificationCount, 2, "repeated endStall must not post again")
    }

    func testEndStallBeforeBeginStallMakesBeginStallANoOp() {
        let (gateway, _) = makeGateway()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let token = AudioHALStallToken(label: "ext")
        gateway.endStall(token) // до beginStall — закрывает токен, здоровье не трогает
        gateway.beginStall(token) // токен уже закрыт — no-op
        settleMain()

        guard case .healthy = gateway.health else { return XCTFail("expected healthy") }
        XCTAssertEqual(notificationCount, 0, "no transition ever happened, no notification")
    }

    // MARK: - enqueueCleanup

    func testEnqueueCleanupRunsEvenWhileUnresponsive() {
        let semaphore = DispatchSemaphore(value: 0)
        let (gateway, _) = makeGateway(timeout: 0.15)

        let timedOutExp = expectation(description: "timed out")
        let blockedWork: () -> Int = { semaphore.wait(); return 1 }
        gateway.perform("blockedOp", blockedWork, completion: { result in
            guard case .failure(.unresponsive) = result else { return XCTFail("\(result)") }
            timedOutExp.fulfill()
        })
        wait(for: [timedOutExp], timeout: 1)
        guard case .unresponsive = gateway.health else { return XCTFail("expected unresponsive") }

        var cleanupRan = false
        let cleanupExp = expectation(description: "cleanup ran")
        // Ставится в очередь СРАЗУ, невзирая на .unresponsive — выполнится
        // только когда зависшая work наконец освободит очередь.
        gateway.enqueueCleanup("cleanup") {
            cleanupRan = true
            cleanupExp.fulfill()
        }

        semaphore.signal()
        wait(for: [cleanupExp], timeout: 1)
        XCTAssertTrue(cleanupRan)
    }

    // MARK: - AudioDeviceObservation: реестр, а не completion (план, требование 6)

    /// Потокобезопасные подставные add/remove — вызываются с очереди шлюза.
    private final class FakeListenerIO {
        private let lock = NSLock()
        private(set) var addCalls: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        private(set) var removeCalls: [AudioObjectPropertyAddress] = []
        /// Если задано — addListener БЛОКИРУЕТСЯ на этом семафоре при вызове с данным индексом.
        var blockAddAtIndex: Int?
        var blockSemaphore: DispatchSemaphore?

        func add(_ address: AudioObjectPropertyAddress, _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
            let index: Int
            lock.lock()
            index = addCalls.count
            addCalls.append((address, block))
            lock.unlock()

            if blockAddAtIndex == index, let sem = blockSemaphore {
                sem.wait()
            }
            return noErr
        }

        func remove(_ address: AudioObjectPropertyAddress, _ block: AudioObjectPropertyListenerBlock) -> OSStatus {
            lock.lock()
            removeCalls.append(address)
            lock.unlock()
            return noErr
        }

        var addCount: Int { lock.lock(); defer { lock.unlock() }; return addCalls.count }
        var removeCount: Int { lock.lock(); defer { lock.unlock() }; return removeCalls.count }
    }

    private let testSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice
    ]

    /// cancel() приходит, пока очередь шлюза занята посторонней блокирующей
    /// работой — регистрация ещё не начиналась. После освобождения очереди
    /// либо ничего не добавлено, либо всё добавленное снято (план, требование 9).
    func testObservationCancelBeforeRegistrationRunsLeavesNoLeakedListeners() {
        let blockGateSemaphore = DispatchSemaphore(value: 0)
        let (gateway, _) = makeGateway(timeout: 2.0)
        let io = FakeListenerIO()

        // Занимает очередь шлюза ДО того, как init поставит туда регистрацию.
        gateway.enqueueCleanup("occupyQueue") { blockGateSemaphore.wait() }

        var handlerCallCount = 0
        let observation = AudioDeviceObservation(
            gateway: gateway,
            selectors: testSelectors,
            handler: { handlerCallCount += 1 },
            addListener: io.add,
            removeListener: io.remove
        )
        observation.cancel() // очередь занята — регистрация ещё не выполнялась

        blockGateSemaphore.signal() // освобождаем очередь: регистрация, затем cleanup — по FIFO

        let settleExp = expectation(description: "queue drained")
        gateway.enqueueCleanup("settle") { settleExp.fulfill() }
        wait(for: [settleExp], timeout: 1)

        XCTAssertEqual(io.addCount, io.removeCount, "every added listener must be removed exactly once")
        XCTAssertTrue(io.addCount == 0 || io.removeCount == io.addCount)
        XCTAssertEqual(handlerCallCount, 0)
    }

    /// Регистрация добавила один listener и заблокировалась на втором дольше
    /// срока шлюза → gateway.perform уходит в .unresponsive; cancel() ставится
    /// в очередь; когда блокировка снята, регистрация ДОБАВЛЯЕТ второй listener
    /// (её completion уже отброшен шлюзом, но сама работа продолжается и
    /// довершается) — cleanup обязан снять ОБА ровно по разу.
    func testObservationCleanupRemovesListenersAddedAfterGatewayTimeout() {
        let (gateway, _) = makeGateway(timeout: 0.15)
        let io = FakeListenerIO()
        let blockSemaphore = DispatchSemaphore(value: 0)
        io.blockAddAtIndex = 1 // второй selector блокируется
        io.blockSemaphore = blockSemaphore

        var handlerCallCount = 0
        let observation = AudioDeviceObservation(
            gateway: gateway,
            selectors: testSelectors,
            handler: { handlerCallCount += 1 },
            addListener: io.add,
            removeListener: io.remove
        )

        // Ждём, пока шлюз перейдёт в .unresponsive — регистрация всё ещё
        // блокирована на втором addListener.
        let unresponsiveExp = expectation(description: "gateway unresponsive")
        let observer = NotificationCenter.default.addObserver(
            forName: AudioHALGateway.healthDidChangeNotification, object: gateway, queue: .main
        ) { _ in
            if case .unresponsive = gateway.health { unresponsiveExp.fulfill() }
        }
        wait(for: [unresponsiveExp], timeout: 1)
        NotificationCenter.default.removeObserver(observer)

        observation.cancel() // встаёт в очередь ПОСЛЕ ещё не завершившейся регистрации

        blockSemaphore.signal() // регистрация довершает второй Add, затем идёт cleanup

        let settleExp = expectation(description: "queue drained")
        gateway.enqueueCleanup("settle") { settleExp.fulfill() }
        wait(for: [settleExp], timeout: 1)

        XCTAssertEqual(io.addCount, 2, "both selectors must have been registered")
        XCTAssertEqual(io.removeCount, 2, "every listener added — including the one added after the timeout — must be removed exactly once")
        XCTAssertEqual(handlerCallCount, 0, "handler must never fire — no fake listener block was ever invoked")
    }
}
