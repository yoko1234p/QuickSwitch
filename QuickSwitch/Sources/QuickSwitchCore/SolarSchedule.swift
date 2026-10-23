import Foundation

public struct SolarLocation: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public var valid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public enum SolarDay: Equatable, Sendable {
    case events(sunrise: Date, sunset: Date)
    case polarDay
    case polarNight
    public func dark(at date: Date) -> Bool {
        switch self {
        case .events(let sunrise, let sunset): return date < sunrise || date >= sunset
        case .polarDay: return false
        case .polarNight: return true
        }
    }
}

/// Independently implemented NOAA/Meeus solar geometry; local date and time-zone changes are recomputed.
/// No network requests or location service are needed. Refraction uses the standard 90.833° zenith.
public enum SolarSchedule {
    public static func day(at date: Date, location: SolarLocation, calendar: Calendar = .current) -> SolarDay? {
        guard location.valid else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: parts) else { return nil }
        let julian = midnight.timeIntervalSince1970 / 86400 + 2440587.5
        let noonTerms = terms(julian: julian + (720 - 4 * location.longitude) / 1440)
        let cosine = hourAngleCos(latitude: location.latitude, declination: noonTerms.declination)
        if cosine < -1 { return .polarDay }
        if cosine > 1 { return .polarNight }
        guard let rise = eventMinute(julian: julian, location: location, rising: true),
            let set = eventMinute(julian: julian, location: location, rising: false)
        else { return nil }
        return .events(sunrise: midnight.addingTimeInterval(rise * 60), sunset: midnight.addingTimeInterval(set * 60))
    }
    private static func eventMinute(julian: Double, location: SolarLocation, rising: Bool) -> Double? {
        var estimate = 720 - 4 * location.longitude
        for _ in 0..<3 {
            let solar = terms(julian: julian + estimate / 1440)
            let cosine = hourAngleCos(latitude: location.latitude, declination: solar.declination)
            guard (-1...1).contains(cosine) else { return nil }
            let hourAngle = acos(cosine) * 180 / .pi * (rising ? 1 : -1)
            estimate = 720 - 4 * (location.longitude + hourAngle) - solar.equationOfTime
        }
        return estimate
    }
    private static func hourAngleCos(latitude: Double, declination: Double) -> Double {
        cos(90.833 * .pi / 180) / (cos(latitude * .pi / 180) * cos(declination)) - tan(latitude * .pi / 180)
            * tan(declination)
    }
    private static func terms(julian: Double) -> (equationOfTime: Double, declination: Double) {
        let t = (julian - 2_451_545) / 36525
        let meanLongitude = normalized(280.46646 + t * (36000.76983 + t * 0.0003032))
        let anomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * .pi / 180
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let center =
            sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * anomaly) * (0.019993 - 0.000101 * t)
            + sin(3 * anomaly) * 0.000289
        let apparentLongitude =
            (meanLongitude + center - 0.00569 - 0.00478 * sin((125.04 - 1934.136 * t) * .pi / 180)) * .pi / 180
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let obliquity = (23 + (26 + seconds / 60) / 60 + 0.00256 * cos((125.04 - 1934.136 * t) * .pi / 180)) * .pi / 180
        let declination = asin(sin(obliquity) * sin(apparentLongitude))
        let y = pow(tan(obliquity / 2), 2)
        let longitude = meanLongitude * .pi / 180
        let equation =
            y * sin(2 * longitude) - 2 * eccentricity * sin(anomaly) + 4 * eccentricity * y * sin(anomaly)
            * cos(2 * longitude) - 0.5 * y * y * sin(4 * longitude) - 1.25 * eccentricity * eccentricity
            * sin(2 * anomaly)
        return (4 * equation * 180 / .pi, declination)
    }
    private static func normalized(_ degree: Double) -> Double {
        let remainder = degree.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }
}
