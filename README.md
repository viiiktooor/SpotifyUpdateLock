# Spotify Update Lock

Small Windows utility for keeping an intentionally installed classic Spotify Desktop build from immediately replacing itself through its built-in updater.

The launcher is `SpotifyUpdateLock.bat`; the logic is in `SpotifyUpdateLock.ps1`.

## Usage

1. Run `SpotifyUpdateLock.bat` and choose **PREPARE** before installing the target build.
2. Install the desired classic Spotify Desktop version.
3. Return to the same launcher and choose **LOCK** before using Spotify normally.
4. Use **STATUS** for diagnostics and **UNLOCK** to remove the protection.

Direct CLI use is also supported:

```bat
SpotifyUpdateLock.bat PREPARE
SpotifyUpdateLock.bat LOCK
SpotifyUpdateLock.bat STATUS
SpotifyUpdateLock.bat UNLOCK
SpotifyUpdateLock.bat UNLOCK -Force
```

## How it works

`PREPARE` creates `%LOCALAPPDATA%\Spotify\Update` when necessary, creates a guard file, applies one exact deny ACE for the current user, verifies that a file cannot be created in the directory, and creates a temporary outbound firewall rule for `%APPDATA%\Spotify\Spotify.exe`.

The firewall rule has a unique internal name (`SpotifyUpdateLock-<GUID>`). That exact name is stored before the rule is created, so a crash does not leave an unidentified rule behind. Existing rules are never replaced simply because they share the same display name.

`LOCK` refuses to release the temporary firewall while the target Spotify process, or a Spotify process with an unreadable path, may still be running. After the updater-directory lock is verified and the expected executable exists, the temporary firewall rule is removed.

`UNLOCK` removes only the exact utility-shaped ACE and guard file when ownership is recorded. `-Force` is an escape hatch for the filesystem protection when state ownership is missing/corrupt; it never removes an unrecorded firewall rule.

## State and safety

State is stored in `%LOCALAPPDATA%\SpotifyUpdateLock\state.json` using a temp-file-and-replace write. It records ownership of the updater directory, deny ACE, guard file, and unique firewall rule name.

A newer state schema is treated as **Unsupported** and this version refuses to mutate anything. A corrupt state is treated conservatively. Only one action can run at a time per Windows user, and the utility refuses to change ACLs when the Spotify/Update path is a junction or symbolic link.

The firewall operation is the only part that requests administrator rights. ACL work remains in the launching user's context.

## Limitations

This is a best-effort measure for the classic per-user Spotify Desktop updater. It does not cover the Microsoft Store package, alternate updater implementations, or a process running as administrator/SYSTEM. The write probe proves that file creation in the configured update directory is denied; it is not a guarantee against every future update mechanism.

The utility does not modify `hosts`, scheduled tasks, Spotify binaries, undocumented update-policy registry values, the parent Spotify folder ACL, or `SYSTEM` permissions.

## License

MIT. See [LICENSE](LICENSE).

Spotify is a trademark of Spotify AB. This project is independent and is not affiliated with or endorsed by Spotify AB.
