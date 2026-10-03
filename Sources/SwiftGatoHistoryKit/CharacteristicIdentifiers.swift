/// The three Eve/fakegato-history characteristic UUIDs, as plain `String`s
/// (no HomeKit/CoreBluetooth dependency) so any consumer — HomeKit
/// controller-side or otherwise — knows exactly what to resolve without
/// reverse-engineering it themselves. All three sit under the custom
/// `E863F007-079E-48FF-8F27-9C2605A29F52` History service.
public enum FakegatoCharacteristic {
    public static let historyRequestUUID = "E863F11C-079E-48FF-8F27-9C2605A29F52"
    public static let historyStatusUUID = "E863F116-079E-48FF-8F27-9C2605A29F52"
    public static let historyEntriesUUID = "E863F117-079E-48FF-8F27-9C2605A29F52"
}
