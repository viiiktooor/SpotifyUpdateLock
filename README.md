# Desktop Update Lock

A small Windows batch utility for preventing a desktop application's built-in updater from immediately replacing an intentionally installed older build.

The project is designed around a two-stage workflow: protect first, install second, then convert the temporary protection into a persistent updater-directory lock.

## How it works

`PREPARE` is intended to be run **before** installing or launching the target build. It creates the expected updater directory if needed, stores its original NTFS ACL, adds an explicit deny rule for the current user against write/delete operations in that updater directory, and creates a temporary Windows Firewall outbound rule for the application's standard executable path.

The purpose of the temporary firewall rule is to cover the short window between installation and final verification. If the installer launches the application automatically, the expected executable cannot establish outbound connections until the lock is finalized.

`LOCK` is run after installation. It terminates the target process if it is running, confirms that the expected executable exists, displays its product/file version, verifies the updater-directory ACL, and then removes the temporary firewall rule. The application can then access the network normally while its updater directory remains write-protected for the current user.

`STATUS` performs diagnostics only. It reports the executable path and version, process state, updater-directory state, matching deny ACL entries, ACL-backup state, and temporary firewall-rule state.

`UNLOCK` removes the firewall rule created by this utility and restores the exact ACL that was captured before protection was applied. If the utility itself created an empty updater directory, it attempts to remove it. It does not delete unrelated registry keys or reset permissions generically.

## Usage

Run `DesktopUpdateLock.bat`. The script requests administrator elevation once and then keeps the same elevated console open.

Use the menu in this order:

1. Choose `PREPARE` before installing the target build.
2. Install the desired desktop build while keeping the script window open.
3. Return to the same window and choose `LOCK` before using the application normally.
4. Use `STATUS` whenever you want to inspect the protection state.
5. Use `UNLOCK` to restore the saved ACL and remove this utility's firewall rule.

The same actions can also be called directly:

```bat
DesktopUpdateLock.bat PREPARE
DesktopUpdateLock.bat LOCK
DesktopUpdateLock.bat STATUS
DesktopUpdateLock.bat UNLOCK
```

## What it changes

The utility changes only the following categories of state:

- the target updater directory and its NTFS ACL;
- a small state directory under `%LOCALAPPDATA%\DesktopUpdateLock` used to store the original ACL and flags;
- one named outbound Windows Firewall rule used temporarily during the installation window.

It does **not** modify the Windows `hosts` file, create scheduled tasks, download executables, patch application binaries, add undocumented update-policy registry values, or add an ACL deny entry for `SYSTEM`.

## Target configuration

The target executable and updater paths are intentionally isolated near the beginning of the batch file:

```bat
set "APP_PROCESS=..."
set "APP_EXE=..."
set "UPDATE_DIR=..."
```

This keeps the update-control logic separate from the application-specific paths and makes the script straightforward to audit or adapt.

## Limitations

This approach assumes a traditional per-user Windows desktop installation whose updater relies on the configured update directory. Packaged/store installations, alternate install locations, future updater implementations, or installers that perform their own network update before the target executable is installed may behave differently.

The batch file has been statically reviewed, but this repository does not claim compatibility with every client version or Windows configuration. Review the source before running administrative scripts on your system.

## Independence and trademarks

This is an independent third-party utility. It is not affiliated with, endorsed by, sponsored by, maintained by, or officially connected with any software vendor whose executable names, directory names, or trademarks may appear in the source code.

Any product names or trademarks referenced in source paths exist solely to identify interoperability or compatibility targets. All such trademarks remain the property of their respective owners.

## License

Released under the [MIT License](LICENSE).
