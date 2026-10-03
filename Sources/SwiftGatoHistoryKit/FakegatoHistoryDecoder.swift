import Foundation
import TLVCoding

/// Returns the element at `index`, or `nil` if out of bounds. A local
/// reimplementation of Trug's `Array+Safe.swift` helper, so this package
/// doesn't depend on the app it was extracted from.
private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Decodes/encodes the reverse-engineered Eve/fakegato-history wire format
/// exposed under the custom `E863F007` History service (`E863F11C` History
/// Request, `E863F116` History Status, `E863F117` History Entries). Pure
/// Foundation logic, no `HomeKit` import, so it's testable without a live
/// Home — see `FakegatoHistoryDecoderTests`.
///
/// Ported from `simont77/fakegato-history`'s JavaScript source, which is
/// the ground truth here since the project's own wiki marks several
/// fields "tentative" or "not fully understood." Status/reference-time
/// parsing and the temperature+humidity (`0x03`) entry type are validated
/// against a real accessory's captured bytes: a fakegato `custom`-type
/// bridge with Status signature `02 0102 0202` (temperature, humidity),
/// whose entry type byte `0x03` is just the bitmask "fields 1 and 2
/// present." The Weather (`0x07`, 16-byte), Room (`0x0F`, 19-byte), and
/// Room 2 (`0x7F`, 21-byte) layouts were checked against `getCurrentS2R2`'s
/// `Format(...)` strings in the JS source — all three start with
/// `temp:Int16LE ×100` then `humidity:UInt16LE ×100`, so they share one
/// decode path.
///
/// Only temperature/humidity/PPM shapes are decoded; Door, Motion, Energy,
/// Aqua, and Thermo aren't. That's deliberate: type bytes aren't unique
/// across accessory types (Eve Energy's signature also starts
/// `0102 0202`, but its entries carry zeroes there), so a generic
/// signature-bitmask decoder would fabricate 0 °C / 0 % readings for it.
/// An explicit allowlist is safer. Known limitation: a partial entry on a
/// temperature/humidity accessory (bitmask `0x01` or `0x02` alone) is
/// skipped, since those bits collide with Door/Motion status entries and
/// can't be disambiguated without knowing the accessory type.
@TLVCodable
struct HistoryRequestPayload: Equatable {
    var address: UInt32

    // The macro's synthesized `init?(tlvData:)` suppresses the implicit
    // memberwise init, so we need this one to build a value before encoding.
    init(address: UInt32) {
        self.address = address
    }

    enum CodingKeys: UInt8, TLVCodingKey {
        case address = 0x02
    }
}

public enum FakegatoHistoryDecoder {

    // MARK: - History Request (E863F11C)

    /// Decoded fields from the History Status characteristic — a
    /// fixed-offset binary blob (not TLV8). Its only variable-length part
    /// is a per-accessory-type "signature" sitting between a fixed 12-byte
    /// prefix (4-byte "current time" delta, 4 reserved bytes, 4-byte
    /// reference time) and a fixed 14-byte suffix (2-byte used-entry
    /// count, 2-byte memory size, 4-byte first-entry address, 6 reserved
    /// bytes). The signature length is a 1-byte count right after the
    /// prefix, then `1 + 2*count` bytes of signature, so the suffix has to
    /// be parsed forward from that count byte, not measured back from the
    /// end of the blob — the latter only works by coincidence for some
    /// devices and silently misparses `firstEntryAddress`/`memorySize` for
    /// others.
    ///
    /// Field semantics follow fakegato-history's `_addEntry`, which
    /// encodes the two memory fields differently before and after the
    /// ring buffer first wraps:
    ///
    /// | State            | "used" field on the wire | "first entry" field on the wire |
    /// |------------------|--------------------------|---------------------------------|
    /// | not yet wrapped  | `usedMemory + 1`         | `0`                             |
    /// | wrapped          | `usedMemory`             | oldest retained address         |
    ///
    /// `parseStatus(_:)` stores the raw first-entry field and `used − 1`,
    /// so the invariant holding in both states is
    /// `firstEntryAddress + usedEntryCount == newest retained address`,
    /// which `HistoryCursor.retainedRangeUpperBound(status:)` relies on.
    /// Don't reinterpret either field alone without re-deriving that sum.
    public struct HistoryStatus: Equatable, Sendable {
        /// The accessory's current reference time, re-anchored on every
        /// status read — matches the reference-time (`0x81`) entries also
        /// found in the `E863F117` stream.
        public let referenceDate: Date
        /// The wire "used" field minus one. Before the ring wraps, this is
        /// the exact retained-record count (including the `0x81`
        /// reference-time marker at address 1); after wrapping it's
        /// `memorySize − 1`. Either way, `firstEntryAddress +
        /// usedEntryCount` is the newest retained address — see the
        /// type's doc comment.
        public let usedEntryCount: Int
        /// Total entry capacity before the accessory starts overwriting
        /// its oldest entries (fakegato's default is 4032).
        public let memorySize: Int
        /// The wire "first entry" field verbatim: `0` until the ring buffer
        /// first wraps (entries then live at addresses `1...usedEntryCount`),
        /// and the oldest retained address afterwards. Requesting `0` via
        /// `E863F11C` means "restart from the beginning," so it's always a
        /// valid address to (re)start a full fetch from.
        public let firstEntryAddress: UInt32

