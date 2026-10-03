import Testing
import Foundation
@testable import SwiftGatoHistoryKit

/// Covers `FakegatoHistoryDecoder` against hand-built fixture bytes derived
/// from `simont77/fakegato-history`'s JS source. An internal-consistency
/// check that decoding matches that reference implementation, not a
/// substitute for validating against a real accessory's bytes.
struct FakegatoHistoryDecoderTests {

    // MARK: - encodeRequest

    @Test func encodeRequestProducesATLV8Type02Payload() {
        // TLV8: type 0x02, length 0x04 (a UInt32), value = address, little-endian.
        let data = FakegatoHistoryDecoder.encodeRequest(startAddress: 1)
        #expect([UInt8](data) == [0x02, 0x04, 0x01, 0x00, 0x00, 0x00])
    }

    @Test func encodeRequestEncodesTheAddressLittleEndian() {
        let data = FakegatoHistoryDecoder.encodeRequest(startAddress: 0x0403_0201)
        #expect([UInt8](data) == [0x02, 0x04, 0x01, 0x02, 0x03, 0x04])
    }

    // MARK: - parseStatus

    @Test func parseStatusDecodesReferenceTimeAndMemoryFields() {
        // Prefix (12 bytes): currentTimeDelta(4)=0, reserved(4)=0, refTime(4)=3600.
        var bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + littleEndian(UInt32(3600))
        // Signature: count=3, so 7 bytes total (`1 + 2*3`) — decoder must
        // parse forward, not measure back from the blob's end. Only the
        // count matters; the rest of the bytes are arbitrary.
        bytes += [0x03, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        // Suffix (14 bytes): usedMemory+1=101 (LE16), memorySize=4096 (LE16), firstEntry=1 (LE32), reserved(6)=0.
        bytes += littleEndian(UInt16(101)) + littleEndian(UInt16(4096)) + littleEndian(UInt32(1)) + [0, 0, 0, 0, 0, 0]

        let status = FakegatoHistoryDecoder.parseStatus(Data(bytes))

        #expect(status?.referenceDate == Date(timeIntervalSinceReferenceDate: 3600))
        #expect(status?.usedEntryCount == 100)
        #expect(status?.memorySize == 4096)
        #expect(status?.firstEntryAddress == 1)
    }

    /// What fakegato-history's `_addEntry` emits for a fresh, not-yet-wrapped
    /// Eve Weather emulation: the real 3-word Weather signature, a "used"
    /// field of `usedMemory + 1`, and a "first entry" field of `0` (not
    /// `1` — fakegato only reports the oldest address once wrapped). The
    /// decoded pair must still satisfy `firstEntryAddress + usedEntryCount
    /// == newest address`.
    @Test func parseStatusDecodesAFreshUnwrappedFakegatoWeatherStatus() {
        // Prefix (12 bytes): currentTimeDelta(4)=0, reserved(4)=0, refTime(4)=7200.
        var bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + littleEndian(UInt32(7200))
        // Signature: fakegato TYPE_WEATHER accessoryType116 = "03 0102 0202 0302".
        bytes += [0x03, 0x01, 0x02, 0x02, 0x02, 0x03, 0x02]
        // Suffix (14 bytes): usedMemory+1=51 (LE16), memorySize=4032 (LE16), firstEntry=0 (LE32), then `00000000 0101`.
        bytes += littleEndian(UInt16(51)) + littleEndian(UInt16(4032)) + littleEndian(UInt32(0)) + [0, 0, 0, 0, 0x01, 0x01]

        let status = FakegatoHistoryDecoder.parseStatus(Data(bytes))

        #expect(status?.referenceDate == Date(timeIntervalSinceReferenceDate: 7200))
        #expect(status?.usedEntryCount == 50)
        #expect(status?.memorySize == 4032)
        #expect(status?.firstEntryAddress == 0)
        // 50 records live at addresses 1...50, so the newest is 50.
        #expect((status?.firstEntryAddress).map { Int($0) + (status?.usedEntryCount ?? -1) } == 50)
    }

    /// A signature with no words (`count == 0`). fakegato never emits
    /// this, but the forward parse must still not misplace the suffix.
    @Test func parseStatusHandlesAnEmptySignature() {
        var bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + littleEndian(UInt32(7200))
        bytes += [0x00]
        bytes += littleEndian(UInt16(51)) + littleEndian(UInt16(4096)) + littleEndian(UInt32(0)) + [0, 0, 0, 0, 0, 0]

        let status = FakegatoHistoryDecoder.parseStatus(Data(bytes))

        #expect(status?.usedEntryCount == 50)
        #expect(status?.memorySize == 4096)
        #expect(status?.firstEntryAddress == 0)
    }

    @Test func parseStatusReturnsNilForTooShortData() {
        #expect(FakegatoHistoryDecoder.parseStatus(Data([0, 1, 2])) == nil)
    }

    // MARK: - parseEntries

    private func entryBytes(counter: UInt32, secondsSinceReference: UInt32, type: UInt8, payload: [UInt8]) -> [UInt8] {
        FakegatoTestBytes.entryBytes(counter: counter, secondsSinceReference: secondsSinceReference, type: type, payload: payload)
    }

    private func littleEndian(_ value: UInt16) -> [UInt8] {
        FakegatoTestBytes.littleEndian(value)
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        FakegatoTestBytes.littleEndian(value)
    }

    @Test func parseEntriesDecodesARoomEntry() {
        // Eve Room: type 0x0F, temperature/humidity ×100, PPM raw, 3 reserved trailing bytes.
        let payload = littleEndian(UInt16(2250)) + littleEndian(UInt16(5500)) + littleEndian(UInt16(800)) + [0, 0, 0]
        let bytes = entryBytes(counter: 1, secondsSinceReference: 600, type: 0x0F, payload: payload)
        let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

        let result = FakegatoHistoryDecoder.parseEntries(Data(bytes), referenceDate: referenceDate)

        #expect(result.entries.count == 1)
        let entry = result.entries.first
        #expect(entry?.timestamp == referenceDate.addingTimeInterval(600))
        #expect(entry?.temperatureCelsius == 22.5)
        #expect(entry?.humidityPercent == 55.0)
        #expect(entry?.co2PPM == 800)
        #expect(result.referenceDate == referenceDate) // No reference-time entry in this stream.
        #expect(result.lastAddress == 1)
    }

    @Test func parseEntriesDecodesAWeatherEntryIgnoringPressure() {
        // Eve Weather: type 0x07, temperature/humidity ×100, pressure ×10 (unused by `HistoryEntry`).
        let payload = littleEndian(UInt16(1980)) + littleEndian(UInt16(4200)) + littleEndian(UInt16(10132))
        let bytes = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x07, payload: payload)
        let referenceDate = Date(timeIntervalSinceReferenceDate: 1000)

        let result = FakegatoHistoryDecoder.parseEntries(Data(bytes), referenceDate: referenceDate)

        let entry = result.entries.first
        #expect(entry?.temperatureCelsius == 19.8)
        #expect(entry?.humidityPercent == 42.0)
        #expect(entry?.co2PPM == nil)
    }

