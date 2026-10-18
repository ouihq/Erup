import XCTest
@testable import Erup

final class DiagnosticLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEntriesAreKeptInOrderWithTheirCategory() {
        let log = DiagnosticLog(directory: directory)
        log.log(.connection, "link lost")
        log.log(.stream, "restarting")
        XCTAssertEqual(log.snapshot.map(\.message), ["link lost", "restarting"])
        XCTAssertEqual(log.snapshot.map(\.category), [.connection, .stream])
    }

    func testOnlyTheNewestEntriesAreKept() {
        let log = DiagnosticLog(directory: directory, capacity: 3)
        for index in 0..<10 { log.log(.app, "event \(index)") }
        XCTAssertEqual(log.snapshot.map(\.message), ["event 7", "event 8", "event 9"])
    }

    func testTheLogSurvivesTheAppBeingKilled() {
        let first = DiagnosticLog(directory: directory)
        first.log(.connection, "scooter disconnected in the background")
        first.log(.stream, "stream stalled")
        first.flush()

        // A new process starts: the earlier events are still there.
        let second = DiagnosticLog(directory: directory)
        XCTAssertEqual(second.snapshot.map(\.message), ["scooter disconnected in the background", "stream stalled"])
    }

    func testEntriesRememberWhetherTheAppWasInTheBackground() {
        let log = DiagnosticLog(directory: directory)
        log.log(.stream, "on screen")
        log.isForeground = false
        log.log(.stream, "frames stopped")
        let flags = log.snapshot.map { "\($0.foreground ? "fg" : "bg"):\($0.message)" }
        XCTAssertEqual(flags, ["fg:on screen", "bg:app left the foreground", "bg:frames stopped"])
    }

    func testReportHasTheFactsThenEveryEventOldestFirst() {
        let log = DiagnosticLog(directory: directory)
        log.log(.connection, "first")
        log.log(.error, "second")
        let report = log.report(header: [("App", "1.2.4"), ("Low Power Mode", "off")], frames: ["tx frame aa bb"])

        XCTAssertTrue(report.contains("App: 1.2.4"))
        XCTAssertTrue(report.contains("Low Power Mode: off"))
        XCTAssertTrue(report.contains("fg connection: first"))
        XCTAssertTrue(report.contains("fg error: second"))
        XCTAssertTrue(report.contains("tx frame aa bb"))
        let first = report.range(of: "connection: first")!.lowerBound
        let second = report.range(of: "error: second")!.lowerBound
        XCTAssertLessThan(first, second)
    }

    func testClearingRemovesEverythingIncludingTheFile() {
        let log = DiagnosticLog(directory: directory)
        log.log(.app, "old")
        log.flush()
        log.clear()
        log.flush()
        XCTAssertEqual(log.snapshot.map(\.message), ["log cleared"])
        XCTAssertEqual(DiagnosticLog(directory: directory).snapshot.map(\.message), ["log cleared"])
    }

    func testAnUnreadableLineDoesNotLoseTheRest() throws {
        let log = DiagnosticLog(directory: directory)
        log.log(.app, "kept")
        log.flush()
        let file = directory.appendingPathComponent("diagnostics.jsonl")
        var data = try Data(contentsOf: file)
        data.append(Data("not json at all\n".utf8))
        try data.write(to: file)
        XCTAssertEqual(DiagnosticLog(directory: directory).snapshot.map(\.message), ["kept"])
    }
}
