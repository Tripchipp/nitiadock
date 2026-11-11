import Foundation

/// Type narrowing for the `Any?` read back from UserDefaults. Both rules were hit in two places
/// (`AppSettingsStore` / `NativeDockPreferencesService`), so they live in one place:
/// - `Bool` / `CFBoolean` bridges to `NSNumber`; unless excluded by CF type first, `true` is read as 1.0;
/// - NaN / ±inf reaching a downstream `Int(...)` crashes (every NaN comparison is false, so clamp has no
///   effect); non-finite values count as missing.
enum DefaultsValueParsing {
    /// A real numeric object that is finite; booleans, strings, missing, NaN / inf -> nil.
    nonisolated static func finiteNumericValue(_ value: Any?) -> Double? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// Accepts only a real boolean object (`CFBoolean`); the numbers 0 / 1 are not booleans.
    nonisolated static func strictBooleanValue(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }
}
