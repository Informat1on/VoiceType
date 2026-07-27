// AudioDeviceResolver.swift — VoiceType
//
// Два решения из пути записи, вынесенные в чистые функции: какое устройство
// брать и что делать с прерванной записью. Обе живут отдельно от захвата
// намеренно — это единственный способ проверить их без микрофона, а гонки и
// откаты как раз там, где живого прогона не устроишь.

import Foundation

/// Какое устройство брать при старте записи.
enum AudioDeviceDecision: Equatable {
    /// Писать с выбранного пользователем устройства.
    case usePreferred(uid: String)
    /// Писать с системного по умолчанию: пользователь его и выбрал (nil в
    /// настройках) либо выбранный UID совпадает с системным.
    case useSystemDefault(uid: String?)
    /// Выбранного устройства сейчас нет — пишем с системного и говорим об этом.
    case fallback(uid: String, reason: DeviceFallbackReason)
    /// Ни выбранного, ни системного: записывать не с чего.
    case noDevice
}

enum AudioDeviceResolver {

    /// `availableUIDs` — то, что CoreAudio показывает сейчас; `systemDefaultUID`
    /// — системное устройство по умолчанию (nil, если его нет).
    ///
    /// Отдельный случай «выбранное совпадает с системным» существует не для
    /// красоты: если UID совпадают, откатываться при сбое некуда, и делать вид,
    /// что есть запасной путь, значит врать пользователю в подсказке.
    static func resolve(
        preferredUID: String?,
        availableUIDs: [String],
        systemDefaultUID: String?
    ) -> AudioDeviceDecision {
        guard let preferredUID, !preferredUID.isEmpty else {
            guard systemDefaultUID != nil || !availableUIDs.isEmpty else { return .noDevice }
            return .useSystemDefault(uid: systemDefaultUID)
        }

        if preferredUID == systemDefaultUID {
            return .useSystemDefault(uid: systemDefaultUID)
        }

        if availableUIDs.contains(preferredUID) {
            return .usePreferred(uid: preferredUID)
        }

        // Выбранного устройства нет. Настройку НЕ трогаем: гарнитуру подключат
        // обратно, и молча переписать выбор пользователя было бы хуже, чем
        // временно писать с другого устройства и сказать об этом.
        guard let systemDefaultUID else { return .noDevice }
        return .fallback(
            uid: systemDefaultUID,
            reason: .selectedDeviceUnavailable(uid: preferredUID)
        )
    }
}

/// Что делать с записью, прерванной не по воле пользователя.
enum CaptureInterruptionOutcome: Equatable {
    /// Что-то записалось — транскрибируем это и сообщаем, что запись прервана.
    /// Терять уже сказанное нельзя: человек это произнёс.
    case transcribePartial
    /// Не записалось ничего — показываем ошибку.
    case showError
    /// Событие пришло, когда запись уже останавливается или закончилась.
    /// Молчим: пользователь получил бы ошибку на успешно завершённой записи.
    case ignore
}

enum CaptureInterruptionDecision {

    /// `isRecording` — была ли запись активна в момент, когда решение
    /// принимается; `sampleCount` — окончательное число сэмплов, снятое ПОСЛЕ
    /// барьера, а не счётчик на момент прихода уведомления.
    static func decide(isRecording: Bool, sampleCount: Int) -> CaptureInterruptionOutcome {
        guard isRecording else { return .ignore }
        return sampleCount > 0 ? .transcribePartial : .showError
    }
}