        public init(referenceDate: Date, usedEntryCount: Int, memorySize: Int, firstEntryAddress: UInt32) {
            self.referenceDate = referenceDate
            self.usedEntryCount = usedEntryCount
            self.memorySize = memorySize
            self.firstEntryAddress = firstEntryAddress
        }
    }

    private static let statusPrefixLength = 12
    private static let statusSuffixLength = 14

    /// TLV8 payload for the History Request characteristic, asking the
    /// accessory to (re)send history starting at `startAddress`. Pass a
    /// per-accessory resume cursor here so repeat syncs only pull new
    /// entries.
    public static func encodeRequest(startAddress: UInt32 = 1) -> Data {
        HistoryRequestPayload(address: startAddress).tlvData
    }

    public static func parseStatus(_ data: Data) -> HistoryStatus? {
        let bytes = [UInt8](data)
        // Signature-length byte sits right after the fixed prefix; the
        // signature itself is `1 + 2*count` bytes, so the suffix starts
        // right after that — never at a fixed offset from the blob's end.
        guard let signatureCount = bytes[safe: statusPrefixLength] else { return nil }
        let signatureLength = 1 + 2 * Int(signatureCount)
        let suffixStart = statusPrefixLength + signatureLength

        guard bytes.count >= suffixStart + statusSuffixLength,
              let refTime = readUInt32LE(bytes, at: 8),
              let usedEntryCountPlusOne = readUInt16LE(bytes, at: suffixStart),
              let memorySize = readUInt16LE(bytes, at: suffixStart + 2),
              let firstEntryAddress = readUInt32LE(bytes, at: suffixStart + 4) else { return nil }

        return HistoryStatus(
            referenceDate: Date(timeIntervalSinceReferenceDate: TimeInterval(refTime)),
            usedEntryCount: max(0, Int(usedEntryCountPlusOne) - 1),
            memorySize: Int(memorySize),
            firstEntryAddress: firstEntryAddress
        )
    }

    // MARK: - History Entries (E863F117)

    /// Reference-time marker — carries no reading. Its payload's first 4
    /// bytes redefine `referenceDate` for every entry that follows.
    private static let referenceTimeEntryType: UInt8 = 0x81
    /// Temperature + humidity only, no third field — confirmed against a
    /// real accessory's captured bytes (14-byte entries, 4-byte payload,
    /// both fields ×100). Matches Eve Degree-style sensors with no
    /// pressure/air-quality sensor; distinct from `weatherEntryType`
    /// (pressure) and `roomEntryType` (PPM) below.
    private static let temperatureHumidityEntryType: UInt8 = 0x03
    /// Eve Weather: temperature + humidity + pressure (pressure unused,
    /// not part of `HistoryEntry`). 16-byte entries.
    private static let weatherEntryType: UInt8 = 0x07
    /// Eve Room (1st gen): temperature + humidity + air-quality PPM, then
    /// 3 reserved bytes. 19-byte entries.
    private static let roomEntryType: UInt8 = 0x0F
    /// Eve Room (2nd gen) / fakegato `room2`: temperature + humidity + VOC
    /// density, then reserved bytes. 21-byte entries. VOC isn't CO₂ PPM,
    /// so it's ignored rather than mapped to `co2PPM` — only the shared
    /// temperature/humidity prefix is decoded.
    private static let room2EntryType: UInt8 = 0x7F

    /// Result of `parseEntries(_:referenceDate:)` — a named type rather
    /// than a tuple since SwiftLint's `large_tuple` rule caps tuples at 2
    /// members.
    public struct EntriesBatch: Equatable, Sendable {
        public let entries: [HistoryEntry]
        public let referenceDate: Date
        /// The highest `counter` seen across every record in this batch,
        /// including reference-time entries and unsupported types that
        /// don't produce a `HistoryEntry` — each still occupies an address
        /// slot. `nil` if the batch was empty.
        public let lastAddress: UInt32?
        /// Total well-formed records seen, regardless of whether `type`
        /// decoded into a `HistoryEntry`. `entries.isEmpty` alone can't
        /// distinguish a batch of unsupported-but-real records (progress
        /// — `lastAddress` advanced) from one with nothing parseable at
        /// all (`recordCount == 0`). `FakegatoHistoryDrainer.drainEntries`
        /// uses this to decide whether to keep reading past an
        /// all-unsupported batch instead of stopping early.
        public let recordCount: Int

        public init(entries: [HistoryEntry], referenceDate: Date, lastAddress: UInt32?, recordCount: Int) {
            self.entries = entries
            self.referenceDate = referenceDate
            self.lastAddress = lastAddress
            self.recordCount = recordCount
        }
    }

