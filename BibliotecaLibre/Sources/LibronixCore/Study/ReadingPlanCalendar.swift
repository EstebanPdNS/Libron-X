import Foundation

/// Interoperable all-day events. A civil date is never converted through a
/// local midnight, so exporting in a different time zone cannot shift a day.
public enum ReadingPlanCalendar {
    public static func export(_ plan: ReadingPlan, timestamp: Date = Date()) throws -> Data {
        try plan.validate()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: timestamp)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Libron-X//Reading Plans//EN", "CALSCALE:GREGORIAN"]
        for reading in plan.readings {
            let end = try reading.day.adding(days: 1)
            lines += ["BEGIN:VEVENT", "UID:\(reading.id.uuidString.lowercased())@libron-x.local", "DTSTAMP:\(stamp)",
                      "DTSTART;VALUE=DATE:\(reading.day.calendarValue)", "DTEND;VALUE=DATE:\(end.calendarValue)",
                      "SUMMARY:\(escape(plan.title))", "DESCRIPTION:\(escape(reading.reference))", "TRANSP:TRANSPARENT", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return Data((lines.map(fold).joined(separator: "\r\n") + "\r\n").utf8)
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }
    /// Fold at UTF-8 scalar boundaries, counting the continuation space.
    private static func fold(_ line: String) -> String {
        var result = "", count = 0
        for scalar in line.unicodeScalars {
            let part = String(scalar), length = part.utf8.count
            if count + length > 75 { result += "\r\n "; count = 1 }
            result += part; count += length
        }
        return result
    }
}
