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
builds, uploads the PDBs to Sentry, then packages. Its header carries the
one-time setup - sentry-cli, and the auth token via `set-sentry-token.ps1`.

```powershell
installer\windows\build-store.ps1
```

The package's identity, capabilities and everything it registers with Windows
live in `msix_config` in `pubspec.yaml`, not here.

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
