# ghostcopy-bin (AUR)

`ghostcopy-bin/` is the AUR package, kept here so it is reviewed like any other
code. The AUR repository is a copy of `PKGBUILD` and `.SRCINFO` from this
directory; edit here first, never only on the AUR.

It repackages the published `linux-v<version>+<build>` tarball system-wide:

| Path | What |
|---|---|
| `/opt/ghostcopy/` | The release bundle, minus `linux_update.py` |
| `/usr/bin/ghostcopy-desktop` | The GUI (launcher script) |
| `/usr/bin/ghostcopy` | The CLI/MCP companion (launcher script) |
| `/usr/bin/ghostcopy-send` | One `--send-file` per argument, for Dolphin |
| `/usr/share/applications/com.ghostcopy.ghostcopy.desktop` | Menu entry and the `ghostcopy://` sign-in handler |
| `/usr/share/kio/servicemenus/com.ghostcopy.ghostcopy.send.desktop` | Send with GhostCopy in Dolphin |

Everything under `/usr` except the icon and licenses is written by the
tarball's `linux_integration.py`, the same definition `install_linux.py` and
the in-app updater use, so the package never drifts from a per-user install.
Change those files there, not in the PKGBUILD. Releases up to
1.0.9+25 do not carry it, so the PKGBUILD cannot build those.

## Updates belong to pacman

`LinuxAppUpdateService` only enables itself when `install-manifest.json` and
`linux_update.py` sit next to the executable. The package installs neither, so
the in-app updater is off and the tray hides its update items (from 1.0.10 on;
1.0.9 still shows a Check for Updates item that explains it is unavailable).
Never ship either file in the package: the updater would try to replace
`/opt/ghostcopy`, which pacman owns.

## Per-user installs

`install_linux.py` puts a desktop entry with the same ID in
`~/.local/share/applications`, which wins over the package's. Anyone switching
to the AUR package should first run, from an extracted release:

```sh
python3 install_linux.py --uninstall
```

Account data and credentials are kept either way.

## Releasing a new version

After `linux-v<version>+<build>` is published (see `docs/linux-cachyos.md`):

```sh
installer/linux/aur/update-pkgbuild.sh 1.0.10 26
cd installer/linux/aur/ghostcopy-bin && makepkg -f && cd -
```

Commit the change here, then copy it to the AUR:

```sh
git clone ssh://aur@aur.archlinux.org/ghostcopy-bin.git /tmp/ghostcopy-bin-aur
cp installer/linux/aur/ghostcopy-bin/{PKGBUILD,.SRCINFO} /tmp/ghostcopy-bin-aur/
cd /tmp/ghostcopy-bin-aur && git add PKGBUILD .SRCINFO \
  && git commit -m "Update to 1.0.10+26" && git push
```

The first push creates the package. Pushing needs an AUR account with this
machine's SSH public key added under My Account → SSH Public Key.

## Checks before publishing

- `makepkg -f` builds without errors and the package has no `linux_update.py`
  or `install-manifest.json`.
- `depends` matches the bundle's direct ELF dependencies. `libdartjni.so` links
  `libjvm.so` but the app never loads it, so no JDK belongs there.
- The app starts from a read-only copy of `/opt/ghostcopy` (`chmod -R a-w`);
  it writes nothing next to the executable (Sentry uses `~/.cache/GhostCopy`).
