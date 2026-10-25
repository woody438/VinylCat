import Foundation

/*
 * Where updates come from, and which is newer: the half of the updater that isn't the Mac
 * (`Updater` does the downloading and the swap). Replaced the release.json notice on
 * 2026-10-25 — that one could only point at a DMG and ask you to drag it over the old app,
 * on the assumption that without a Developer ID the app couldn't safely replace itself.
 * It can: a build signed with the project's own certificate has a designated requirement
 * naming that certificate, and `Updater.verify` holds every download to it.
 *
 * Every build CI publishes carries VinylCat.json beside the app:
 *
 *   {"build": 41, "version": "0.2.2", "commit": "a677f40", "channel": "latest", "notes": "…"}
 *
 * `build` is the CI run's number, written into the app as CFBundleVersion: higher is newer.
 * Main's builds go to the "latest" release; a pull request's to "preview". Every copy follows
 * "latest"; with Settings → UPDATES → Get preview builds on, "preview" too, so a tester gets
 * the next preview, and then main's build once it's merged. Switched off again while running
 * a preview, main's build is only newer once main next builds: until then, BACK TO MAIN
 * RELEASE installs main's now.
 *
 * Nothing here touches the disk or the network, so `--self-test` can check all of it.
 */
enum Updates {
    static let repository = "woody438/VinylCat"

    /// What a release says about itself, read from VinylCat.json.
    struct Release: Decodable, Equatable, Sendable {
        var build: Int
        var version: String
        var commit: String
        var channel: String          // the release it sits in: "latest" or "preview"
        /// One line of what's new, for the top-bar chip. CI fills it from the commit subject.
        var notes: String?
    }

    /// A file in a release. The tag is the channel name, so the URL is stable and CI replaces
    /// the release in place rather than piling up tags.
    static func url(_ channel: String, _ file: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(channel)/\(file)")!
    }

    /// The releases followed: main's, and the preview's while previews are on.
    static func channels(previews: Bool) -> [String] {
        previews ? ["preview", "latest"] : ["latest"]
    }

    static func decode(_ data: Data) -> Release? {
        try? JSONDecoder().decode(Release.self, from: data)
    }

    /// The newest release built after `build`, if any.
    static func newest(_ releases: [Release], after build: Int) -> Release? {
        releases.filter { $0.build > build }.max { $0.build < $1.build }
    }

    /// Main's release to go back to from a preview build, with previews off: older than the
    /// preview by number, so not an update, but where you'd be. Nil on main's own builds, with
    /// previews on, or once main's is newer anyway.
    static func backToMain(_ releases: [Release], running build: Int, channel: String, previews: Bool) -> Release? {
        guard channel == "preview", !previews else { return nil }
        return releases.first { $0.channel == "latest" && $0.build < build }
    }
}
