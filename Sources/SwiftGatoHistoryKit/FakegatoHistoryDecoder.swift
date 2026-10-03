import Foundation
import TLVCoding

/// Returns the element at `index`, or `nil` if `index` is out of bounds.
/// A private reimplementation of Trug's own `Array+Safe.swift` helper so
/// this package has no dependency on the app it was extracted from.
private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Decodes/encodes the reverse-engineered Eve/fakegato-history wire format
/// exposed by HomeKit accessories under the custom `E863F007` History
/// service (`E863F1xx-079E-48FF-8F27-9C2605A29F52` UUID family: `E863F11C`
/// History Request, `E863F116` History Status, `E863F117` History
/// Entries). Pure Foundation logic with no `HomeKit` import, so it's
/// testable without a live Home — see `FakegatoHistoryDecoderTests`.
///
/// Ported from `simont77/fakegato-history`'s actual JavaScript source (the
/// reference implementation that emulates an Eve accessory for
/// Homebridge) — the ground truth for what bytes a HomeKit *client* like
/// Trug needs to parse, since the project's own wiki documents several
/// fields as "tentative" or "not fully understood." Status/reference-time
/// parsing and the temperature+humidity (`0x03`) entry type have been
/// validated against a real accessory's captured bytes — that accessory is
/// a fakegato `custom`-type bridge whose Status signature is
/// `02 0102 0202` (two 2-byte fields: temperature, humidity), so its entry
/// type byte `0x03` is the bitmask "fields 1 and 2 present". The Weather
/// (`0x07`, 16-byte), Room (`0x0F`, 19-byte), and Room 2 (`0x7F`, 21-byte)
/// layouts were checked line-by-line against `getCurrentS2R2`'s
/// `Format(...)` strings in the JS source: all three carry
/// `temp:Int16LE ×100` then `humidity:UInt16LE ×100` as the first four
/// payload bytes, so they share one decode path. Only
/// temperature/humidity/PPM entry shapes are decoded at all; other Eve
/// accessory types (Door, Motion, Energy, Aqua, Thermo) aren't decoded —
/// deliberately so: field type bytes aren't globally unique across
/// accessory types (Eve Energy's signature *also* starts `0102 0202` yet
/// its entries carry zeroes there), so a generic signature-bitmask decoder
/// would fabricate 0 °C / 0 % readings for it. The explicit type allowlist
/// below is the safer design. Known limitation: a partial entry on a
/// temperature/humidity accessory (bitmask `0x01` temp-only or `0x02`
/// humidity-only) is skipped, because `0x01`/`0x02` collide with Door/Motion
/// status entries and can't be told apart without the accessory type.
@TLVCodable
struct HistoryRequestPayload: Equatable {
    var address: UInt32

    // The macro's synthesized `init?(tlvData:)` suppresses Swift's implicit
    // memberwise init, so an explicit one is needed to construct a value
    // from a plain `UInt32` before encoding.
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
    /// fixed-offset binary blob (not TLV8) whose only variable-length part
    /// is a per-accessory-type "signature" that sits between a fixed
    /// 12-byte prefix (a 4-byte "current time" delta, 4 reserved bytes, and
    /// the 4-byte reference time) and a fixed 14-byte suffix (2-byte
    /// used-entry count, 2-byte memory size, 4-byte first-entry address, 6
    /// reserved bytes). The signature's length can't be hardcoded per
    /// device: it's a 1-byte count immediately following the prefix, then
    /// `1 + 2*count` bytes of signature (per fakegato-history's own JS
    /// source), so the suffix's actual start has to be parsed forward from
    /// that count byte rather than measured back from the end of the blob —
    /// measuring from the end only happens to line up for accessories whose
    /// signature `count` byte makes the trailing arithmetic work out, and
    /// silently misparses `firstEntryAddress`/`memorySize` for others.
    ///
    /// Field semantics follow fakegato-history's `_addEntry`, which encodes
    /// the two memory fields *differently* before and after the ring buffer
    /// first wraps:
    ///
    /// | State            | "used" field on the wire | "first entry" field on the wire |
    /// |------------------|--------------------------|---------------------------------|
    /// | not yet wrapped  | `usedMemory + 1`         | `0`                             |
    /// | wrapped          | `usedMemory`             | oldest retained address         |
    ///
    /// (The wiki agrees on the first-entry field: "once memory rolling
    /// occurred it indicates the address of the oldest entry present".)
    /// `parseStatus(_:)` stores the raw first-entry field and `used − 1`,
    /// so the one invariant that holds in *both* states is
    /// `firstEntryAddress + usedEntryCount == newest retained address` —
    /// which is exactly what `HistoryCursor.retainedRangeUpperBound(status:)`
    /// relies on. Don't "fix" either field to a nicer meaning in isolation
    /// without re-deriving that sum.
    public struct HistoryStatus: Equatable, Sendable {
        /// The accessory's current reference time, re-anchored on every
        /// status read — matches the reference-time (`0x81`) entries also
        /// found in the `E863F117` stream.
        public let referenceDate: Date
        /// The wire "used" field minus one. Before the ring wraps this is
        /// the exact number of retained records (including the `0x81`
        /// reference-time marker fakegato stores at address 1); after it
        /// wraps it's `memorySize − 1` (one fewer than the true count).
        /// Either way, `firstEntryAddress + usedEntryCount` is the newest
        /// retained address — see the type's doc comment.
        public let usedEntryCount: Int
        /// Total entry capacity before the accessory starts overwriting
        /// its oldest entries (fakegato's default is 4032).
        public let memorySize: Int
        /// The wire "first entry" field verbatim: `0` until the ring buffer
        /// first wraps (entries then live at addresses `1...usedEntryCount`),
        /// and the address of the oldest retained entry afterwards.
        /// Requesting `0` via `E863F11C` means "restart from the
        /// beginning" per both the wiki and fakegato's `sendHistory`, so
        /// this is always a valid address to (re)start a full fetch from.
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
    /// accessory to (re)send its history starting at `startAddress`. A
    /// consumer passes a per-accessory resume cursor here so repeat syncs
    /// only pull entries the accessory hasn't sent before.
    public static func encodeRequest(startAddress: UInt32 = 1) -> Data {
        HistoryRequestPayload(address: startAddress).tlvData
    }

