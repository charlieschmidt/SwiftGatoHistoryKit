import Foundation

/// Shared byte-fixture helpers for building raw Eve/fakegato-history
/// Entries-characteristic records, used by both `FakegatoHistoryDecoderTests`
/// (direct decoder coverage) and `FakegatoHistoryDrainerTests`
/// (drain-loop coverage against scripted characteristic reads) so both
/// suites build byte-for-byte identical fixtures from one place rather than
/// maintaining duplicate byte-layout logic.
enum FakegatoTestBytes {

    /// Builds one raw entry record:
    /// `[length][counter LE32][secondsSinceReference LE32][type][payload]`.
    static func entryBytes(counter: UInt32, secondsSinceReference: UInt32, type: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt8(10 + payload.count)
        return [length] + littleEndian(counter) + littleEndian(secondsSinceReference) + [type] + payload
    }

    /// Encodes `value` as 2 little-endian bytes.
    static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// Encodes `value` as 4 little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// An Eve Room (`0x0F`) entry payload: temperature/humidity ×100 (both
    /// little-endian), PPM raw (little-endian), plus 3 reserved trailing
    /// bytes.
    static func roomPayload(temperatureCelsiusTimes100: Int16, humidityPercentTimes100: UInt16, ppm: UInt16) -> [UInt8] {
        littleEndian(UInt16(bitPattern: temperatureCelsiusTimes100)) + littleEndian(humidityPercentTimes100) + littleEndian(ppm) + [0, 0, 0]
    }

    /// A reference-time (`0x81`) entry payload: the new reference time
    /// (little-endian) plus 7 reserved trailing bytes, matching the real
    /// 21-byte total entry length.
    static func referenceTimePayload(newReferenceSeconds: UInt32) -> [UInt8] {
        littleEndian(newReferenceSeconds) + [0, 0, 0, 0, 0, 0, 0]
    }

    /// Parses a space-separated hex string (e.g. `"87 95 69 00"`) into raw
    /// bytes, for fixtures captured verbatim from a real accessory.
    static func hexBytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}
