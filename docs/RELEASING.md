# Releasing

How a build becomes a release that players can install and that existing
installs will offer as an update. **No release has been published from this
repository yet**, so this is the procedure for the first one as well.

A release is a Developer ID signed, notarised build that has passed every
test. `make app` output is ad-hoc signed and is never a release.

## Before The First Release

Three decisions are open and block a first release:

- **Signing identity.** An Apple Developer ID Application certificate and
  notary credentials for whoever publishes.
- **Online play.** It is off in every build and a Developer ID build refuses
  to switch it on. It stays off until BAR's maintainers have agreed to this
  build connecting to their servers.
- **Where releases live.** The app's update feed, download links and the
  "new version needed" page all point at this repository's GitHub Releases.

## One-Time Setup

### Update Signing Key

Installed apps accept an update only if its archive verifies against the
public key in `packaging/update-public-key`, which is compiled into every
build. The private half signs the feed.

```sh
make app                                                   # builds the updater tool
release-artifacts/Accurona.app/Contents/MacOS/updater keygen --out ~/.accurona/update-signing.key
```

`keygen` prints the public key: commit it as `packaging/update-public-key`.
The private key stays on the release machine (`ACCURONA_UPDATE_SIGNING_KEY`
names another path). **Back it up.** If it is lost, installed apps can never
update in-app again; they still see the "new version needed" notice and can
download by hand. To replace a key, ship one release signed with the old key
that carries the new public key. `packaging/test/updater-test.sh` covers the
swap and every refusal.

### Notary Credentials

Either a keychain profile:

```sh
xcrun notarytool store-credentials <profile-name>
```

or an App Store Connect API key, passed as `NOTARY_KEY` (path to the `.p8`
file), `NOTARY_KEY_ID` and `NOTARY_ISSUER`. The API key form does not depend
on the login keychain, so it suits a machine that builds unattended.

### A Demo For The Replay Check

The release build re-simulates one fleet replay recorded on the engine
version being released. Pick one with
`scripts/find-fleet-replays.py <engine version>`, download it, and either put
it under `refdemos/<engine version>/` or pass `RELEASE_SMOKE_DEMO=<file>`.
Its game version and map must be in the app's data folder.

## Release Steps

1. **Check the tree.** `main` is pushed, the working tree is clean, and
   [VERSIONS.md](VERSIONS.md) and [PARITY.md](PARITY.md) describe this
   commit.
2. **Run the checks the release build does not run:**
   `scripts/run-unit-tests.sh`, `make test`, and `scripts/check-nonmac.sh`.
   Go through the non-Mac checklist in [MAINTENANCE.md](MAINTENANCE.md).
3. **Set the version.** Edit `packaging/PORT_VERSION` (the number players
   see) and commit. The engine version is read from the built engine and is
   not typed anywhere.
4. **Review the message file.** Every installed copy reads
   `message-config/messages.json` from `main` at each launch, and messages
   target versions. A release that changes behaviour can make a live message
   wrong, so read each file under `message-config/messages/` against the new
   version, assemble (`python3 message-config/assemble.py`), and commit. See
   [message-config/README.md](../message-config/README.md).
5. **Build.**

   ```sh
   IDENTITY="Developer ID Application: NAME (TEAMID)" NOTARY_PROFILE=<profile-name> make release
   ```

   This runs the engine build with its libm gate, the streflop sync test, the
   replay check, the bundle audits and the license audit, signs with the
   hardened runtime, runs visual regression and the driver smoke test on the
   signed bundle, notarises and staples the zip and the disk image, and
   writes the update feed. For a Developer ID build none of the tests can be
   skipped, a driver without a provenance stamp is refused, and online play,
   pinned content tags and a non-default message or update address are
   refused unless `--allow-release-overrides` is given. The summary at the
   end prints the values in effect: read it.
6. **Build the engine-only bundle** if it is being published:
   `packaging/release-build.sh --profile engine --identity ... --notary-profile ...`.
7. **Tag and publish.** Tag the commit `v<PORT_VERSION>` and create a GitHub
   release for the tag with these files from `release-artifacts/`:

   | File | What It Is |
   |---|---|
   | `Accurona-v<version>.dmg` | The installer players download. |
   | `Accurona-v<version>.zip` | The archive the in-app updater downloads. Its name and address are in the feed. |
   | `appcast.json` | The signed update feed. It must be an asset of the newest release, because installs read `releases/latest/download/appcast.json`. |
   | `Recoil-macos-<engine>-port<version>.zip` | The engine-only bundle, when published. |

8. **Keep the debug symbols.** The build writes
   `release-artifacts/symbols/<engine>-port<version>-<profile>/`. Archive
   that folder somewhere private: it is what turns a crash report from this
   release into file and line numbers, and the next build does not recreate
   it. Do not publish it; it holds builder paths.
9. **Check from the outside.** Download the disk image on another Mac, open
   it, and confirm Gatekeeper accepts the app. On a Mac with the previous
   release installed, confirm the app offers the update and that it installs.

## What The Update Feed Promises

`appcast.json` names a version, an archive address, the archive's length and
SHA-256, a date, a minimum macOS version and notes, with one signature over
all of them. An installed app checks that signature against its built-in
public key before it asks the player anything, so a feed that was edited, or
an older feed format, is ignored. It then downloads only from an `https`
address under the release download base the build recorded, stops at the
promised length, and replaces itself only when the archive matches the
SHA-256, the unpacked bundle has this app's bundle identifier and exactly the
promised version, and `codesign --verify --deep --strict` passes. An app
signed by a Developer ID team accepts only a new one signed by the same team.

The feed signature does not expire, which is why only a signed, notarised
build writes one: a feed for an ad-hoc build would offer that build to every
older copy. Nothing compares the feed's date with a clock, so an old feed
that is still validly signed can be served again; it can only offer the
version it was signed for, and the app never installs a version that is not
newer than itself.

## The Engine Notice

Separately from the update feed, each launch reads which engine BAR's
production servers run from BYAR-Chobby's `dist_cfg/config.json`. When that
engine is newer than the one in the app, the app shows a "New Version Needed"
dialog with a button that opens this repository's latest release. It stops by
itself once the player installs an app with that engine, so no message-file
entry is needed. Test: `packaging/test/engine-nudge-test.sh`.

## The Caution Text

The README caution and the first-run consent dialog
(`packaging/consent-dialog.swift`) say the same thing in the same terms. If
one changes, change the other. `packaging/release-notes-header.md` holds the
same caution for release notes.