    /// Eve Room (2nd gen) / fakegato `room2`: type `0x7F`, 21 bytes total —
    /// temperature ×100, humidity ×100, VOC density (µg/m³, not CO₂, so
    /// it mustn't surface as `co2PPM`), then reserved bytes. Before this
    /// type was recognised, Room 2 batches decoded to zero entries and
    /// never synced any history.
    @Test func parseEntriesDecodesARoom2EntryIgnoringVOC() {
        let payload = littleEndian(UInt16(2115)) + littleEndian(UInt16(4870)) + littleEndian(UInt16(312)) + [0x00, 0x54, 0xa8, 0x0f, 0x01]
        let bytes = entryBytes(counter: 9, secondsSinceReference: 1200, type: 0x7F, payload: payload)
        #expect(bytes.count == 0x15) // Matches fakegato's declared length byte for room2.
        let referenceDate = Date(timeIntervalSinceReferenceDate: 500)

        let result = FakegatoHistoryDecoder.parseEntries(Data(bytes), referenceDate: referenceDate)

        #expect(result.entries.count == 1)
        let entry = result.entries.first
        #expect(entry?.timestamp == referenceDate.addingTimeInterval(1200))
        #expect(entry?.temperatureCelsius == 21.15)
        #expect(entry?.humidityPercent == 48.7)
        #expect(entry?.co2PPM == nil)
        #expect(result.lastAddress == 9)
    }

