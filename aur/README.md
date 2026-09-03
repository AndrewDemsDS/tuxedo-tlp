# AUR packaging

`PKGBUILD` + `.SRCINFO` for `tuxedo-tlp-git`, a VCS package tracking this repo's `main`
branch. Kept here as the source of truth; the actual AUR submission is a separate git
history at `ssh://aur@aur.archlinux.org/tuxedo-tlp-git.git`.

Depends on `tlp` and `tuxedo-drivers-dkms` (hard dependency: the plugin is inert without
it). The install scriptlet (`tuxedo-tlp-git.install`) best-effort swaps `uniwill_laptop`
for `uniwill_wmi` at install time so the `charging_profile` sysfs node is usable
immediately, no reboot required, on a system where `tuxedo-drivers-dkms` was already
present. On a from-scratch install in the same transaction, or if the live swap can't
bind (e.g. the hotkey input device is busy), it falls back to telling the user to
reboot, which is fully sufficient because `tuxedo-drivers-dkms` ships the
`uniwill_laptop` blacklist that makes the correct module win at next boot anyway.

## Publish / update

```sh
cd aur/
makepkg --printsrcinfo > .SRCINFO   # after any PKGBUILD edit
```

Push to AUR (requires an AUR account with this machine's SSH key
`~/.ssh/id_ed25519.pub` added under Account &gt; My Account &gt; SSH Public Key at
https://aur.archlinux.org/):

```sh
git clone ssh://aur@aur.archlinux.org/tuxedo-tlp-git.git /tmp/aur-tuxedo-tlp-git
cp PKGBUILD .SRCINFO tuxedo-tlp-git.install /tmp/aur-tuxedo-tlp-git/
cd /tmp/aur-tuxedo-tlp-git
git add -A && git commit -m "..." && git push
```

Test a full build + install locally first with `makepkg -fi` before pushing.
