# SwiftGatoHistoryKit

A Swift implementation of the reverse-engineered Eve/Elgato "fakegato-history" characteristic protocol: TLV8 request encoding, Status/Entries decoding, and a drain loop that pages through a HomeKit accessory's on-device history buffer.

This package never imports `HomeKit` — it talks to the outside world only through `Data` in/out and plain closures, so it works with any transport that can write a request characteristic and read back Status/Entries characteristics.

## What's included

- `FakegatoHistoryDecoder` — encodes the History Request TLV8 payload, and decodes the Status and Entries characteristics.
- `FakegatoHistoryDrainer` — repeatedly reads the Entries characteristic until the accessory's reported entry count is reached, nothing new comes back, or a safety cap is hit.
- `HistoryCursor` — pure staleness math for deciding whether a previously-persisted resume cursor still falls within an accessory's currently retained history range.
- `FakegatoCharacteristic` — the three Eve history characteristic UUIDs, as plain `String` constants.
- `HistoryEntry`, `HistoryFetchResult`, `HistorySyncProgress` — plain value types for a consumer's own sync orchestration.

## Usage

Resolve the three characteristics by UUID, write the request, read status, then drain:

```swift
import HomeKit
import SwiftGatoHistoryKit

func fetchHistory(
    from accessory: HMAccessory,
    startingAtAddress requestedAddress: UInt32,
    onProgress: ((_ current: Int, _ total: Int) -> Void)? = nil
) async throws -> HistoryFetchResult {
    // App-owned: resolve HMCharacteristics using the package's UUID constants.
    let characteristics = accessory.services.flatMap(\.characteristics)
    guard
        let request = characteristics.first(where: { $0.characteristicType == FakegatoCharacteristic.historyRequestUUID }),
        let status = characteristics.first(where: { $0.characteristicType == FakegatoCharacteristic.historyStatusUUID }),
        let entries = characteristics.first(where: { $0.characteristicType == FakegatoCharacteristic.historyEntriesUUID })
    else {
        throw MyAppError.historyUnavailable
    }

    // App-owned: read status first so we know the accessory's buffer range, then use
    // HistoryCursor to decide the real start address (a saved cursor that's fallen out
    // of the accessory's retained range needs to reset).
    try await status.readValue()
    guard let statusData = status.value as? Data,
          let parsedStatus = FakegatoHistoryDecoder.parseStatus(statusData) else {
        throw MyAppError.historyUnavailable
    }
    let startAddress = HistoryCursor.isStale(startingAtAddress: requestedAddress, status: parsedStatus)
        ? HistoryCursor.staleCursorFallbackAddress(status: parsedStatus)
        : requestedAddress

    // Package-owned: encode + send the request.
    try await request.writeValue(FakegatoHistoryDecoder.encodeRequest(startAddress: startAddress))

    // Package-owned: drain the entries characteristic until done, reporting progress.
    let result = await FakegatoHistoryDrainer.drainEntries(
        status: parsedStatus,
        accessoryName: accessory.name,
        readNext: {
            try await entries.readValue()
            return entries.value as? Data
        },
        onProgress: onProgress
    )

    return HistoryFetchResult(entries: result.entries, lastSyncedAddress: result.lastAddress)
}
```

Everything that touches the characteristic transport (resolving, reading, writing) is the caller's job; everything that understands the TLV8 bytes and the paging/stop logic is this package's job, reached only through `Data` and closures.

## Requirements

- Swift 6.0+
- iOS 17+ / macOS 14+

## Installation

```swift
.package(url: "https://github.com/charlieschmidt/SwiftGatoHistoryKit", from: "0.1.0")
```
