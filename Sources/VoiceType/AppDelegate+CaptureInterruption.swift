// AppDelegate+CaptureInterruption.swift — VoiceType
//
// Обработка записи, прервавшейся не по воле пользователя. Вынесено из
// AppDelegate отдельным файлом: тот уже упирался в порог file_length, и
// поднимать порог вместо выноса механизма — ровно та подмена, от которой
// предостерегает беклог (TODOS §12.9).

import Foundation

extension AppDelegate {

    /// Запись прервалась не по воле пользователя: отключили устройство, сессия
    /// упала, файл перестал писаться. Останавливаем ровно одной обычной
    /// остановкой — сервис доставляет одно событие на запись, а единственный
    /// переход состояния живёт внутри stopRecording(). Уже записанное не
    /// выбрасывается: человек это произнёс, и решение о том, транскрибировать
    /// его или показать ошибку, принимается по фактическому числу сэмплов
    /// после барьера (CaptureInterruptionDecision).
    func setupCaptureInterruptionHandling() {
        audioCaptureService.onInterruption = { [weak self] interruption in
            guard let self else { return }
            guard self.appState == .recording else { return }
            AppLog.app.error("Recording interrupted: \(String(describing: interruption))")
            ErrorLogger.shared.log(
                message: "Recording interrupted: \(interruption)",
                category: "app"
            )
            self.interruptedCapture = interruption
            self.handleRecordingStopped()
        }
    }
}
