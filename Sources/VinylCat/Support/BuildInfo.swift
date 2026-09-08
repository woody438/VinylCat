import Foundation

/// Version and build stamp for Settings → ABOUT. `scripts/build-app.sh` writes the build stamp
/// (date, time and git commit) into Info.plist as `VinylCatBuild`; the bare debug binary has no
/// bundle, so it reports itself as a dev build.
enum BuildInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "VinylCat \($0)" } ?? "VinylCat (dev build)"
    }
    static var build: String {
        Bundle.main.infoDictionary?["VinylCatBuild"] as? String
            ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).map { "build \($0)" }
            ?? "run from .build — no bundle stamp"
    }
}
