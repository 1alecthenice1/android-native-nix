# android-native-nix

A real `/nix/store` for one app on a **locked, verified-boot** Android — Nix without
proot. Platform patches + SELinux policy for AOSP/LineageOS-based ROMs, and a
session setup for the [Nix-on-Droid](https://github.com/nix-community/nix-on-droid)
app as the terminal.

Tested on a Pixel 10 Pro Fold (rango) running LineageOS 24 (Android 17), bootloader
relocked with our own key. Built and verified on the phone: glibc programs, Nix
local builds, `home-manager switch`, Python multiprocessing, a normal interactive
bash. The device build this comes from: [lineage-rango](#related).

## Why

Nix-on-Droid runs Nix inside proot, which traces every system call: slow (shell
startups measured in seconds, Emacs in minutes — see nix-on-droid#192), fragile, and
it fakes hard links. Running natively needs things an Android app can't do on its
own: a `/nix` path, system calls the app seccomp filter kills, terminal ioctls the
SELinux policy blocks, hard links, `/dev/shm`. Only the ROM can grant them — and it
can grant them to **one app** without weakening the rest of the system.

## What the ROM does

| Problem natively | Fix | Where |
|---|---|---|
| no `/nix` (read-only, verified root) | empty mountpoint in the root image; zygote bind-mounts the app's own data dir on `/nix` **in that app's mount namespace only** | `frameworks/base` 0001, `native-nix.mk` |
| glibc programs die with SIGSYS ("Unknown signal 31", nix-on-droid#252): the app seccomp filter lacks `set_robust_list`, `rseq`, `faccessat2`, `fchmodat2`, `openat2` | a second app filter with those five, used only for that app | `bionic` 0001, `frameworks/base` 0002 |
| `#!/usr/bin/env` scripts: no `/usr` | zygote binds `/system/bin` on an empty `/usr/bin` mountpoint (app only) | `frameworks/base` 0003 |
| no `/dev/shm` (`sem_open`, `shm_open`, Python multiprocessing) | private 1 GB tmpfs, app-owned, labelled like the app's data | `frameworks/base` 0004, `nix.rc`, `nix.te` |
| no prompt / line editing, Nix builder "getting pseudoterminal attributes": glibc ≥ 2.42 uses `TCGETS2`…`TCSETSF2`, not in Android's pty ioctl allowlist | allowed on the app's own ptys (`untrusted_app_all_devpts`) | `system/sepolicy` 0001 |
| hard links forbidden for all untrusted apps (and glibc's `sem_open` needs `link()`) | allowed **only within the app's own data** | `system/sepolicy` 0001 |
| phantom process killer kills child processes above 32 (and the shell with them) | off by default | `native-nix.mk` |
| no `/etc/resolv.conf` for glibc/musl resolvers | shipped in `/system/etc` | `native-nix.mk` |

The extra SELinux rights live in a dedicated domain **`nix_app`**, assigned only to the
package named in `ro.nix.package` **and** signed with the key pinned in
`mac_permissions.xml` (Nix-on-Droid's F-Droid key by default). Every other app — and
another build of the same package with a different key — keeps Android's stock rules.

## Security model, honestly

- No root anywhere, no daemon, no neverallow disabled; the bootloader stays locked.
  The Nix store is ordinary app data: encrypted with the user's credentials, removed
  with the app, invisible to other apps.
- What is relaxed, for that one app: five syscalls in its seccomp filter, terminal
  ioctls on its own ptys, hard links inside its own data, `/dev/shm`. Android forbids
  hard links for untrusted apps partly because installd must be able to delete an
  app's files reliably; links confined to the app's own data dir don't escape it, but
  this is still a deliberate change to AOSP hardening — weigh it.
- Nix runs single-user, without a build sandbox (no user namespaces on Android).
- Whoever controls the pinned signing key controls what runs in `nix_app`. Pin a key
  you trust; to use your own Nix-on-Droid build, put its certificate in
  `sepolicy/certs/` and `keys.conf`.

## Use it

ROM side (AOSP/LineageOS tree, tested on lineage-24.0):

```
git clone <this repo> vendor/native-nix          # into the tree root
vendor/native-nix/apply-patches.sh .             # bionic, frameworks/base, system/sepolicy
# in your device/product makefile:
$(call inherit-product, vendor/native-nix/native-nix.mk)
```

Phone side, after flashing (Nix-on-Droid installed and bootstrapped once as usual):

```
session/native-setup.sh push                                   # computer, phone on adb
bash /sdcard/Download/nix-native/native-setup.sh install       # in the app (proot)
# close and reopen the app: the native login bootstraps /nix once (~1 GB download)
bash /sdcard/Download/nix-native/native-test.sh                # check everything
```

`session/` has the login (falls back to proot if anything is missing), the setup
script, an example home-manager flake, and the test (`ALL PASSED` expected; each FAIL
names the missing piece).

## Status and limits

- Device-independent in principle (zygote, bionic, sepolicy are generic); tested on one
  device and one Android version so far. Reports from other devices welcome.
- User 0 only; one package; no build sandbox; `/proc/stat` stays closed (top/htop show
  no CPU totals; set `GC_NPROCS` for Nix's GC).
- `docs/findings.md` lists every obstacle, how it showed up, and why each fix is the
  narrowest one that works — useful even without a custom ROM.

## Related

- lineage-rango — the full device build (signing with own keys, relock, OTA updates)
  this is extracted from.
- nix-on-droid#252 (rooted bind mounts → "Unknown signal 31"), #192 (removing proot).

## Licence

Apache-2.0 (like the AOSP code the patches touch).