    /// Decodes the repeating History Entries record stream. Each record is
    /// `[length:1][counter:UInt32LE][secondsSinceReference:UInt32LE][type:1][payload...]`,
    /// `length` bytes total. `referenceDate` is the accessory's reference
    /// time from the most recent `parseStatus(_:)` call, or an earlier
    /// reference-time entry in this same stream; entries are timestamped
    /// `referenceDate + secondsSinceReference` — no manual epoch math
    /// needed since Eve's reference epoch (2001-01-01 UTC) matches
    /// Foundation's `timeIntervalSinceReferenceDate`. A malformed or
    /// truncated trailing record stops decoding and returns whatever was
    /// read so far. Also returns the reference date as of the end of this
    /// batch, so a caller reading `E863F117` across multiple characteristic
    /// reads can carry it forward.
    public static func parseEntries(_ data: Data, referenceDate initialReferenceDate: Date) -> EntriesBatch {
        let bytes = [UInt8](data)
        var offset = 0
        var referenceDate = initialReferenceDate
        var entries: [HistoryEntry] = []
        var lastAddress: UInt32?
        var recordCount = 0

        while offset < bytes.count {
            guard let length = bytes[safe: offset] else { break }
            let entryLength = Int(length)
            // 10-byte header: length(1) + counter(4) + secondsSinceReference(4) + type(1).
            guard entryLength >= 10, offset + entryLength <= bytes.count,
                  let counter = readUInt32LE(bytes, at: offset + 1),
                  let secondsSinceReference = readUInt32LE(bytes, at: offset + 5),
                  let type = bytes[safe: offset + 9] else { break }

            recordCount += 1
            lastAddress = counter
            let payloadStart = offset + 10
            let entryEnd = offset + entryLength
            let timestamp = referenceDate.addingTimeInterval(TimeInterval(secondsSinceReference))

            switch type {
            case referenceTimeEntryType:
                if let newReferenceDate = referenceTimeEntry(bytes, at: payloadStart) {
                    referenceDate = newReferenceDate
                }
            case temperatureHumidityEntryType, weatherEntryType, room2EntryType:
                if let entry = temperatureHumidityEntry(bytes, at: payloadStart, entryEnd: entryEnd, timestamp: timestamp) {
                    entries.append(entry)
                }
            case roomEntryType:
                if let entry = roomEntry(bytes, at: payloadStart, entryEnd: entryEnd, timestamp: timestamp) {
                    entries.append(entry)
                }
            default:
                break // unsupported type (Door/Motion/Energy/Aqua/etc.)
            }
            offset += entryLength
        }
        return EntriesBatch(entries: entries, referenceDate: referenceDate, lastAddress: lastAddress, recordCount: recordCount)
    }

    /// Decodes a reference-time (`0x81`) entry's payload into the new
    /// `referenceDate` it re-anchors subsequent entries to.
    private static func referenceTimeEntry(_ bytes: [UInt8], at payloadStart: Int) -> Date? {
        guard let refSeconds = readUInt32LE(bytes, at: payloadStart) else { return nil }
        return Date(timeIntervalSinceReferenceDate: TimeInterval(refSeconds))
    }

    /// Decodes the leading temperature+humidity fields shared by
    /// `temperatureHumidityEntryType`, `weatherEntryType` (trailing
    /// pressure ignored), and `room2EntryType` (trailing VOC ignored) —
    /// all three share an identical payload prefix. `entryEnd` is the
    /// record's declared end; a record too short for the full payload is
    /// skipped rather than read into the next record's bytes.
    private static func temperatureHumidityEntry(_ bytes: [UInt8], at payloadStart: Int, entryEnd: Int, timestamp: Date) -> HistoryEntry? {
        guard payloadStart + 4 <= entryEnd,
              let temperature = readInt16LE(bytes, at: payloadStart),
              let humidity = readUInt16LE(bytes, at: payloadStart + 2) else { return nil }
        return HistoryEntry(
            timestamp: timestamp,
            temperatureCelsius: Double(temperature) / 100,
            humidityPercent: Double(humidity) / 100,
            co2PPM: nil
        )
    }

    /// Decodes an Eve Room entry (temperature + humidity + air-quality
    /// PPM) — 6 payload bytes. `entryEnd` is the record's declared end; a
    /// record too short for the full payload is skipped rather than read
    /// into the next record's bytes.
    private static func roomEntry(_ bytes: [UInt8], at payloadStart: Int, entryEnd: Int, timestamp: Date) -> HistoryEntry? {
        guard payloadStart + 6 <= entryEnd,
              let temperature = readInt16LE(bytes, at: payloadStart),
              let humidity = readUInt16LE(bytes, at: payloadStart + 2),
              let ppm = readUInt16LE(bytes, at: payloadStart + 4) else { return nil }
        return HistoryEntry(
            timestamp: timestamp,
            temperatureCelsius: Double(temperature) / 100,
            humidityPercent: Double(humidity) / 100,
            co2PPM: Double(ppm)
        )
    }

    // MARK: - Little-endian byte reads

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readInt16LE(_ bytes: [UInt8], at offset: Int) -> Int16? {
        readUInt16LE(bytes, at: offset).map { Int16(bitPattern: $0) }
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
