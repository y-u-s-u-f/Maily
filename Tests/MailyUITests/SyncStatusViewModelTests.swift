import XCTest
import Combine
@testable import MailyUI
import MailyCore

@MainActor
final class SyncStatusViewModelTests: XCTestCase {

    // MARK: - Test 1: Initial label is Idle

    func testInitialLabelIsIdle() {
        let vm = SyncStatusViewModel(phaseStream: {
            // Stream that never yields anything
            AsyncStream { _ in }
        })
        XCTAssertEqual(vm.label, "Idle")
    }

    // MARK: - Test 2: Each phase maps to expected label

    func testEachPhaseMapsToExpectedLabel() {
        let cases: [(SyncEngine.Phase, String)] = [
            (.idle, "Idle"),
            (.enumerating, "Scanning labels…"),
            (.fetchingMetadata(processed: 0), "Loading messages (0)…"),
            (.fetchingMetadata(processed: 42), "Loading messages (42)…"),
            (.fetchingBodies(processed: 0), "Loading bodies (0)…"),
            (.fetchingBodies(processed: 7), "Loading bodies (7)…"),
            (.watching, "Up to date"),
            (.draining, "Sending…"),
            (.error(message: "boom"), "Error: boom"),
            (.error(message: "network timeout"), "Error: network timeout"),
        ]

        for (phase, expectedLabel) in cases {
            let result = SyncStatusViewModel.label(for: phase)
            XCTAssertEqual(result, expectedLabel,
                           "Phase \(phase) should map to \"\(expectedLabel)\"")
        }
    }

    // MARK: - Test 3: Multiple phases update label in order

    func testMultiplePhasesUpdateLabelInOrder() async throws {
        let (stream, cont) = AsyncStream<SyncEngine.Phase>.makeStream()
        let vm = SyncStatusViewModel(phaseStream: { stream })

        let expected = ["Scanning labels…", "Loading messages (3)…", "Up to date"]
        var observed: [String] = []
        let allObserved = expectation(description: "all phases observed")
        var bag = Set<AnyCancellable>()

        vm.$label
            .dropFirst() // skip initial "Idle"
            .sink { value in
                observed.append(value)
                if observed == expected { allObserved.fulfill() }
            }
            .store(in: &bag)

        Task { await vm.start() }

        cont.yield(.enumerating)
        cont.yield(.fetchingMetadata(processed: 3))
        cont.yield(.watching)

        await fulfillment(of: [allObserved], timeout: 2.0)
        XCTAssertEqual(observed, expected)
    }

    // MARK: - Test 4: Error phase formats correctly

    func testErrorPhaseFormatsCorrectly() {
        let result = SyncStatusViewModel.label(for: .error(message: "boom"))
        XCTAssertEqual(result, "Error: boom")
    }
}
