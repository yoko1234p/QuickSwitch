import Foundation

public struct SourceSystemObservation: Codable, Equatable, Sendable {
    public var bundleID: String
    public var version: String
    public var observedAt: Date
    public var loginAtStartup: Bool
    public var source: String
    public var evidenceSHA256: String
    public init(
        bundleID: String, version: String, observedAt: Date, loginAtStartup: Bool, source: String,
        evidenceSHA256: String
    ) {
        self.bundleID = bundleID
        self.version = version
        self.observedAt = observedAt
        self.loginAtStartup = loginAtStartup
        self.source = source
        self.evidenceSHA256 = evidenceSHA256
    }
    public func validate() throws {
        guard bundleID == OneSwitchImporter.sourceBundleID, !version.isEmpty, source == "native-preferences-checkbox",
            evidenceSHA256.count == 64, evidenceSHA256.allSatisfy({ $0.isHexDigit })
        else { throw ConfigurationError.invalid(L10n.text("原版系統設定觀察資料無效")) }
    }
}

extension ConfigurationStore {
    /// Record a proven source preference without registering login items or changing any feature.
    public func recordSystemObservation(_ observation: SourceSystemObservation) throws {
        try observation.validate()
        guard var configuration = try load(), let migration = configuration.migration,
            migration.sourceVersion == observation.version
        else { throw ConfigurationError.invalid(L10n.text("請先匯入相同版本的 One Switch 設定")) }
        configuration.sourceSystemObservation = observation
        try save(configuration)
    }
}