    public static func parseStatus(_ data: Data) -> HistoryStatus? {
        let bytes = [UInt8](data)
        // The signature-length byte sits right after the fixed prefix;
        // signature is `1 + 2*count` bytes (fakegato-history's JS source),
        // so the fixed suffix starts right after that — never at a fixed
        // offset from the end of the blob.
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

    /// Entry type byte for a reference-time marker — carries no reading;
    /// its payload's first 4 bytes redefine `referenceDate` for every
    /// entry that follows, mirroring how the real protocol periodically
    /// re-anchors the relative timestamps used by every other entry type.
    private static let referenceTimeEntryType: UInt8 = 0x81
    /// Temperature + humidity only, no third field — confirmed against a
    /// real accessory's captured bytes: 14-byte entries, 4-byte payload
    /// (`temp:Int16LE`/`humidity:UInt16LE`, both ×100). Matches Eve
    /// Degree-style sensors that have no pressure/air-quality sensor,
    /// distinct from both `weatherEntryType` (has pressure) and
    /// `roomEntryType` (has PPM) below.
    private static let temperatureHumidityEntryType: UInt8 = 0x03
    /// Eve Weather: temperature + humidity + pressure (pressure unused —
    /// not part of `HistoryEntry`). 16-byte entries per fakegato's
    /// `",10 %s%s-%s:%s %s %s"` format string.
    private static let weatherEntryType: UInt8 = 0x07
    /// Eve Room (1st gen): temperature + humidity + air-quality PPM, then
    /// 3 reserved bytes. 19-byte entries per fakegato's
    /// `",13 %s%s%s%s%s%s0000 00"` format string.
    private static let roomEntryType: UInt8 = 0x0F
    /// Eve Room (2nd gen) / fakegato `room2`: temperature + humidity + VOC
    /// density, then reserved bytes (`0054 a80f01`). 21-byte entries per
    /// fakegato's `",15 %s%s%s%s%s%s0054 a80f01"` format string. The VOC
    /// field is *not* CO₂ PPM, so it's ignored rather than mapped onto
    /// `co2PPM`; only the shared temperature/humidity prefix is decoded.
    private static let room2EntryType: UInt8 = 0x7F

    /// Result of `parseEntries(_:referenceDate:)` — a named type rather
    /// than a tuple since SwiftLint's `large_tuple` rule caps tuples at 2
    /// members.
    public struct EntriesBatch: Equatable, Sendable {
        public let entries: [HistoryEntry]
        public let referenceDate: Date
        /// The highest `counter` seen across *every* record processed in
        /// this batch — including reference-time entries and unsupported
        /// types that don't produce a `HistoryEntry` — since each record
        /// still occupies one address slot in the accessory's ring buffer;
        /// `nil` if the batch was empty.
        public let lastAddress: UInt32?
        /// Total number of well-formed records seen in this batch,
        /// regardless of whether their `type` was decodable into a
        /// `HistoryEntry`. `entries.isEmpty` alone can't tell a batch made
        /// up entirely of unsupported/skipped types (real progress —
        /// `lastAddress` still advanced) apart from a batch that had
        /// nothing parseable at all; `recordCount == 0` is the latter.
        /// `FakegatoHistoryDrainer.drainEntries` uses this distinction to
        /// decide whether to keep reading past an all-unsupported batch
        /// instead of stopping early.
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
    /// `length` bytes long in total. `referenceDate` is the accessory's
    /// reference time from the most recent `parseStatus(_:)` call (or a
    /// prior reference-time entry earlier in this same stream); entries
    /// are timestamped `referenceDate + secondsSinceReference`, which
    /// works out exactly because Eve's reference epoch (2001-01-01 UTC)
    /// matches Foundation's own `timeIntervalSinceReferenceDate` epoch, so
    /// no manual epoch arithmetic is needed. A malformed/truncated trailing
    /// record stops decoding rather than throwing, returning whatever
    /// entries were successfully read before it. Also returns the
    /// reference date as of the end of this batch (unchanged if no
    /// reference-time entry appeared in it), so a caller reading
    /// `E863F117` across multiple characteristic reads can carry it
    /// forward into the next call.
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
            // 10-byte common header: length(1) + counter(4) + secondsSinceReference(4) + type(1).
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
                break // Unsupported entry type (Door/Motion/Energy/Aqua/etc.) — skip.
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

    /// Decodes the leading temperature+humidity fields of an entry — shared
    /// by `temperatureHumidityEntryType` (fakegato `custom` temp+humidity),
    /// `weatherEntryType` (Eve Weather; trailing pressure ignored), and
    /// `room2EntryType` (Eve Room 2; trailing VOC ignored), all of which
    /// have byte-for-byte identical temperature/humidity payload prefixes.
    /// `entryEnd` is the record's declared end (`offset + entryLength`); a
    /// record too short to hold the full payload is skipped rather than
    /// reading into the next record's bytes, mirroring `parseEntries`'s own
    /// per-record bounds check.
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
    /// PPM) — 6 payload bytes. `entryEnd` is the record's declared end
    /// (`offset + entryLength`); a record too short to hold the full
    /// payload is skipped rather than reading into the next record's
    /// bytes, mirroring `parseEntries`'s own per-record bounds check.
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
