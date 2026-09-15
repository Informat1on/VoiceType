// AppDelegate+AsyncStart.swift — VoiceType
//
// Разбор асинхронного исхода AudioCaptureService.startRecording(...)
// (docs/plans/audio-start-hang.md). Вынесено из AppDelegate отдельным файлом
// по той же причине, что и AppDelegate+CaptureInterruption.swift: тот уже
// упирался в порог file_length.

import Foundation

extension AppDelegate {

    /// Отменяет незавершённый старт, если он есть. Общий выход из `.starting`
    /// для стопа (хоткей/меню), forceReset и завершения приложения.
    @discardableResult
    func cancelStartAttemptIfPending() -> Bool {
        guard appState == .starting else { return false }
        audioCaptureService.cancelPendingStart()
        currentStartAttemptID = nil
        return true
    }

    /// Стейл-результаты (попытка уже отменена/заменена) отбрасываются сверкой
    /// `currentStartAttemptID` — задача 1 плана, требование 2.
    func handleStartRecordingResult(_ result: Result<Void, AudioCaptureError>, attemptID: StartAttemptID) {
        guard currentStartAttemptID == attemptID else {
            print("[AppDelegate] Ignoring stale start result for attempt \(attemptID)")
            return
        }

        switch result {
        case .success:
            guard appState == .starting else {
                // Не должно быть достижимо: cancelPendingStart() гарантирует
                // ровно один терминальный исход. Fail-safe: не транскрибировать
                // с уже остановленной сессии.
                _ = try? audioCaptureService.stopRecording()
                return
            }
            currentStartAttemptID = nil
            appState = .recording
            recordingStartedAt = Date()
            voiceTypeWindow?.show(state: CapsuleState.recording)
            print("[AppDelegate] Recording started")
            AppLog.app.notice("Recording started")

        case .failure(let error):
            currentStartAttemptID = nil
            print("[AppDelegate] Failed to start recording: \(error)")
            AppLog.app.error("Recording failed to start")

            switch error {
            case .startCancelled:
                // Пользователь сам отпустил хоткей — handleRecordingStopped()
                // уже привёл состояние к идентичному виду синхронно, до этого
                // колбэка. Не ошибка, показывать нечего.
                break

            case .sessionStartTimedOut:
                // Не логируем повторно: AudioCaptureService.handleWatchdogFired
                // уже записал в errors.log UID + разрешённое фоном имя +
                // фактическую длительность (требование 15) — здесь этих
                // attempt-owned данных нет, только то, что несёт errorDescription.
                voiceTypeWindow?.show(state: .errorInline(message: "Mic not responding · Check input"))
                voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
                hotkeyService.syncIsRecording(false)
                appState = .idle

            case .captureDeviceBusy:
                ErrorLogger.shared.log(error, category: "app")
                voiceTypeWindow?.show(state: .errorInline(message: "Mic not responding · Check input"))
                voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
                hotkeyService.syncIsRecording(false)
                appState = .idle

            default:
                // Существующие кейсы сохраняют нынешнюю формулировку.
                ErrorLogger.shared.log(error, category: "app")
                voiceTypeWindow?.show(state: .errorInline(message: "Failed to start recording"))
                voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
                hotkeyService.syncIsRecording(false)
                appState = .idle
            }
        }
    }
}
