/// The three Eve/fakegato-history characteristic UUIDs, as plain `String`s
/// so consumers don't need a HomeKit/CoreBluetooth dependency just to
/// resolve them. All three live under the custom
/// `E863F007-079E-48FF-8F27-9C2605A29F52` History service.
public enum FakegatoCharacteristic {
    public static let historyRequestUUID = "E863F11C-079E-48FF-8F27-9C2605A29F52"
    public static let historyStatusUUID = "E863F116-079E-48FF-8F27-9C2605A29F52"
    public static let historyEntriesUUID = "E863F117-079E-48FF-8F27-9C2605A29F52"
}
