// RecordingWindowTests.swift — Tier A Step 6 (Scope E)
//
// Tests CapsuleStateModel as a pure ObservableObject — no NSWindow
// instantiation (display-env-dependent; excluded from headless CI).
//
// DESIGN.md § Implementation Plan Step 6.
// DESIGN.md Decisions Log D2: single NSHostingView + @Published CapsuleState.

import XCTest
import Combine
@testable import VoiceType

final class RecordingWindowTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - CapsuleStateModel — initial state

    func testCapsuleStateModelDefaultStateIsRecording() {
        let model = CapsuleStateModel()
        XCTAssertEqual(model.state, .recording, "CapsuleStateModel default state must be .recording")
    }

    // MARK: - CapsuleStateModel — state mutation publishes

    func testCapsuleStateModelPublishesOnStateChange() {
        let model = CapsuleStateModel()
        let expectation = expectation(description: "state change published")
        var receivedStates: [CapsuleState] = []

        model.$state
            .dropFirst() // skip initial value
            .sink { state in
                receivedStates.append(state)
                if receivedStates.count == 1 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        model.state = .transcribing

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedStates, [.transcribing])
    }

    func testCapsuleStateModelPublishesInsertedState() {
        let model = CapsuleStateModel()
        let expectation = expectation(description: "inserted state published")

        model.$state
            .dropFirst()
            .sink { state in
                if case .inserted(let count, let app) = state {
                    XCTAssertEqual(count, 123)
                    XCTAssertEqual(app, "Cursor")
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        model.state = .inserted(charCount: 123, targetAppName: "Cursor")

        wait(for: [expectation], timeout: 1.0)
    }

    func testCapsuleStateModelPublishesErrorInline() {
        let model = CapsuleStateModel()
        let expectation = expectation(description: "errorInline published")

        model.$state
            .dropFirst()
            .sink { state in
                if case .errorInline(let msg) = state {
                    XCTAssertEqual(msg, "Mic denied")
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        model.state = .errorInline(message: "Mic denied")

        wait(for: [expectation], timeout: 1.0)
    }

    func testCapsuleStateModelPublishesEmptyResult() {
        let model = CapsuleStateModel()
        let expectation = expectation(description: "emptyResult published")

        model.$state
            .dropFirst()
            .sink { state in
                if state == .emptyResult {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        model.state = .emptyResult

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - CapsuleStateModel — sequential transitions

    func testCapsuleStateModelHandlesFullRecordingCycle() {
        let model = CapsuleStateModel()
        var states: [CapsuleState] = []
        let expectation = expectation(description: "full cycle")
        expectation.expectedFulfillmentCount = 3

        model.$state
            .dropFirst()
            .sink { state in
                states.append(state)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        model.state = .transcribing
        model.state = .inserted(charCount: 50, targetAppName: "Notes")
        model.state = .recording

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(states, [
            .transcribing,
            .inserted(charCount: 50, targetAppName: "Notes"),
            .recording
        ])
    }

    // MARK: - CapsuleStateModel — is ObservableObject

    func testCapsuleStateModelIsObservableObject() {
        // Verify the type constraint is satisfied — compile-time check
        let model: any ObservableObject = CapsuleStateModel()
        XCTAssertNotNil(model)
    }
}
