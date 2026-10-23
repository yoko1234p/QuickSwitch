import XCTest

@testable import QuickSwitchCore

final class BluetoothBatteryTests: XCTestCase {
    func testConnectedReadingsMatchNormalizedAddressAndExcludePrivateMetadata() throws {
        let fixture: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "device_connected": [
                        [
                            "fixture headphones": [
                                "device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelLeft": "65%",
                                "device_batteryLevelRight": "70%", "device_batteryLevelCase": "80%",
                                "device_serialNumber": "must not retain",
                            ]
                        ]
                    ],
                    "device_not_connected": [
                        ["old device": ["device_address": "11:22:33:44:55:66", "device_batteryLevelMain": "95%"]]
                    ],
                ]
            ]
        ]
        let parsed = try BluetoothBatteryParser.parse(JSONSerialization.data(withJSONObject: fixture))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["aabbccddeeff"]?.summary, "左 65% · 右 70% · 盒 80%")
        XCTAssertEqual(BluetoothBatteryParser.addressKey("AA:BB:CC:DD:EE:FF"), "aabbccddeeff")
        XCTAssertNil(parsed["112233445566"])
    }
    func testUnavailableOutOfRangeAndMalformedValuesNeverInventBattery() throws {
        let fixture: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "device_connected": [
                        [
                            "fixture": [
                                "device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelLeft": "unknown",
                                "device_batteryLevelRight": "120%", "device_batteryLevelMain": "0.5",
                            ]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertTrue(try BluetoothBatteryParser.parse(JSONSerialization.data(withJSONObject: fixture)).isEmpty)
        XCTAssertThrowsError(try BluetoothBatteryParser.parse(Data("truncated".utf8)))
        XCTAssertNil(BluetoothBatteryParser.addressKey("invalid"))
    }
}
