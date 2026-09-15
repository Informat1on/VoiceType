import AVFoundation
import XCTest
@testable import VoiceType

/// Приёмка буфера на входе записи. Проверяется тестом, а не живым микрофоном,
/// потому что нужный набор устройств (капризный драйвер, честный драйвер,
/// заведомо чужой формат) одновременно на столе не собирается.
///
/// Числа в двух первых тестах не выдуманы: это ASBD, снятые 13.09.2026 с той же
/// AVCaptureSession и тех же audioSettings, что в AudioCaptureService.
final class CaptureFormatValidatorTests: XCTestCase {

    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    private func reason(for asbd: AudioStreamBasicDescription) -> String? {
        CaptureFormatValidator.rejectionReason(
            for: asbd,
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels
        )
    }

    /// Формат, годный к записи. По умолчанию — ровно то, что просят
    /// audioSettings: 16 кГц, моно, int16 little-endian.
    private func asbd(
        rate: Double = 16000,
        channels: UInt32 = 1,
        bits: UInt32 = 16,
        bytesPerFrame: UInt32 = 2,
        framesPerPacket: UInt32 = 1,
        bytesPerPacket: UInt32? = nil,
        flags: AudioFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        formatID: AudioFormatID = kAudioFormatLinearPCM
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: formatID,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerPacket ?? bytesPerFrame,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    // MARK: - Устройства, снятые вживую

    /// Elgato Wave XLR MK.2: mFormatFlags = 4, то есть один только
    /// IsSignedInteger — флага IsPacked драйвер не выставляет. Данные при этом
    /// упакованы, и запись обязана идти. Ровно этот формат до 13.09.2026
    /// отвергался на первом же буфере.
    func testAcceptsSignedIntegerFormatWithoutPackedFlag() {
        let format = asbd(flags: kAudioFormatFlagIsSignedInteger)
        XCTAssertEqual(format.mFormatFlags, 4, "предпосылка теста: ASBD, снятый с Wave XLR MK.2")
        XCTAssertNil(reason(for: format))
    }

    /// Встроенный микрофон MacBook Pro и виртуальные устройства Wave Link на том
    /// же тракте: mFormatFlags = 12, с флагом IsPacked. Принимались раньше,
    /// обязаны приниматься и теперь.
    func testAcceptsSignedIntegerFormatWithPackedFlag() {
        let format = asbd(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        XCTAssertEqual(format.mFormatFlags, 12, "предпосылка теста: ASBD, снятый со встроенного микрофона")
        XCTAssertNil(reason(for: format))
    }

    // MARK: - Отказы

    /// Главное, что должна была ловить прежняя проверка флагом: отсчёт уже
    /// контейнера, в котором лежит. Геометрия ловит это и без флага —
    /// иначе замена ослабила бы приёмку, а не ужесточила.
    func testRejectsSampleNarrowerThanItsContainer() {
        let detail = reason(for: asbd(bytesPerFrame: 4, flags: kAudioFormatFlagIsSignedInteger))
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail?.contains("4 bytes per frame, expected 2") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsStereo() {
        let detail = reason(for: asbd(channels: 2, bytesPerFrame: 4))
        XCTAssertTrue(detail?.contains("2 channels, expected 1") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsNativeSampleRate() {
        let detail = reason(for: asbd(rate: 48000))
        XCTAssertTrue(detail?.contains("sample rate 48000.0") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsFloatSamples() {
        let detail = reason(for: asbd(
            bits: 32,
            bytesPerFrame: 4,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        ))
        XCTAssertTrue(detail?.contains("floating-point") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsUnsignedSamples() {
        let detail = reason(for: asbd(flags: kAudioFormatFlagIsPacked))
        XCTAssertTrue(detail?.contains("not signed integers") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsBigEndianSamples() {
        let detail = reason(for: asbd(
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian
        ))
        XCTAssertTrue(detail?.contains("big-endian") ?? false, "получено: \(detail ?? "nil")")
    }

    /// На моно non-interleaved побайтно неотличим от interleaved, поэтому
    /// путь копирования его бы «переварил». Контракт всё равно обязан быть
    /// заявленным: делегат читает единственный блок как interleaved.
    func testRejectsNonInterleavedSamples() {
        let detail = reason(for: asbd(
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved
        ))
        XCTAssertTrue(detail?.contains("non-interleaved") ?? false, "получено: \(detail ?? "nil")")
    }

    /// Кадр без каналов: геометрию по нему считать не из чего, и подставлять
    /// вместо нуля единицу нельзя — иначе испорченный ASBD пройдёт по
    /// выдуманному размеру кадра.
    func testRejectsZeroChannels() {
        let detail = reason(for: asbd(channels: 0))
        XCTAssertTrue(detail?.contains("zero channels per frame") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsMismatchedBytesPerPacket() {
        let detail = reason(for: asbd(bytesPerPacket: 4))
        XCTAssertTrue(detail?.contains("4 bytes per packet, expected 2") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsCompressedFormat() {
        let detail = reason(for: asbd(formatID: kAudioFormatMPEG4AAC))
        XCTAssertTrue(detail?.contains("not linear PCM") ?? false, "получено: \(detail ?? "nil")")
    }

    func testRejectsMultiFramePackets() {
        let detail = reason(for: asbd(framesPerPacket: 1024))
        XCTAssertTrue(detail?.contains("1024 frames per packet") ?? false, "получено: \(detail ?? "nil")")
    }

    // MARK: - Диагностируемость

    /// Отказ обязан называть первопричину и устройство: три прежних отказа были
    /// неразличимы в errors.log.
    func testRejectionNamesBothTheProblemAndTheFullFormat() {
        let detail = reason(for: asbd(rate: 44100, channels: 2, bytesPerFrame: 4)) ?? ""
        XCTAssertTrue(detail.contains("sample rate 44100.0"))
        XCTAssertTrue(detail.contains("2 channels"))
        XCTAssertTrue(detail.contains("flags=0x"), "полный ASBD: \(detail)")
    }
}
