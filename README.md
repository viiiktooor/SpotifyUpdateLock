# Spotify Update Lock

A small Windows batch utility for preventing Spotify Desktop's built-in updater from immediately replacing an intentionally installed older build.

The project is designed around a two-stage workflow: protect first, install second, then convert the temporary protection into a persistent updater-directory lock.

## How it works

`PREPARE` is intended to be run **before** installing or launching the target Spotify build. It creates the expected updater directory if needed, stores its original NTFS ACL, adds an explicit deny rule for the current user against write/delete operations in that updater directory, and creates a temporary Windows Firewall outbound rule for Spotify's standard executable path.

The purpose of the temporary firewall rule is to cover the short window between installation and final verification. If the installer launches Spotify automatically, the expected executable cannot establish outbound connections until the lock is finalized.

`LOCK` is run after installation. It terminates Spotify if it is running, confirms that the expected executable exists, displays its product/file version, verifies the updater-directory ACL, and then removes the temporary firewall rule. Spotify can then access the network normally while its updater directory remains write-protected for the current user.

`STATUS` performs diagnostics only. It reports the executable path and version, process state, updater-directory state, matching deny ACL entries, ACL-backup state, and temporary firewall-rule state.

`UNLOCK` removes the firewall rule created by this utility and restores the exact ACL that was captured before protection was applied. If the utility itself created an empty updater directory, it attempts to remove it. It does not delete unrelated registry keys or reset permissions generically.

## Usage

Run `SpotifyUpdateLock.bat`. The script requests administrator elevation once and then keeps the same elevated console open.

Use the menu in this order:

1. Choose `PREPARE` before installing the desired Spotify build.
2. Install the desired Spotify Desktop build while keeping the script window open.
3. Return to the same window and choose `LOCK` before using Spotify normally.
4. Use `STATUS` whenever you want to inspect the protection state.
5. Use `UNLOCK` to restore the saved ACL and remove this utility's firewall rule.

The same actions can also be called directly:

```bat
SpotifyUpdateLock.bat PREPARE
SpotifyUpdateLock.bat LOCK
SpotifyUpdateLock.bat STATUS
SpotifyUpdateLock.bat UNLOCK
```

## What it changes

The utility changes only the following categories of state:

- `%LOCALAPPDATA%\Spotify\Update` and its NTFS ACL;
- a small state directory under `%LOCALAPPDATA%\SpotifyUpdateLock` used to store the original ACL and flags;
- one named outbound Windows Firewall rule used temporarily during the installation window.

It does **not** modify the Windows `hosts` file, create scheduled tasks, download executables, patch Spotify binaries, add undocumented update-policy registry values, or add an ACL deny entry for `SYSTEM`.

## Target paths

The current script targets the standard per-user Spotify Desktop installation:

```bat
set "APP_PROCESS=Spotify.exe"
set "APP_EXE=%APPDATA%\Spotify\Spotify.exe"
set "UPDATE_DIR=%LOCALAPPDATA%\Spotify\Update"
```

## Limitations

This approach assumes a traditional per-user Windows Spotify Desktop installation whose updater relies on the configured update directory. Microsoft Store installations, alternate install locations, future updater implementations, or installers that perform their own network update before `Spotify.exe` is installed may behave differently.

The batch file has been statically reviewed, but this repository does not claim compatibility with every Spotify client version or Windows configuration. Review the source before running administrative scripts on your system.

## Independence and trademarks

This is an independent third-party utility. It is not affiliated with, endorsed by, sponsored by, maintained by, or officially connected with Spotify AB.

Spotify and related product names and trademarks are the property of their respective owners. References here exist solely to identify the software with which this utility interoperates.

## License

Released under the [MIT License](LICENSE).
