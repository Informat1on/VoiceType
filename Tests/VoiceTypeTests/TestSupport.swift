// TestSupport.swift — VoiceType
//
// Shared hermeticity helpers (T3, plan §3 "Герметичные тесты: errors.log и
// defaults-домены"): keep ErrorLogger writes out of the real
// ~/Library/Logs/VoiceType/errors.log, and stop suite-scoped UserDefaults
// tests from leaving ~/Library/Preferences/<suite>.plist files behind.

import XCTest
@testable import VoiceType

/// A throwaway `ErrorLogger` writing into `dir` (a test's own temp
/// directory, already covered by its `addTeardownBlock`), so
/// `HistoryStore.test(...)` and friends never touch the real errors.log.
@MainActor
func makeTestErrorLogger(in dir: URL) -> ErrorLogger {
    ErrorLogger.test(logsDirectory: dir.appendingPathComponent("logs"))
}

/// Thrown when a suite-scoped `UserDefaults` could not be opened at all —
/// in practice this never happens for a well-formed suite name.
struct HermeticDefaultsUnavailable: Error {}

/// True for a usable UserDefaults suite name: non-empty, no path separator
/// ("/" or "\\"), and not starting with "." — the same defensive shape as
/// `HistoryStore.isSafeAudioFilename`, since this name is also built
/// directly into a filesystem path below
/// (~/Library/Preferences/<suite>.plist). Review finding, T3 code review.
private func isSafeSuiteName(_ suiteName: String) -> Bool {
    !suiteName.isEmpty
        && !suiteName.contains("/")
        && !suiteName.contains("\\")
        && !suiteName.hasPrefix(".")
}

/// Runs `body` against a fresh, suite-scoped `UserDefaults`, then tears it
/// down the way the T3 investigation found necessary to stop new
/// `~/Library/Preferences/voicetype.tests.*.plist` files from accumulating.
///
/// Root cause (confirmed empirically, 2026-09-26): `cfprefsd` flushes a
/// suite's writes to disk on its OWN schedule, not synchronously with
/// `set(...)`. A single-process, low-contention check sees the plist appear
/// immediately and disappear cleanly after `removePersistentDomain` +
/// `CFPreferencesSynchronize` + a direct file delete (the original version of
/// this helper). But under the concurrent UserDefaults traffic a full `swift
/// test` run produces, that is a genuine RACE, not a guarantee: `cfprefsd`
/// can still be mid-flush of the domain's ORIGINAL (pre-removal) contents
/// when we delete, so it recreates the file afterward — reproduced directly
/// (2026-09-26, throwaway harness in scratchpad, not checked in): hammering
/// unrelated suite domains from 6 background threads while running the
/// original sequence 300 times left 127/300 plist files on disk 3s after
/// process exit. Two fixes made this reliably 0/300 (same harness, two
/// repeated runs):
///   1. Force OUR OWN flush of the suite — `synchronize()` on the `body`'s
///      `UserDefaults` instance while it is still alive, THEN
///      `CFPreferencesSynchronize` for the same domain — BEFORE
///      `removePersistentDomain` runs. This drains whatever `cfprefsd` had
///      queued for this domain under our control, so the domain has nothing
///      left to flush later using stale (pre-removal) data.
///   2. Retry the file delete for a bounded window (~1s worst case, 0ms in
///      the common case) instead of trying exactly once — belt-and-suspenders
///      for any flush that still lands after step 1.
/// There is no public API to make a NAMED `UserDefaults(suiteName:)` skip
/// `cfprefsd`/disk entirely (`setVolatileDomain` only overlays read
/// priority, `set(...)` still targets the persistent domain), so avoiding
/// the plist file altogether was not an option.
///
/// The cleanup runs in `defer`, so it happens on every exit from `body` —
/// including a thrown error — not just the success path (review finding,
/// T3 code review). The `UserDefaults` used by `body` is scoped to the
/// immediately-invoked closure below and goes out of scope when that
/// closure returns or throws, before the outer `defer` runs — matching the
/// order the investigation used ("flush and release the UserDefaults
/// object, then remove the persistent domain").
@MainActor
func withHermeticUserDefaults<T>(
    suiteName: String = "voicetype.tests.\(UUID().uuidString)",
    _ body: (UserDefaults) throws -> T
) throws -> T {
    defer { cleanUpHermeticUserDefaults(suiteName: suiteName) }

    return try {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw HermeticDefaultsUnavailable()
        }
        // Runs on every exit from `body` (success or throw), before
        // `defaults` goes out of scope — forces our own flush so
        // `cleanUpHermeticUserDefaults` below isn't racing a delayed one.
        defer {
            defaults.synchronize()
            CFPreferencesSynchronize(suiteName as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return try body(defaults)
    }()
}

/// The `defer`red half of `withHermeticUserDefaults` — split into its own
/// function because a bare `return` (from the unsafe-name guard) cannot
/// appear directly inside a `defer` body.
@MainActor
private func cleanUpHermeticUserDefaults(suiteName: String) {
    // An unsafe suiteName is refused outright and nothing is deleted —
    // review finding, T3 code review.
    guard isSafeSuiteName(suiteName) else {
        XCTFail("withHermeticUserDefaults: refusing to clean up an unsafe suiteName (\"\(suiteName)\")")
        return
    }
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    CFPreferencesSynchronize(suiteName as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let plistURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Preferences")
        .appendingPathComponent("\(suiteName).plist")
    // Bounded retry (~1s worst case, 0ms in the common case): a delayed
    // cfprefsd flush can still land after the synchronize above under
    // contention — see the mechanism note on withHermeticUserDefaults.
    for attempt in 0..<10 {
        try? FileManager.default.removeItem(at: plistURL)
        if !FileManager.default.fileExists(atPath: plistURL.path) { return }
        usleep(useconds_t(20_000 * (attempt + 1)))
    }
}
