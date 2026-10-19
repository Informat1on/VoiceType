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

    // MARK: - Redundant lazy types (docs/plans/lazy-pasteboard-types.md)

    // NSPasteboardItem rejects non-UTI type strings ("Apple Web Archive pasteboard type",
    // "iOS rich content paste pasteboard type"), so the fixtures use the only valid-UTI member
    // of `redundantLazyTypes`: com.apple.webarchive.
    private static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
    private static let html = NSPasteboard.PasteboardType("public.html")
    private static let plain = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let unknownLazy = NSPasteboard.PasteboardType("com.voicetype.test.unknown-lazy")

    /// Serves the given data per type; any advertised type absent from
    /// `readable` stays unfulfilled (`data(forType:)` returns nil).
    private final class SelectiveDataProvider: NSObject, NSPasteboardItemDataProvider {
        let readable: [NSPasteboard.PasteboardType: Data]

        init(readable: [NSPasteboard.PasteboardType: Data]) {
            self.readable = readable
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            guard let data = readable[type] else { return }
            item.setData(data, forType: type)
        }
    }

    /// Writes one item per entry of `specs` (advertised types in order, plus
    /// readable data) and returns the providers to keep alive.
    private func writeLazyItems(
        _ specs: [(types: [NSPasteboard.PasteboardType], readable: [NSPasteboard.PasteboardType: Data])]
    ) -> [SelectiveDataProvider] {
        pasteboard.clearContents()
        var providers: [SelectiveDataProvider] = []
        var items: [NSPasteboardItem] = []
        for spec in specs {
            let provider = SelectiveDataProvider(readable: spec.readable)
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: spec.types)
            providers.append(provider)
            items.append(item)
        }
        pasteboard.writeObjects(items)
        return providers
    }

    private static let webArchiveName = "com.apple.webarchive"

    func testT1RedundantLazyTypesDroppedWhenHtmlAndPlainReadable() {
        let htmlData = Data("<b>hi</b>".utf8)
        let plainData = Data("hi".utf8)
        let providers = writeLazyItems([(
            types: [Self.html, Self.plain, Self.webArchive],
            readable: [Self.html: htmlData, Self.plain: plainData]
        )])

        guard case .captured(let snapshot) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured")
        }
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0][Self.html], htmlData)
        XCTAssertEqual(snapshot.items[0][Self.plain], plainData)
        XCTAssertNil(snapshot.items[0][Self.webArchive])
        XCTAssertEqual(snapshot.droppedRedundantTypes, [Self.webArchiveName])

        snapshot.write(to: pasteboard)
        guard case .captured(let restored) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured after write")
        }
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items[0][Self.html], htmlData)
        XCTAssertEqual(restored.items[0][Self.plain], plainData)
        withExtendedLifetime(providers) {}
    }

    func testT2RedundantTypeWithoutTextFallbackIsIncomplete() {
        let providers = writeLazyItems([(
            types: [.png, Self.webArchive],
            readable: [.png: Data([0x89, 0x50])]
        )])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        XCTAssertEqual(result, .incomplete(unreadableTypes: [Self.webArchiveName]))
        withExtendedLifetime(providers) {}
    }

    func testT3UnknownUnreadableTypeBlocksEvenWithFallback() {
        let providers = writeLazyItems([(
            types: [Self.html, Self.webArchive, Self.unknownLazy],
            readable: [Self.html: Data("<i>x</i>".utf8)]
        )])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        XCTAssertEqual(
            result,
            .incomplete(unreadableTypes: [Self.webArchiveName, Self.unknownLazy.rawValue])
        )
        withExtendedLifetime(providers) {}
    }

    func testT4RuleIsPerItemNotPerPasteboard() {
        let providers = writeLazyItems([
            (types: [Self.html, Self.webArchive], readable: [Self.html: Data("<b>a</b>".utf8)]),
            (types: [Self.webArchive], readable: [:])
        ])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        XCTAssertEqual(result, .incomplete(unreadableTypes: [Self.webArchiveName]))
        withExtendedLifetime(providers) {}
    }

    func testT5OrdinaryPasteboardHasNoDroppedTypes() {
        pasteboard.clearContents()
        pasteboard.setString("plain", forType: .string)

        guard case .captured(let snapshot) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured")
        }
        XCTAssertEqual(snapshot.droppedRedundantTypes, [])
    }

    func testT6AsyncCaptureDropsRedundantLazyTypes() async {
        let providers = writeLazyItems([(
            types: [Self.html, Self.plain, Self.webArchive],
            readable: [Self.html: Data("<b>hi</b>".utf8), Self.plain: Data("hi".utf8)]
        )])

        let result = await PasteboardSnapshot.capture(from: pasteboard)
        guard case .captured(let snapshot) = result else {
            return XCTFail("Expected .captured, got \(result)")
        }
        XCTAssertEqual(snapshot.droppedRedundantTypes, [Self.webArchiveName])
        withExtendedLifetime(providers) {}
    }

    func testT7EmptyHtmlIsNotATextFallback() {
        let providers = writeLazyItems([(
            types: [Self.html, Self.webArchive],
            readable: [Self.html: Data()]
        )])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        XCTAssertEqual(result, .incomplete(unreadableTypes: [Self.webArchiveName]))
        withExtendedLifetime(providers) {}
    }

    func testT7bEmptyHtmlIsKeptInItemsWhenPlainTextIsReadable() {
        let plainData = Data("hi".utf8)
        let providers = writeLazyItems([(
            types: [Self.html, Self.plain, Self.webArchive],
            readable: [Self.html: Data(), Self.plain: plainData]
        )])

        guard case .captured(let snapshot) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured")
        }
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0][Self.html], Data())
        XCTAssertEqual(snapshot.items[0][Self.plain], plainData)
        XCTAssertNil(snapshot.items[0][Self.webArchive])
        XCTAssertEqual(snapshot.droppedRedundantTypes, [Self.webArchiveName])
        withExtendedLifetime(providers) {}
    }

    func testT10IncompleteListsAllUnreadableTypesInFirstSeenOrderWithoutRepeats() {
        // "iOS rich content paste pasteboard type" is not a valid UTI and cannot be fixtures
        // on NSPasteboardItem, so a second unknown type stands in for it.
        let unknownA = NSPasteboard.PasteboardType("test.unknown.a")
        let unknownB = NSPasteboard.PasteboardType("test.unknown.b")
        let providers = writeLazyItems([
            (types: [Self.html, Self.webArchive, unknownA], readable: [Self.html: Data("<b>a</b>".utf8)]),
            (types: [Self.html, unknownA, Self.webArchive, unknownB], readable: [Self.html: Data("<b>b</b>".utf8)])
        ])

        let result = PasteboardSnapshot.materialize(from: pasteboard)
        XCTAssertEqual(
            result,
            .incomplete(unreadableTypes: [Self.webArchiveName, unknownA.rawValue, unknownB.rawValue])
        )
        withExtendedLifetime(providers) {}
    }

    func testT8LazyTypeDeclaredBeforeFallbackStillDropped() {
        let providers = writeLazyItems([(
            types: [Self.webArchive, Self.html],
            readable: [Self.html: Data("<b>a</b>".utf8)]
        )])

        XCTAssertEqual(pasteboard.pasteboardItems?[0].types.first, Self.webArchive)
        guard case .captured(let snapshot) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured")
        }
        XCTAssertEqual(snapshot.droppedRedundantTypes, [Self.webArchiveName])
        withExtendedLifetime(providers) {}
    }

    func testT9MultipleItemsDeduplicateDroppedTypesAndRoundTrip() {
        let html1 = Data("<b>one</b>".utf8)
        let html2 = Data("<b>two</b>".utf8)
        let html3 = Data("<b>three</b>".utf8)
        let providers = writeLazyItems([
            (types: [Self.html, Self.webArchive], readable: [Self.html: html1]),
            (types: [Self.webArchive, Self.html], readable: [Self.html: html2]),
            (types: [Self.html, Self.webArchive], readable: [Self.html: html3])
        ])

        guard case .captured(let snapshot) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured")
        }
        XCTAssertEqual(snapshot.droppedRedundantTypes, [Self.webArchiveName])
        XCTAssertEqual(snapshot.items.count, 3)

        snapshot.write(to: pasteboard)
        guard case .captured(let restored) = PasteboardSnapshot.materialize(from: pasteboard) else {
            return XCTFail("Expected .captured after write")
        }
        XCTAssertEqual(restored.items.count, 3)
        XCTAssertEqual(restored.items.map { $0[Self.html] }, [html1, html2, html3])
        for item in restored.items {
            XCTAssertNil(item[Self.webArchive])
        }
        XCTAssertEqual(restored.droppedRedundantTypes, [])
        withExtendedLifetime(providers) {}
    }

    // MARK: - classifyUnreadable with raw Safari type strings

    private static let rawWebArchive = "Apple Web Archive pasteboard type"
    private static let rawIosRich = "iOS rich content paste pasteboard type"

    func testClassifyDropsBothRawSafariTypesWithNonEmptyHtml() {
        let result = PasteboardSnapshot.classifyUnreadable(
            [Self.rawWebArchive, Self.rawIosRich],
            capturedTypes: ["public.html": Data("<b>x</b>".utf8)]
        )
        XCTAssertEqual(result.dropped, [Self.rawWebArchive, Self.rawIosRich])
        XCTAssertEqual(result.blocking, [])
    }

    func testClassifyBlocksRawSafariTypesWhenOnlyHtmlIsEmpty() {
        let result = PasteboardSnapshot.classifyUnreadable(
            [Self.rawWebArchive, Self.rawIosRich],
            capturedTypes: ["public.html": Data()]
        )
        XCTAssertEqual(result.dropped, [])
        XCTAssertEqual(result.blocking, [Self.rawWebArchive, Self.rawIosRich])
    }

    func testClassifySplitsRedundantAndUnknownWithRtfFallback() {
        let result = PasteboardSnapshot.classifyUnreadable(
            [Self.rawWebArchive, "test.unknown.a"],
            capturedTypes: ["public.rtf": Data("{\\rtf1}".utf8)]
        )
        XCTAssertEqual(result.dropped, [Self.rawWebArchive])
        XCTAssertEqual(result.blocking, ["test.unknown.a"])
    }

    func testClassifyBlocksRawIosRichWithoutTextFallback() {
        let result = PasteboardSnapshot.classifyUnreadable(
            [Self.rawIosRich],
            capturedTypes: ["public.png": Data([0x89])]
        )
        XCTAssertEqual(result.dropped, [])
        XCTAssertEqual(result.blocking, [Self.rawIosRich])
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
