# Contributing

Thanks for wanting to help. NitiaDock is a small project maintained by one person, so a short
issue first saves both of us time before a large pull request.

## Bugs and ideas

Use the issue templates. For bugs, the version (Settings > About) and macOS version matter most,
and a crash report (`~/Library/Logs/DiagnosticReports/NitiaDock-*.ips`) makes most crashes
fixable.

## Code

- Xcode 26 or later. Open `NitiaDock.xcodeproj`.
- `Scripts/build_and_run.sh` builds Debug and relaunches; `Scripts/install_local_release.sh`
  installs a Release build.
- Run the tests with `-derivedDataPath build/TestDD` (see the README for why).
- The project lists every source file explicitly. Register a new file with
  `python3 Scripts/fork_add_source.py <path> --app [--tests]`, and remove one with
  `python3 Scripts/remove_source.py <path>`.
- UI text goes through `String(localized:)`. Add new strings with
  `python3 Scripts/fork_add_string.py "Text"` and check with `python3 Scripts/check_localization.py`.
  Edit `Resources/Localizable.xcstrings` as text only; it does not survive a JSON round trip.
- New settings appear in the settings window and, if they should be searchable, in
  `App/Scenes/SettingsSearch.swift` with exactly the row's title.
- User-visible changes get a line in `CHANGELOG.md`.

## Releases (maintainer)

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project and add a
   `## <version>` section to `CHANGELOG.md`.
2. Run `Scripts/release.sh`. It runs the checks and tests, builds a universal Release, signs it
   with the Developer ID, notarizes and staples the ZIP and DMG, and adds the release to
   `appcast.xml`. It uploads nothing.
3. Run the `gh release create` command it prints, then commit and push `appcast.xml`.
4. Update the Homebrew cask in `Tripchipp/homebrew-tap` (`Casks/nitiadock.rb`): set `version` and
   `sha256` to the DMG's checksum, which the release script prints.

The Sparkle private key lives only in the maintainer's login keychain. Back it up with
`generate_keys -x <file>` and keep that file somewhere safe: without it, installed copies can no
longer be updated.
