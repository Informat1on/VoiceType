// AudioHALGateway.swift — VoiceType
//
// docs/plans/coreaudiod-hang-resilience.md, задача 1.
//
// Инвариант: main никогда не вызывает HAL напрямую. Диагностика 18.09.2026
// показала, что первый же HAL-вызов (AudioObject*, AVCaptureDevice(uniqueID:),
// AVAudioPlayer.prepareToPlay(), NSSound.play()…) виснет НАВСЕГДА, если
// coreaudiod ушёл в deadlock — и вешает поток, с которого вызван, будь то
// main или любой другой. Этот шлюз — единственная точка входа к CoreAudio:
// своя последовательная очередь, срок на вызов, состояние здоровья.
//
// Почему очередь шлюза ОТДЕЛЬНА от sessionQueue захвата (AudioCaptureService):
// startRunning(), висящий на одном неисправном устройстве (Elgato Wave Link
// MicFX, docs/plans/audio-start-hang.md), не должен выглядеть как «аудиосистема
// мертва» — health шлюза отражает демон, а не конкретное устройство.
//
// Почему health держится по количеству открытых «застоев» (stalls), а не по
// одному bool: застой может быть внутренним (просроченная work в perform/
// performSync) или внешним (AudioCaptureService.beginStall на зависшем
// stopRunning(), задача 2) — здоровье обязано оставаться .unresponsive, пока
// не закрыт ни один из них.

import Foundation

/// Почему вызов через шлюз не дал результата.
enum AudioHALError: Error, Equatable {
    /// Не уложился в срок, либо шлюз уже в `.unresponsive` (fail-fast: работа
    /// в очередь НЕ ставилась).
    case unresponsive
    /// Работа выполнилась и бросила ошибку. `String(describing: error)`.
    case failed(String)
}

enum AudioSystemHealth: Equatable {
    case healthy
    case unresponsive(since: Date)
}

/// Identity внешнего застоя. Создаётся ЗАРАНЕЕ вызывающим, до решения,
/// открывать ли застой, — чтобы begin/end можно было звать вне своих замков
/// в любом порядке (см. `AudioHALGateway.beginStall`/`endStall`).
final class AudioHALStallToken {
    let label: String
    /// Мутируются только под замком `AudioHALGateway.lock` — токен сам по
    /// себе не потокобезопасен, безопасность даёт шлюз, который им владеет.
    /// `fileprivate`, а не `private`, — тип-владелец другой (`AudioHALGateway`),
    /// но в том же файле; strict_fileprivate тут не про утечку абстракции.
    fileprivate var isClosed = false // swiftlint:disable:this strict_fileprivate
    fileprivate var isRegisteredOpen = false // swiftlint:disable:this strict_fileprivate

    init(label: String) {
        self.label = label
    }
}

/// Гарантирует ровно одно "решение" на попытку `perform`/`performSync`: либо
/// work успела вернуться первой (обычный путь), либо истёк срок первым
/// (таймаут). Кто первый застолбил исход — тот и действует; второй участник
/// молча уступает. Без этого позднее возвращение зависшей work могло бы
/// доставить completion повторно поверх уже доставленного таймаута.
private final class PerformOutcomeGate {
    private let lock = NSLock()
    private var isResolved = false

    /// true — work успела первой, доставлять её результат.
    func resolveByWork() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return false }
        isResolved = true
        return true
    }

    /// true — срок истёк первым, открывать застой и доставлять `.unresponsive`.
    func resolveByTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return false }
        isResolved = true
        return true
    }
}

final class AudioHALGateway {

    static let shared = AudioHALGateway()

    /// Постится на main ровно на переходах healthy↔unresponsive; `object` —
    /// сам шлюз, который перешёл. Слушатели фильтруют по объекту, если у них
    /// несколько шлюзов (тесты).
    static let healthDidChangeNotification = Notification.Name("AudioHALGateway.healthDidChangeNotification")

    /// Общий для ВСЕХ экземпляров шлюза (а не только `.shared`) — так
    /// `isOnGatewayQueue` работает и с шлюзом, подставленным в тестах, без
    /// привязки к конкретному инстансу.
    private static let queueKey = DispatchSpecificKey<Void>()

    /// true, если текущий код исполняется на очереди ЛЮБОГО экземпляра шлюза.
    static var isOnGatewayQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// Последовательная очередь, на которой выполняется ВСЯ работа шлюза:
    /// perform/performSync work, регистрация/снятие CoreAudio listener'ов,
    /// enqueueCleanup.
    let queue: DispatchQueue