    @Test func parseEntriesDecodesNegativeTemperatures() {
        // Int16LE(-550) == -5.50°C — proves the temperature field is signed, not just scaled.
        let rawTemperature = UInt16(bitPattern: -550)
        let payload = littleEndian(rawTemperature) + littleEndian(UInt16(5000)) + littleEndian(UInt16(400)) + [0, 0, 0]
        let bytes = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload)

        let result = FakegatoHistoryDecoder.parseEntries(Data(bytes), referenceDate: .now)

        #expect(result.entries.first?.temperatureCelsius == -5.5)
    }

    @Test func parseEntriesReferenceTimeEntryReanchorsSubsequentTimestampsWithoutProducingAReading() {
        let newReferenceSeconds: UInt32 = 5000
        // Type 0x81 payload: refTime LE32 + 7 reserved bytes.
        let referenceEntry = entryBytes(counter: 1, secondsSinceReference: 1, type: 0x81, payload: littleEndian(newReferenceSeconds) + [0, 0, 0, 0, 0, 0, 0])
        let roomPayload = littleEndian(UInt16(2000)) + littleEndian(UInt16(5000)) + littleEndian(UInt16(500)) + [0, 0, 0]
        let roomEntry = entryBytes(counter: 2, secondsSinceReference: 60, type: 0x0F, payload: roomPayload)

        let result = FakegatoHistoryDecoder.parseEntries(Data(referenceEntry + roomEntry), referenceDate: Date(timeIntervalSinceReferenceDate: 0))

        #expect(result.entries.count == 1) // The reference-time entry itself isn't a reading.
        #expect(result.referenceDate == Date(timeIntervalSinceReferenceDate: TimeInterval(newReferenceSeconds)))
        #expect(result.entries.first?.timestamp == Date(timeIntervalSinceReferenceDate: TimeInterval(newReferenceSeconds) + 60))
        // Reference-time entry (counter 1) still occupies an address, so
        // the resume cursor must advance past it too.
        #expect(result.lastAddress == 2)
    }

    @Test func parseEntriesSkipsUnsupportedEntryTypes() {
        // Eve Door (type 0x01) isn't decoded.
        let doorEntry = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x01, payload: [1])
        let result = FakegatoHistoryDecoder.parseEntries(Data(doorEntry), referenceDate: .now)

        #expect(result.entries.isEmpty)
        // Still occupies address 1, so the resume cursor advances past it.
        #expect(result.lastAddress == 1)
        #expect(result.recordCount == 1)
    }

    /// A batch of entirely unsupported entry types still has well-formed
    /// records — `recordCount` must reflect that even though `entries`
    /// stays empty, distinguishing it from a batch with nothing parseable
    /// at all (see `parseEntriesReturnsEmptyForEmptyData`).
    @Test func parseEntriesReportsRecordCountForAnAllUnsupportedTypeBatch() {
        let doorEntry = entryBytes(counter: 5, secondsSinceReference: 0, type: 0x01, payload: [1])
        let motionEntry = entryBytes(counter: 6, secondsSinceReference: 60, type: 0x02, payload: [0])
        let result = FakegatoHistoryDecoder.parseEntries(Data(doorEntry + motionEntry), referenceDate: .now)

        #expect(result.entries.isEmpty)
        #expect(result.recordCount == 2)
        #expect(result.lastAddress == 6)
    }

    /// An Eve Room record with fewer than 6 payload bytes must be
    /// skipped, not misread past its own bounds.
    @Test func parseEntriesSkipsATruncatedRoomPayloadRatherThanMisreadingIt() {
        let shortPayload: [UInt8] = [0x01, 0x02, 0x03] // Only 3 of the required 6 payload bytes.
        let truncatedRoomEntry = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: shortPayload)

        let result = FakegatoHistoryDecoder.parseEntries(Data(truncatedRoomEntry), referenceDate: .now)

        #expect(result.entries.isEmpty)
        #expect(result.recordCount == 1)
        #expect(result.lastAddress == 1)
    }

    @Test func parseEntriesSkipsATruncatedTemperatureHumidityPayloadRatherThanMisreadingIt() {
        let shortPayload: [UInt8] = [0x01, 0x02, 0x03] // Only 3 of the required 4 payload bytes.
        let truncatedTemperatureHumidityEntry = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x03, payload: shortPayload)

        let result = FakegatoHistoryDecoder.parseEntries(Data(truncatedTemperatureHumidityEntry), referenceDate: .now)

        #expect(result.entries.isEmpty)
        #expect(result.recordCount == 1)
        #expect(result.lastAddress == 1)
    }

    @Test func parseEntriesStopsAtATruncatedTrailingRecordRatherThanThrowing() {
        let payload = littleEndian(UInt16(2250)) + littleEndian(UInt16(5500)) + littleEndian(UInt16(800)) + [0, 0, 0]
        let completeEntry = entryBytes(counter: 1, secondsSinceReference: 0, type: 0x0F, payload: payload)
        let truncatedTrailingBytes: [UInt8] = [0x13, 0x01, 0x00] // Declares length 0x13 but only has 3 bytes.

        let result = FakegatoHistoryDecoder.parseEntries(Data(completeEntry + truncatedTrailingBytes), referenceDate: .now)

        #expect(result.entries.count == 1)
        #expect(result.lastAddress == 1) // Only the complete record's address counts.
    }

    @Test func parseEntriesReturnsEmptyForEmptyData() {
        let result = FakegatoHistoryDecoder.parseEntries(Data(), referenceDate: .now)
        #expect(result.entries.isEmpty)
        #expect(result.lastAddress == nil)
        #expect(result.recordCount == 0)
    }

    // MARK: - Real captured device data

    /// Bytes captured from a real accessory ("Left Flower Tent") via
    /// `FakegatoHistoryDecoder`'s debug logging. This caught entry type
    /// `0x03` (temperature+humidity-only, no PPM) not being decoded:
    /// every entry in this batch used that type, so before it was added,
    /// `parseEntries` silently returned zero entries for the whole batch.
    @Test func parseStatusAndEntriesDecodeARealCapturedDeviceResponse() throws {
        // Ring buffer has wrapped: `firstEntryAddress` (7498) is past
        // `memorySize` (4032). Parsed forward from byte 12, the signature
        // is `02 | 0102 | 0202` (5 bytes), landing the suffix at byte 17 —
        // giving used+1=0x0fc0, memSize=4032, firstEntry=7498. Measuring
        // back from the blob's end instead misreads memorySize as 7498
        // and firstEntryAddress as 0.
        let statusBytes = hexBytes("87 95 69 00 00 00 00 00 fd 91 f4 2f 02 01 02 02 02 c0 0f c0 0f 4a 1d 00 00 00 00 00 00 01 01")
        let status = try #require(FakegatoHistoryDecoder.parseStatus(Data(statusBytes)))
        #expect(status.usedEntryCount == 4031)
        #expect(status.memorySize == 4032)
        #expect(status.firstEntryAddress == 7498)

        let entriesBytes = hexBytes("""
            0e 01 00 00 00 49 e1 49 00 03 3d 09 c7 15 \
            0e 02 00 00 00 a1 e3 49 00 03 3d 09 d6 15 \
            0e 03 00 00 00 f9 e5 49 00 03 3d 09 e0 15 \
            0e 04 00 00 00 51 e8 49 00 03 42 09 e0 15 \
            0e 05 00 00 00 a9 ea 49 00 03 42 09 e0 15 \
            0e 06 00 00 00 01 ed 49 00 03 47 09 e0 15 \
            0e 07 00 00 00 59 ef 49 00 03 47 09 e0 15 \
            0e 08 00 00 00 b1 f1 49 00 03 42 09 ea 15 \
            0e 09 00 00 00 09 f4 49 00 03 42 09 d9 15 \
            0e 0a 00 00 00 61 f6 49 00 03 42 09 d9 15 \
            0e 0b 00 00 00 b9 f8 49 00 03 3d 09 d9 15
            """)

        let result = FakegatoHistoryDecoder.parseEntries(Data(entriesBytes), referenceDate: status.referenceDate)

        #expect(result.entries.count == 11) // Was 0 before entry type 0x03 was supported.
        let first = try #require(result.entries.first)
        #expect(first.temperatureCelsius == 23.65)
        #expect(first.humidityPercent == 55.75)
        #expect(first.co2PPM == nil)
        #expect(result.entries.allSatisfy { $0.temperatureCelsius != nil && $0.humidityPercent != nil })
        // 10-minute cadence between consecutive entries, matching Eve's
        // typical logging interval.
        #expect(result.entries[1].timestamp.timeIntervalSince(result.entries[0].timestamp) == 600)
        #expect(result.lastAddress == 0x0b)
    }

    private func hexBytes(_ hex: String) -> [UInt8] {
        FakegatoTestBytes.hexBytes(hex)
    }
}
