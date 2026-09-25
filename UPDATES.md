# Updating the companion

For removal, see [Complete removal](#complete-removal).

The bridge checks stable GitHub releases once a day. New Hermes Jr. iOS builds also check the hosted signed release feed on foreground/open and reconnect, with a 15-minute app cache and a five-minute server cache. **Check for updates** in Settings bypasses the app cache. Checks never install code, start model conversations, or restart Hermes. The host’s checks-off preference also disables automatic phone checks on companions that advertise that preference.

The update notice offers **Update with Hermes** or **Copy update prompt**. Update with Hermes starts one new conversation in the default profile and uses the normal model allowance, only after the user taps it. The app remembers that request across reconnects and relaunches; it never automatically resends an uncertain prompt. If an update needs attention, open its conversation before starting another action.

When notifications are enabled, a successful guided update sends an encrypted completion notification to the requesting phone, linking to that conversation. The signed installer verifies the installed version and connection before recording success. Model output alone cannot complete a request. Notification opt-out and device revocation are checked again at completion. Copied prompts without a tracking receipt still use the normal updater but do not request a completion push.

The app says when the package has been installed and reminds the user to restart existing Hermes sessions when their work is finished. This is necessary to load new hooks. The updater does not terminate active Hermes conversations. “Not now” hides an available version from Bots; it remains visible in Settings.

```sh
hermes jr update
hermes jr update --checks off
hermes jr update --checks on
```

## Install an update

Ask Hermes:

> Update my Hermes Jr. companion from https://github.com/cyberculturedhq/hermes-jr-companion. Read UPDATES.md, wait for active work to finish, and run hermes jr update --install. Preserve my pairings and profile settings. Restart loaded Hermes processes when idle and run hermes jr doctor. Report any unfinished steps.

Or, when Hermes is idle:

```sh
hermes jr update --install
hermes jr doctor
```

The installer verifies a stable release and pins its commit, uses Hermes’ native plugin scanner, and checks installed profile copies for local changes before replacing anything. It saves the plugin copies and their installation metadata, preserves enabled/disabled settings, and lets Hermes' package manager select the pinned Python package from PyPI. It restarts the managed bridge if it was running. Loaded Hermes processes still need a restart when idle to use the new hooks.

If installation, validation, or bridge startup fails, it restores the previous code automatically. Pairings, follows, and conversation state are never restored from an old snapshot.

To undo the most recent managed update:

```sh
hermes jr rollback
```

Rollback refuses to overwrite subsequent local code changes. Backups and private logs are kept under the companion state directory in `update-backups`; `last-update.json` identifies the latest backup. If the package cannot start, run the saved standalone recovery helper with Hermes' currently selected Python executable. It restores plugin files and asks Hermes' package manager to select their previous pinned package:

```sh
/path/to/hermes/python /path/to/update-backups/BACKUP_ID/recover.py
```

Then restart loaded Hermes processes when idle and run `hermes jr doctor`. Keep backups until you are satisfied with the update. Never delete private state to repair installed code.

## Updating an older companion

For installations before 0.17.0, stop Hermes Jr. and finish active Hermes work. Move every old `plugins/hermes-jr` directory out of the Hermes home (the default profile and each named profile) into a private backup, then finish the pending Hermes Agent update. The old plugin directory contains a `pyproject.toml`; multiple enabled copies cause Hermes' new package manager to reject the shared workspace, so individual profile removals can fail until the duplicate set is gone. Keep the profile installation metadata and companion state in place. Once Hermes updates, use the current [INSTALL.md](INSTALL.md) procedure to install the newly released plugin across profiles, and run `hermes jr doctor`. Do not delete companion state or pairings unless you intend to reset them.

For later releases, download the current `install.py` as shown in [INSTALL.md](INSTALL.md) and run it with `--update` only for an explicitly requested update when Hermes work is idle. It loads the signed release's managed updater, preserves profile activation choices, and uses the same `hermes jr rollback` record and automatic recovery. Normal setup without `--update` never upgrades an installed companion.

Hermes' package manager resolves changed requirements across every enabled profile. Conflicting pins, local source edits, and unsupported layouts stop before replacement; report the specific constraint rather than overwriting the user's setup. Diagnose connection failures with [STARTUP.md](STARTUP.md), not a reinstall.

## Limits and release policy

Managed updates support standard, unmodified native installations using the official `.git#plugin` source and Hermes' package manager. Forks, editable installs, linked directories, all-disabled copies, dependency conflicts with other plugins, and protocol/state migrations need release-specific manual instructions. The updater does not silently migrate data.

Checks use stable `vMAJOR.MINOR.PATCH` GitHub releases, not development `main`. The hosted feed contains only a signed version and commit; no device identifiers or model prompts. GitHub receives the host’s network address and a generic user agent, but no pairing or Hermes credentials. Failed checks do not interrupt the bridge. The legacy host notice expires after seven days without a successful check. Guided receipts expire after one day if they have not started and are retained for at most seven days.

Before releasing, run Python and Worker checks, build the package, and exercise update and recovery paths. Actual OS lifecycle changes also require runtime tests. Automated tests do not constitute an independent security audit.

## Release signatures

Starting with 0.7.0, update checks and installation verify an Ed25519 signature
using a public key pinned in the installed plugin. The signed message binds the
repository, stable version and exact Git commit. A changed tag, unsigned release,
wrong signing key or altered version is rejected before the native installer or
package manager acts. The pinned package is published separately to PyPI from
the same tag by GitHub Actions with PyPI trusted publishing; the release
signature binds the plugin commit, while PyPI and that workflow provide the
package distribution. Updating remains an explicit user action.

The first installation still trusts the repository you choose. Signatures do not
make a malicious maintainer safe, and users must keep the pinned verification
code intact. Releases before 0.7.0 do not gain this protection retroactively.

Maintainers: keep the private release key outside GitHub and the source tree,
with mode 0600. After the release commit passes CI and merges, run:

```
python tools/sign_release.py --key /private/path/release-ed25519.pem --version VERSION --commit COMMIT
```

Create the `vVERSION` tag at that exact commit, wait for the PyPI publishing
workflow to succeed and confirm the package is available on PyPI, then include
the resulting HTML comment unchanged in the GitHub release body. The release-feed workflow validates that signature and attaches `companion-release.json`; it has no private signing key. Tag rules prevent later moves and
deletion. Keep a secure backup of the private key. Key rotation requires a release
signed by the currently trusted key that ships the next trusted public key;
losing that key requires a clearly communicated manual reinstall. A GitHub
“Verified” badge is separate from this plugin's signature verification.

## Complete removal

Revoke each phone with `PYTHON -m hermes_jr.cli revoke DEVICE_UUID`, then uninstall the companion service. If setup created a dedicated backend, remove it with `PYTHON -m hermes_jr.cli backend uninstall`. Preserve any pre-existing Hermes supervisor.

Disable and remove the native plugin in each installed profile. Hermes' package manager then removes its requirement from the shared environment; do not use `pip` to modify that environment. Companion state survives routine updates and uninstall. For a clean reinstall, remove only companion-specific state after revocation and service removal. Preserve conversations, model settings, and the Hermes pairing subsystem.

End any conversation still running old plugin callbacks before checking removal or starting a clean-install test.
