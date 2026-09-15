// CaptureFormatValidator.swift — VoiceType
//
// Проверка формата буферов, приходящих от AVCaptureAudioDataOutput.
//
// Вынесена из делегата отдельным типом по двум причинам: внутри captureOutput
// её нельзя было накрыть тестом (нужен настоящий CMSampleBuffer), и именно она
// 13.09.2026 отвергла заведомо исправные буферы Elgato Wave XLR MK.2.
//
// Что произошло: прежняя проверка требовала флаг kAudioFormatFlagIsPacked.
// Драйвер Wave XLR MK.2 его не выставляет — mFormatFlags = 4, один только
// IsSignedInteger, — хотя данные упакованы: 16 бит в 2 байтах на кадр, длина
// блок-буфера ровно frames × 2. Встроенный микрофон и виртуальные устройства
// Wave Link на том же тракте отдают mFormatFlags = 12, с флагом (замерено на
// той же сессии и тех же audioSettings). То есть флаг описывает не свойство
// данных, а добросовестность драйвера, и запись срывалась на первом же буфере.
//
// Чем заменено: упаковка выводится из геометрии, а не принимается на слово.
// mBitsPerChannel == 16 вместе с mBytesPerFrame == 2 × каналы не оставляет в
// кадре ни одного неиспользуемого бита — это и есть packed, только посчитанный,
// а не заявленный. Проверка при этом стала строже прежней, а не мягче: 16 бит
// в 4-байтовом контейнере она отвергает по числам, тогда как один лишь флаг
// Packed в паре с bits == 16 такой случай пропускал.

import AVFoundation
import Foundation

/// Формат буфера обязан быть ровно тем, что запрошен в `audioSettings`:
/// writer сконфигурирован под int16, и «терпимая» запись чужого формата
/// означала бы записать мусор под видом речи.
enum CaptureFormatValidator {

    private static let bytesPerSample = UInt32(MemoryLayout<Int16>.size)

    /// `nil` — буфер годен к записи. Иначе — причина отказа, пригодная и для
    /// `errors.log`, и для показа человеку: три прежних отказа давали один и тот
    /// же текст, и по логу нельзя было понять, что именно не совпало.
    static func rejectionReason(
        for asbd: AudioStreamBasicDescription,
        targetSampleRate: Double,
        targetChannels: AVAudioChannelCount
    ) -> String? {
        var problems: [String] = []

        if asbd.mFormatID != kAudioFormatLinearPCM {
            problems.append("not linear PCM")
        }
        if asbd.mSampleRate != targetSampleRate {
            problems.append("sample rate \(asbd.mSampleRate), expected \(targetSampleRate)")
        }
        if asbd.mChannelsPerFrame != UInt32(targetChannels) {
            problems.append("\(asbd.mChannelsPerFrame) channels, expected \(targetChannels)")
        }
        if asbd.mBitsPerChannel != bytesPerSample * 8 {
            problems.append("\(asbd.mBitsPerChannel) bits per sample, expected \(bytesPerSample * 8)")
        }

        problems.append(contentsOf: flagProblems(asbd.mFormatFlags))
        problems.append(contentsOf: geometryProblems(asbd))

        guard !problems.isEmpty else { return nil }
        return problems.joined(separator: "; ") + " (\(describe(asbd)))"
    }

    private static func flagProblems(_ flags: AudioFormatFlags) -> [String] {
        var problems: [String] = []
        if flags & kAudioFormatFlagIsFloat != 0 {
            problems.append("floating-point samples, expected signed integer")
        }
        if flags & kAudioFormatFlagIsSignedInteger == 0 {
            problems.append("samples are not signed integers")
        }
        if flags & kAudioFormatFlagIsBigEndian != 0 {
            problems.append("big-endian samples, expected little-endian")
        }
        // Делегат копирует ЕДИНСТВЕННЫЙ блок-буфер в int16ChannelData как
        // сплошной interleaved-кусок. На моно non-interleaved совпал бы с ним
        // побайтно и прошёл бы незамеченным, но совпадение — не контракт:
        // стоит появиться второму каналу или другому представлению
        // CMSampleBuffer, и тот же путь прочитает данные неверно.
        if flags & kAudioFormatFlagIsNonInterleaved != 0 {
            problems.append("non-interleaved samples, expected interleaved")
        }
        // kAudioFormatFlagIsPacked здесь намеренно НЕ проверяется — см. шапку
        // файла. Упаковку доказывает geometryProblems, и доказывает строже.
        return problems
    }

    /// Числа кадра: именно они, а не флаги, решают, влезает ли отсчёт в
    /// отведённое ему место без дырок.
    private static func geometryProblems(_ asbd: AudioStreamBasicDescription) -> [String] {
        var problems: [String] = []
        // Кадр без каналов — испорченный ASBD, а не формат, размер которого
        // можно досчитать. Подставить сюда 1 значило бы сверять геометрию с
        // выдуманным числом и признать годным кадр, которого не существует.
        guard asbd.mChannelsPerFrame > 0 else {
            return ["zero channels per frame"]
        }
        let expectedBytesPerFrame = bytesPerSample * asbd.mChannelsPerFrame

        if asbd.mBytesPerFrame != expectedBytesPerFrame {
            problems.append("\(asbd.mBytesPerFrame) bytes per frame, expected \(expectedBytesPerFrame)")
        }
        // Для linear PCM пакет — это ровно один кадр. Иное значение означает,
        // что перед нами не тот формат, под который открыт writer.
        if asbd.mFramesPerPacket != 1 {
            problems.append("\(asbd.mFramesPerPacket) frames per packet, expected 1")
        }
        if asbd.mBytesPerPacket != expectedBytesPerFrame {
            problems.append("\(asbd.mBytesPerPacket) bytes per packet, expected \(expectedBytesPerFrame)")
        }
        return problems
    }

    /// Полный ASBD в отказе нужен всегда: несовпавшее поле называет причину, а
    /// остальные говорят, какое устройство её принесло.
    private static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        "rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) "
            + "bytesPerFrame=\(asbd.mBytesPerFrame) framesPerPacket=\(asbd.mFramesPerPacket) "
            + "bytesPerPacket=\(asbd.mBytesPerPacket) flags=0x\(String(asbd.mFormatFlags, radix: 16))"
    }
}