    private let defaultTimeout: TimeInterval
    private let writeLogLine: (String) -> Void

    /// Защищает `_health` и `openStalls` — читается с любого потока, пишется
    /// из perform/performSync (фоновая очередь таймаута) и beginStall/endStall
    /// (произвольный вызывающий поток), поэтому не годится сама `queue`.
    private let lock = NSLock()
    private var _health: AudioSystemHealth = .healthy
    private var openStalls: [ObjectIdentifier: AudioHALStallToken] = [:]

    /// `log` — куда писать переходы здоровья; в проде errors.log, в тестах —
    /// перехват. ErrorLogger — @MainActor, а этот closure зовётся с фоновых
    /// очередей шлюза, поэтому дефолт сам уходит на main и там же входит в
    /// изоляцию актора — вызывать `ErrorLogger.shared.log` отсюда напрямую
    /// не даёт компилятор (синхронный вызов main-actor-метода вне main).
    init(
        label: String = "com.voicetype.audio.hal",
        defaultTimeout: TimeInterval = 2.0,
        log: @escaping (String) -> Void = { message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ErrorLogger.shared.log(message: message, category: "audio")
                }
            }
        }
    ) {
        self.queue = DispatchQueue(label: label)
        self.defaultTimeout = defaultTimeout
        self.writeLogLine = log
        self.queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// Читается с любого потока (под замком).
    var health: AudioSystemHealth {
        lock.lock()
        defer { lock.unlock() }
        return _health
    }

    // MARK: - perform / performSync

    /// `completion` — РОВНО один раз, всегда на main, никогда inline.
    /// health == .unresponsive → сразу `.failure(.unresponsive)`, work не
    /// выполняется. work дольше timeout → `.failure(.unresponsive)`,
    /// открывается застой, health → .unresponsive; поздний результат
    /// отбрасывается; когда work вернётся — её застой закрывается.
    func perform<T>(
        _ label: String,
        timeout: TimeInterval? = nil,
        _ work: @escaping () throws -> T,
        completion: @escaping (Result<T, AudioHALError>) -> Void
    ) {
        if case .unresponsive = health {
            deliverOnMain { completion(.failure(.unresponsive)) }
            return
        }

        let effectiveTimeout = timeout ?? defaultTimeout
        let token = AudioHALStallToken(label: label)
        let gate = PerformOutcomeGate()

        queue.async { [weak self] in
            guard let self else { return }
            let outcome = Self.runCatching(work)
            if gate.resolveByWork() {
                self.deliverOnMain { completion(Self.mapOutcome(outcome)) }
            } else {
                // Таймаут уже отдал .unresponsive — результат отбрасываем,
                // закрываем только застой, который он открыл.
                self.endStall(token)
            }
        }

        // ВАЖНО: на отдельной очереди, не на `queue` — если work зависнет,
        // она займёт `queue` навсегда, и таймер, поставленный на ТУ ЖЕ
        // последовательную очередь, никогда бы не выстрелил.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + effectiveTimeout) { [weak self] in
            guard let self, gate.resolveByTimeout() else { return }
            self.openStall(token, label: label, timeout: effectiveTimeout)
            self.deliverOnMain { completion(.failure(.unresponsive)) }
        }
    }

    /// То же синхронно, с ограниченным ожиданием. Запрещён на main и на
    /// `queue` (`dispatchPrecondition`).
    func performSync<T>(
        _ label: String,
        timeout: TimeInterval? = nil,
        _ work: @escaping () throws -> T
    ) -> Result<T, AudioHALError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        dispatchPrecondition(condition: .notOnQueue(queue))

        if case .unresponsive = health {
            return .failure(.unresponsive)
        }

        let effectiveTimeout = timeout ?? defaultTimeout
        let token = AudioHALStallToken(label: label)
        let gate = PerformOutcomeGate()
        let semaphore = DispatchSemaphore(value: 0)
        var workResult: Result<T, AudioHALError>?

        queue.async { [weak self] in
            guard let self else { return }
            let outcome = Self.runCatching(work)
            if gate.resolveByWork() {
                workResult = Self.mapOutcome(outcome)
                semaphore.signal()
            } else {
                self.endStall(token)
            }
        }

        if semaphore.wait(timeout: .now() + effectiveTimeout) == .success, let workResult {
            return workResult
        }

        guard gate.resolveByTimeout() else {
            // Гонка на самой границе дедлайна: work уже застолбила исход и
            // просигналила семафор долями секунды после wait(timeout:) —
            // досчитать до сигнала, не открывая застой зазря.
            semaphore.wait()
            return workResult ?? .failure(.unresponsive)
        }
        openStall(token, label: label, timeout: effectiveTimeout)
        return .failure(.unresponsive)
    }

    /// Без срока и результата (снятие listener'ов). Ставится в очередь
    /// ВСЕГДА, даже при .unresponsive — выполнится, когда очередь освободится.
    func enqueueCleanup(_ label: String, _ work: @escaping () -> Void) {
        _ = label // для трассировки в будущем; сама работа очереди — единственный контракт.
        queue.async(execute: work)
    }

    // MARK: - Внешние застои

    /// Открыть → health .unresponsive; повторный `beginStall` — no-op.
    /// Вызывающий НЕ держит свои замки во время вызова.
    func beginStall(_ token: AudioHALStallToken) {
        openStall(token, label: token.label, timeout: nil)
    }

    /// Закрыть → если открытых застоев нет, .healthy. Идемпотентен и допустим
    /// ДО `beginStall`: токен помечается закрытым, и последующий `beginStall`
    /// с ним — no-op. Вызывающий НЕ держит свои замки во время вызова.
    func endStall(_ token: AudioHALStallToken) {
        lock.lock()
        guard !token.isClosed else {
            lock.unlock()
            return
        }
        token.isClosed = true
        let wasRegistered = openStalls.removeValue(forKey: ObjectIdentifier(token)) != nil
        var recoveredSince: Date?
        if wasRegistered, openStalls.isEmpty, case let .unresponsive(since) = _health {
            _health = .healthy
            recoveredSince = since
        }
        lock.unlock()

        if let recoveredSince {
            let elapsed = Date().timeIntervalSince(recoveredSince)
            writeLogLine("AudioHALGateway: recovered after \(String(format: "%.1f", elapsed))s")
            postHealthChanged()
        }
    }

    private func openStall(_ token: AudioHALStallToken, label: String, timeout: TimeInterval?) {
        lock.lock()
        guard !token.isClosed, !token.isRegisteredOpen else {
            lock.unlock()
            return
        }
        token.isRegisteredOpen = true
        openStalls[ObjectIdentifier(token)] = token
        let becameUnresponsive = openStalls.count == 1
        if becameUnresponsive {
            _health = .unresponsive(since: Date())
        }
        lock.unlock()

        // Повторные fail-fast-отказы при уже открытом застое в лог не пишутся —
        // только сам переход healthy → unresponsive.
        if becameUnresponsive {
            writeLogLine(unresponsiveLogLine(label: label, timeout: timeout))
            postHealthChanged()
        }
    }

    // MARK: - Лог и уведомления

    private func unresponsiveLogLine(label: String, timeout: TimeInterval?) -> String {
        let timeoutText = timeout.map { String(format: "%.1fs", $0) } ?? "n/a"
        let plugins = halPluginBundles().joined(separator: ", ")
        return "AudioHALGateway unresponsive: label=\(label) timeout=\(timeoutText) "
            + "halPlugins=[\(plugins)] recover=\"sudo killall -9 coreaudiod\""
    }

    /// Чтение ФС, НЕ HAL — список сторонних HAL-плагинов (Wave Link, Loopback…),
    /// которые на практике и триггерят deadlock coreaudiod (план, «Контекст»,
    /// 18.09.2026: Elgato Wave Link `com.elgato.wavelink.aggregated-mixer`).
    private func halPluginBundles() -> [String] {
        let path = "/Library/Audio/Plug-Ins/HAL"
        return (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted() ?? []
    }

    private func postHealthChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.healthDidChangeNotification, object: self)
        }
    }

    private func deliverOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private static func runCatching<T>(_ work: () throws -> T) -> Result<T, Error> {
        do {
            return .success(try work())
        } catch {
            return .failure(error)
        }
    }

    private static func mapOutcome<T>(_ outcome: Result<T, Error>) -> Result<T, AudioHALError> {
        switch outcome {
        case .success(let value):
            return .success(value)
        case .failure(let error):
            return .failure(.failed(String(describing: error)))
        }
    }
}
