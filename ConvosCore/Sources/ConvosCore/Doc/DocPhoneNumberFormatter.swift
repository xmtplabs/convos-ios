import Foundation

public struct DocPhoneNumberFormatter: Equatable, Sendable {
    public let regionCode: String

    public init(regionCode: String) {
        self.regionCode = regionCode.uppercased()
    }

    public var initialText: String {
        "+\(callingCode)"
    }

    public var callingCode: String {
        Self.callingCodesByRegion[regionCode] ?? Self.defaultCallingCode
    }

    public func e164(from input: String) -> String? {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputDigits = cleanInput.filter(\.isNumber)
        let digits: String
        if cleanInput.hasPrefix("+") {
            digits = inputDigits
        } else if callingCode == "1", inputDigits.count == 11, inputDigits.hasPrefix("1") {
            digits = inputDigits
        } else {
            let nationalDigits = nationalDigits(from: inputDigits)
            digits = callingCode + nationalDigits
        }
        guard digits.range(of: #"^[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else {
            return nil
        }
        if callingCode == "1", !input.hasPrefix("+") {
            guard digits.count == 11 else { return nil }
        }
        return "+\(digits)"
    }

    public func formatPartial(_ input: String) -> String {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(cleanInput.filter(\.isNumber).prefix(15))
        guard !digits.isEmpty else { return cleanInput.hasPrefix("+") ? "+" : "" }

        if cleanInput.hasPrefix("+") {
            return formatInternational(digits)
        }
        if callingCode == "1" {
            return formatNorthAmericanNational(String(digits.prefix(10)))
        }
        return group(digits, sizes: [3, 3, 3, 3, 3])
    }

    private func nationalDigits(from digits: String) -> String {
        guard callingCode != "1",
              regionCode != "IT",
              digits.hasPrefix("0") else {
            return digits
        }
        return String(digits.dropFirst())
    }

    private func formatInternational(_ digits: String) -> String {
        if digits.hasPrefix("1") {
            let national = String(digits.dropFirst())
            guard !national.isEmpty else { return "+1" }
            return "+1 \(formatNorthAmericanNational(String(national.prefix(10))))"
        }
        if digits.hasPrefix("44") {
            let national = String(digits.dropFirst(2))
            guard !national.isEmpty else { return "+44" }
            return "+44 \(formatUnitedKingdomNational(String(national.prefix(10))))"
        }
        guard let code = Self.callingCodes.first(where: { digits.hasPrefix($0) }) else {
            return "+\(group(digits, sizes: [3, 3, 3, 3, 3]))"
        }
        let national = String(digits.dropFirst(code.count))
        guard !national.isEmpty else { return "+\(code)" }
        return "+\(code) \(group(national, sizes: [3, 3, 3, 3]))"
    }

    private func formatNorthAmericanNational(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        let area = digits.prefix(3)
        let remainder = digits.dropFirst(3)
        guard remainder.count > 3 else { return "(\(area)) \(remainder)" }
        return "(\(area)) \(remainder.prefix(3))-\(remainder.dropFirst(3))"
    }

    private func formatUnitedKingdomNational(_ digits: String) -> String {
        guard digits.count > 2 else { return digits }
        let area = digits.prefix(2)
        let remainder = digits.dropFirst(2)
        guard remainder.count > 4 else { return "\(area) \(remainder)" }
        return "\(area) \(remainder.prefix(4)) \(remainder.dropFirst(4))"
    }

    private func group(_ digits: String, sizes: [Int]) -> String {
        var groups: [String] = []
        var start = digits.startIndex
        for size in sizes where start < digits.endIndex {
            let end = digits.index(start, offsetBy: size, limitedBy: digits.endIndex) ?? digits.endIndex
            groups.append(String(digits[start..<end]))
            start = end
        }
        return groups.joined(separator: " ")
    }

    private static let defaultCallingCode: String = "1"

    private static let callingCodes: [String] = Array(Set(callingCodesByRegion.values))
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }

    private static let callingCodesByRegion: [String: String] = [
        "AE": "971", "AL": "355", "AR": "54", "AT": "43", "AU": "61",
        "BA": "387", "BB": "1", "BD": "880", "BE": "32", "BG": "359",
        "BH": "973", "BO": "591", "BR": "55", "BS": "1", "CA": "1",
        "CH": "41", "CL": "56", "CN": "86", "CO": "57", "CR": "506",
        "CU": "53", "CZ": "420", "DE": "49", "DK": "45", "DO": "1",
        "DZ": "213", "EC": "593", "EE": "372", "EG": "20", "ES": "34",
        "ET": "251", "FI": "358", "FR": "33", "GB": "44", "GH": "233",
        "GR": "30", "GT": "502", "HK": "852", "HN": "504", "HR": "385",
        "HU": "36", "ID": "62", "IE": "353", "IL": "972", "IN": "91",
        "IS": "354", "IT": "39", "JM": "1", "JO": "962", "JP": "81",
        "KE": "254", "KH": "855", "KR": "82", "KW": "965", "LB": "961",
        "LK": "94", "LT": "370", "LV": "371", "MA": "212", "MK": "389",
        "MO": "853", "MX": "52", "MY": "60", "NG": "234", "NI": "505",
        "NL": "31", "NO": "47", "NP": "977", "NZ": "64", "OM": "968",
        "PA": "507", "PE": "51", "PH": "63", "PK": "92", "PL": "48",
        "PR": "1", "PT": "351", "PY": "595", "QA": "974", "RO": "40",
        "RS": "381", "RU": "7", "RW": "250", "SA": "966", "SE": "46",
        "SG": "65", "SI": "386", "SK": "421", "SV": "503", "TH": "66",
        "TN": "216", "TR": "90", "TT": "1", "TW": "886", "TZ": "255",
        "UA": "380", "UG": "256", "US": "1", "UY": "598", "VE": "58",
        "VN": "84", "ZA": "27",
    ]
}
