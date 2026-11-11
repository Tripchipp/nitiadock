import Foundation

/// Marker in the menu's version line for "where this bundle came from".
///
/// It exists because of a real incident: the login item was pinned by `SMAppService.mainApp.register()` to
/// `build/DerivedData/.../Debug/` (it registers the bundle running at that moment), so what launched at boot
/// was always the development build, not the release bundle in `/Applications`. After release the mainline
/// version number was not bumped either, the menu showed the two identically, and "minimize feels wrong" was
/// misjudged as a version regression and "two taskbars on screen" as a fix that did not work. With the origin
/// written into the version line, they can be told apart at a glance.
enum BuildProvenance {
    /// The official install location. The trailing `/` is required: otherwise paths like
    /// `/ApplicationsOld/Foo.app` would be misjudged as installed by `hasPrefix`.
    static let installedPrefix = "/Applications/"

    /// Version line suffix; `nil` = a Release bundle in the official install location, no marker.
    ///
    /// Debug takes priority over the location check: a development build copied into `/Applications` is still
    /// a development build and feels different from the release bundle (Debug has no compiler optimization),
    /// which matters more than where it lives.
    static func suffix(isDebugBuild: Bool, bundlePath: String) -> String? {
        if isDebugBuild { return String(localized: "Debug Build") }
        return bundlePath.hasPrefix(installedPrefix) ? nil : String(localized: "Not Installed")
    }

    /// The assembled full version line. The degraded text when version / build is missing matches the old
    /// implementation from before the marker.
    static func versionTitle(
        version: String?,
        build: String?,
        isDebugBuild: Bool,
        bundlePath: String
    ) -> String? {
        let base: String
        switch (version, build) {
        case let (version?, build?): base = String(format: String(localized: "Version %@ (%@)"), version, build)
        case let (version?, nil): base = String(format: String(localized: "Version %@"), version)
        case let (nil, build?): base = String(format: String(localized: "Version (%@)"), build)
        case (nil, nil): return nil
        }
        guard let suffix = suffix(isDebugBuild: isDebugBuild, bundlePath: bundlePath) else {
            return base
        }
        return "\(base) · \(suffix)"
    }
}
