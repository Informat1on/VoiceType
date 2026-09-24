// PasteboardSnapshotTests.swift — VoiceType
//
// Unit tests for PasteboardSnapshot:
// 1. Round-trip of a multi-type, multi-item clipboard (string + RTF + PNG),
//    preserving item order and every type.
// 2. Empty pasteboard snapshots to empty items; write() clears the pasteboard.
// 3. materialize() returns .tooLarge when the payload exceeds maxTotalBytes.
// 4. capture() (async, background-queue path) round-trips on a private
//    pasteboard and reports the correct changeCount.
// 5. The two pure decision helpers on TextInjectionService.
//
// docs/plans/reliable-dictation.md § D1 / Task A.

import XCTest
import AppKit
@testable import VoiceType

final class PasteboardSnapshotTests: XCTestCase {

    private var pasteboard = NSPasteboard(name: NSPasteboard.Name("vt.test.placeholder"))

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("vt.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    // MARK: - Round-trip

    func testRoundTripPreservesMultipleItemsAndTypes() {
        let rtfData = Data("{\\rtf1 hello}".utf8)
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature bytes

        let firstItem = NSPasteboardItem()
        firstItem.setString("first item string", forType: .string)
        firstItem.setData(rtfData, forType: .rtf)

        let secondItem = NSPasteboardItem()
        secondItem.setData(pngData, forType: .png)

        pasteboard.clearContents()
        pasteboard.writeObjects([firstItem, secondItem])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        guard case .captured(let snapshot) = result else {
            return XCTFail("Expected .captured, got \(result)")
        }

        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items[0][.string], Data("first item string".utf8))
        XCTAssertEqual(snapshot.items[0][.rtf], rtfData)
        XCTAssertEqual(snapshot.items[1][.png], pngData)

        // Overwrite the pasteboard with something else, then restore.
        pasteboard.clearContents()
        pasteboard.setString("overwritten", forType: .string)

        snapshot.write(to: pasteboard)

        let restoredItems = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "first item string")
        XCTAssertEqual(restoredItems[0].data(forType: .rtf), rtfData)
        XCTAssertEqual(restoredItems[1].data(forType: .png), pngData)
    }

    // MARK: - Empty pasteboard

    func testEmptyPasteboardCapturesEmptyItemsAndWriteClears() {
        pasteboard.clearContents()

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        guard case .captured(let snapshot) = result else {
            return XCTFail("Expected .captured, got \(result)")
        }
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.totalBytes, 0)

        // Put something on the pasteboard, then write the empty snapshot over it.
        pasteboard.setString("should be cleared", forType: .string)
        snapshot.write(to: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
    }

    // MARK: - Too large

    func testMaterializeReturnsTooLargeWhenOverBudget() {
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: 1_000), forType: .string)

        let result = PasteboardSnapshot.materialize(from: pasteboard, maxTotalBytes: 10)

        guard case .tooLarge(let bytes) = result else {
            return XCTFail("Expected .tooLarge, got \(result)")
        }
        XCTAssertGreaterThan(bytes, 10)
    }

    // MARK: - Incomplete (unreadable type)

    /// A pasteboard item whose data provider promises `.string` (fulfilled)
    /// and `unreadableType` (deliberately never fulfilled), reproducing the
    /// real-world case `materialize()` must guard against: a type the item
    /// advertises in `.types` but for which `data(forType:)` returns `nil`.
    /// `NSPasteboardItem` does not retain its data provider, so the test
    /// keeps a strong reference for the pasteboard operations' duration.
    private final class PartiallyUnreadableDataProvider: NSObject, NSPasteboardItemDataProvider {
        static let unreadableType = NSPasteboard.PasteboardType("com.voicetype.test.unreadable")

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            guard type == .string else { return } // never provides data for `unreadableType`
            item.setData(Data("readable".utf8), forType: .string)
        }
    }

    func testMaterializeReturnsIncompleteWhenAdvertisedTypeDataIsUnreadable() {
        pasteboard.clearContents()
        let provider = PartiallyUnreadableDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string, PartiallyUnreadableDataProvider.unreadableType])
        pasteboard.writeObjects([item])

        let result = PasteboardSnapshot.materialize(from: pasteboard)

        guard case .incomplete(let unreadableTypes) = result else {
            return XCTFail("Expected .incomplete, got \(result)")
        }
        XCTAssertEqual(unreadableTypes, [PartiallyUnreadableDataProvider.unreadableType.rawValue])
        withExtendedLifetime(provider) {}
    }

    func testMaterializeIncompleteDoesNotRetryInsideCapture() async {
        // capture() only retries on .changedDuringCapture; .incomplete must
        // be returned as-is, on the first attempt, from the background path too.
        pasteboard.clearContents()
        let provider = PartiallyUnreadableDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string, PartiallyUnreadableDataProvider.unreadableType])
        pasteboard.writeObjects([item])

        let result = await PasteboardSnapshot.capture(from: pasteboard)

        guard case .incomplete(let unreadableTypes) = result else {
            return XCTFail("Expected .incomplete, got \(result)")
        }
        XCTAssertEqual(unreadableTypes, [PartiallyUnreadableDataProvider.unreadableType.rawValue])
        withExtendedLifetime(provider) {}
    }

    // MARK: - Async capture

    func testCaptureAsyncRoundTripsOnPrivatePasteboard() async {
        pasteboard.clearContents()
        pasteboard.setString("async capture text", forType: .string)
        let expectedChangeCount = pasteboard.changeCount

        let result = await PasteboardSnapshot.capture(from: pasteboard)

        guard case .captured(let snapshot) = result else {
            return XCTFail("Expected .captured, got \(result)")
        }
        XCTAssertEqual(snapshot.changeCount, expectedChangeCount)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0][.string], Data("async capture text".utf8))
    }

    // MARK: - Pure decision helpers (TextInjectionService)

    func testShouldWriteClipboardOnlyWhenChangeCountUnchanged() {
        XCTAssertTrue(TextInjectionService.shouldWriteClipboard(snapshotChangeCount: 5, currentChangeCount: 5))
        XCTAssertFalse(TextInjectionService.shouldWriteClipboard(snapshotChangeCount: 5, currentChangeCount: 6))
    }

    func testShouldRestoreClipboardOnlyWhenChangeCountUnchanged() {
        XCTAssertTrue(TextInjectionService.shouldRestoreClipboard(ourChangeCount: 7, currentChangeCount: 7))
        XCTAssertFalse(TextInjectionService.shouldRestoreClipboard(ourChangeCount: 7, currentChangeCount: 8))
    }
}
