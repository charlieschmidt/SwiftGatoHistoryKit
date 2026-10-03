import Testing
import Foundation
@testable import SwiftGatoHistoryKit

/// Scripted stand-in for reading a characteristic's current value, so
/// `FakegatoHistoryDrainer.drainEntries` can be driven by a canned sequence
/// of reads without a live HomeKit home.
private actor ScriptedEntriesReader {
    /// One scripted outcome for a single `readNext()` call.
    enum Step {
        case data(Data?)
        case failure(Error)
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(_ dataSteps: [Data?]) {
        self.steps = dataSteps.map { .data($0) }
    }

    init(steps: [Step]) {
        self.steps = steps
    }

    func next() async throws -> Data? {
        callCount += 1
        guard !steps.isEmpty else { return nil }
        switch steps.removeFirst() {
        case .data(let data):
            return data
        case .failure(let error):
            throw error
        }
    }
}

/// Thrown by `ScriptedEntriesReader` to simulate a failed characteristic
/// read partway through a drain.
private struct ScriptedReadFailure: Error {}

struct FakegatoHistoryDrainerTests {

    @Test func drainEntriesStopsWhenTheAccessorysReportedCountIsReached() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 2, memorySize: 100, firstEntryAddress: 0)
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let first = Data(FakegatoTestBytes.entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload))
        let second = Data(FakegatoTestBytes.entryBytes(counter: 2, secondsSinceReference: 60, type: 0x0F, payload: payload))
        let reader = ScriptedEntriesReader([first, second])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 2)
        #expect(result.lastAddress == 2)
        #expect(result.stopReason == .countReached)
        #expect(await reader.callCount == 2)
    }

    @Test func drainEntriesWithZeroMaxIterationsNeverCallsReadNext() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: .now, usedEntryCount: 5, memorySize: 100, firstEntryAddress: 0)
        let reader = ScriptedEntriesReader([Data([1, 2, 3])])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            maxIterations: 0,
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.isEmpty)
        #expect(result.lastAddress == nil)
        #expect(result.stopReason == .iterationCap)
        #expect(await reader.callCount == 0)
    }

    @Test func drainEntriesStopsOnANilRead() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: .now, usedEntryCount: 5, memorySize: 100, firstEntryAddress: 0)
        let reader = ScriptedEntriesReader([nil])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.isEmpty)
        #expect(result.stopReason == .emptyRead)
    }

    @Test func drainEntriesStopsOnAnEmptyDataRead() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: .now, usedEntryCount: 5, memorySize: 100, firstEntryAddress: 0)
        let reader = ScriptedEntriesReader([Data()])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.isEmpty)
        #expect(result.stopReason == .emptyRead)
    }

    @Test func drainEntriesStopsWhenConsecutiveReadsReturnIdenticalBytes() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 10, memorySize: 100, firstEntryAddress: 0)
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let bytes = Data(FakegatoTestBytes.entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload))
        let reader = ScriptedEntriesReader([bytes, bytes])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 1)
        #expect(result.stopReason == .identicalBytes)
        #expect(await reader.callCount == 2)
    }

    @Test func drainEntriesKeepsPartialEntriesWhenAReadFails() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 10, memorySize: 100, firstEntryAddress: 0)
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let bytes = Data(FakegatoTestBytes.entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload))
        let reader = ScriptedEntriesReader(steps: [.data(bytes), .failure(ScriptedReadFailure())])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 1)
        #expect(result.stopReason == .readFailed)
    }

    @Test func drainEntriesContinuesPastAnAllUnsupportedTypeBatchInsteadOfStopping() async {
        // A batch of entirely unsupported-type records still advances the
        // ring buffer, so the drain must keep reading instead of mistaking
        // "zero decoded entries" for end-of-stream.
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 1, memorySize: 100, firstEntryAddress: 0)
        let doorEntryBytes = Data(FakegatoTestBytes.entryBytes(counter: 7, secondsSinceReference: 0, type: 0x01, payload: [1]))
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let roomEntryBytes = Data(FakegatoTestBytes.entryBytes(counter: 8, secondsSinceReference: 60, type: 0x0F, payload: payload))
        let reader = ScriptedEntriesReader([doorEntryBytes, roomEntryBytes])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 1)
        #expect(result.lastAddress == 8)
        #expect(result.stopReason == .countReached)
        #expect(await reader.callCount == 2)
    }

    @Test func drainEntriesStopsWithNoDecodableEntriesOnlyWhenABatchHasNoRecordsAtAll() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 10, memorySize: 100, firstEntryAddress: 0)
        // Record length of 3 is too short for the 10-byte header, so
        // `parseEntries` bails with `recordCount == 0` (end-of-stream).
        let unparseableBytes = Data([0x03, 0x01, 0x00])
        let reader = ScriptedEntriesReader([unparseableBytes])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.isEmpty)
        #expect(result.lastAddress == nil)
        #expect(result.stopReason == .noDecodableEntries)
    }

    @Test func drainEntriesRespectsTheIterationCap() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 100, memorySize: 100, firstEntryAddress: 0)
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let steps = (1...3).map { counter in
            Data(FakegatoTestBytes.entryBytes(counter: UInt32(counter), secondsSinceReference: UInt32(counter) * 60, type: 0x0F, payload: payload))
        }
        let reader = ScriptedEntriesReader(steps)

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            maxIterations: 3,
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 3)
        #expect(result.stopReason == .iterationCap)
        #expect(await reader.callCount == 3)
    }

    @Test func drainEntriesHandlesAReferenceTimeReanchorEntry() async {
        let newReferenceSeconds: UInt32 = 5000
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 1, memorySize: 100, firstEntryAddress: 0)
        let referenceEntry = FakegatoTestBytes.entryBytes(counter: 1, secondsSinceReference: 1, type: 0x81, payload: FakegatoTestBytes.referenceTimePayload(newReferenceSeconds: newReferenceSeconds))
        let roomPayload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let roomEntry = FakegatoTestBytes.entryBytes(counter: 2, secondsSinceReference: 60, type: 0x0F, payload: roomPayload)
        let reader = ScriptedEntriesReader([Data(referenceEntry + roomEntry)])

        let result = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: nil
        )

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.timestamp == Date(timeIntervalSinceReferenceDate: TimeInterval(newReferenceSeconds) + 60))
        #expect(result.lastAddress == 2)
        #expect(result.stopReason == .countReached)
    }

    @Test func drainEntriesReportsProgressPerBatch() async {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: Date(timeIntervalSinceReferenceDate: 0), usedEntryCount: 2, memorySize: 100, firstEntryAddress: 0)
        let payload = FakegatoTestBytes.roomPayload(temperatureCelsiusTimes100: 2000, humidityPercentTimes100: 5000, ppm: 500)
        let first = Data(FakegatoTestBytes.entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload))
        let second = Data(FakegatoTestBytes.entryBytes(counter: 2, secondsSinceReference: 60, type: 0x0F, payload: payload))
        let reader = ScriptedEntriesReader([first, second])
        var progressUpdates: [(current: Int, total: Int)] = []

        _ = await FakegatoHistoryDrainer.drainEntries(
            status: status,
            accessoryName: "Tent",
            readNext: { try await reader.next() },
            onProgress: { current, total in
                progressUpdates.append((current, total))
            }
        )

        #expect(progressUpdates.map(\.current) == [1, 2])
        #expect(progressUpdates.map(\.total) == [2, 2])
    }

    @Test func drainEntriesStopsImmediatelyWhenTheEnclosingTaskIsCancelled() async throws {
        let status = FakegatoHistoryDecoder.HistoryStatus(referenceDate: .now, usedEntryCount: 5, memorySize: 100, firstEntryAddress: 0)
        let reader = ScriptedEntriesReader([Data([1, 2, 3])])

        let task = Task {
            await FakegatoHistoryDrainer.drainEntries(
                status: status,
                accessoryName: "Tent",
                readNext: { try await reader.next() },
                onProgress: nil
            )
        }
        task.cancel()

        let result = await task.value

        #expect(result.entries.isEmpty)
        #expect(result.stopReason == .cancelled)
        #expect(await reader.callCount == 0)
    }
}
