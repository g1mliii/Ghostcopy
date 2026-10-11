# GhostCopy packaging

One directory per platform, plus the symbol upload they share.

| Path | What it packages |
|------|------------------|
| [`windows/`](windows/) | The Microsoft Store MSIX |
| [`macos/`](macos/README.md) | The signed, notarized drag-to-Applications DMG |
| [`ios/`](ios/) | The TestFlight / App Store build |
| `upload-debug-symbols.sh` | dSYMs to Sentry, called by the macOS and iOS builds |

## Windows

**Store only.** `installer/windows/build-store.ps1` does the whole release:
builds, uploads the PDBs to Sentry, compiles the CLI/MCP companion, then packages. Its header carries the
one-time setup - sentry-cli, and the auth token via `set-sentry-token.ps1`.

```powershell
installer\windows\build-store.ps1
```

The package's identity, capabilities and everything it registers with Windows
live in `msix_config` in `pubspec.yaml`. The console execution alias is added by
`windows/set-cli-alias.ps1` between `msix:build` and `msix:pack`: the package's
standard `execution_alias` option would incorrectly target the GUI.
The companion registers a classic desktop execution alias under the existing visible GUI application. Its executable uses the console PE subsystem, so CLI/MCP pipes work without a hidden application or a Store headless waiver.

Starting with MSIX **1.0.22.0**, the payload contains `ghostcopy-agent.exe` and
registers **ghostcopy.exe** as its console alias. Windows manages the alias in
`%LOCALAPPDATA%\Microsoft\WindowsApps`; users do not need an SDK or a PATH edit.
The original `ghostcopy.exe` GUI, app identity, OAuth handler, startup task,
notifications and Explorer menu remain registered to the GUI.

After updating from the Store, open a new terminal and run `ghostcopy --help`.
Enable **Settings → Command line & AI tools** in GhostCopy to allow sends and
device listing. For an MCP client, use the fully expanded path to
`%LOCALAPPDATA%\Microsoft\WindowsApps\ghostcopy.exe` with argument `mcp`.
Never configure the GUI's executable inside the versioned WindowsApps package.
If the command is missing, check Windows Settings → Apps → Advanced app settings
→ App execution aliases and enable GhostCopy's alias.

`windows/package-store.ps1` packages an existing GUI build without uploading
symbols; it is used by CI, not as a substitute for the release script.
`windows/verify-store-package.ps1` checks the final MSIX for the console PE,
alias, original registrations, and absence of PDBs. Do not run `msix:create`
after these scripts: it regenerates the manifest and removes the custom alias.
With Windows Developer Mode already enabled, the optional
`test/windows/cli_alias_registration_test.ps1 -PackagePath <path-to-msix>`
registers a disposable package and unique alias, tests help/MCP pipes/exit codes,
and removes it without changing the installed GhostCopy app or its alias.

### There is no .exe installer any more

`ghostcopy.iss` and `build-installer.bat` are gone, along with
`installer/ghostcopy.ico`. Inno Setup was the alternative to the Store and it
lost on the one thing that matters for a small app: SmartScreen reputation
accrues **per code-signing certificate**, and unsigned it accrues **per file
hash** - so every release and every auto-update re-triggers the warning for
every user. The Store signs each package with Microsoft's certificate and
carries updates, which also removed the need for a certificate and for the
WinSparkle half of the updater.

Two things it used to do are now the manifest's job, and neither is optional:
the `ghostcopy://` protocol and the Run key for launch at startup. See the
Windows table in [`CLAUDE.md`](../CLAUDE.md).

Nothing in the app depends on having been installed by an installer - the
unpackaged build still registers itself in `HKCU` on first run, which is what
`flutter run -d windows` and a build from `build/` rely on.
