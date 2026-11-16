#!/bin/sh
# POSIX sh on purpose: `bootstrap` runs natively under Android's /system/bin/sh (mksh)
# Native /nix for Nix-on-Droid on our LineageOS build (lineage-rango
# docs/nix-design.md, option Z: zygote binds the app's data dir
# /data/data/com.termux.nix on /nix → the store lives at <appdir>/store).
#
#   on PRO (phone on adb):        phone/native-setup.sh push
#       builds a static nix + CA bundle (aarch64, same as the phone) and pushes
#       them with this flake to /sdcard/Download/nix-native/
#   on the PHONE, Nix-on-Droid's proot session (app freshly bootstrapped):
#       bash /sdcard/Download/nix-native/native-setup.sh install
#       copies everything into the app dir and makes native-login.sh the app's
#       login (Nix-on-Droid's own login kept as login.proot = fallback)
#   then close and reopen the app: the native login runs `bootstrap` once by
#   itself (log: ~/native-bootstrap.log) — builds homeConfigurations.native into
#   the real /nix and activates it; later changes: home-manager switch --flake
#   ~/.config/nix-native#native
set -euo pipefail
# Android's toybox (dirname, mkdir, grep, …): the app's PATH lacks it, and a fresh
# Nix-on-Droid proot env has no grep (2026-11-15: "dirname/grep: not found")
PATH="${PATH:+$PATH:}/system/bin"; export PATH
APP=/data/data/com.termux.nix
SD=/sdcard/Download/nix-native
here=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
push)
  [ "$(uname -m)" = aarch64 ] || { echo "run on an aarch64 Linux machine with Nix"; exit 1; }
  adb get-state >/dev/null || { echo "phone not on adb"; exit 1; }
  nixs=$(nix build --no-link --print-out-paths --inputs-from "$here" nixpkgs#nixStatic | grep -v -- '-man$' | head -1)
  ca=$(nix build --no-link --print-out-paths --inputs-from "$here" nixpkgs#cacert | grep -v -- '-man$' | head -1)
  adb shell "rm -rf $SD && mkdir -p $SD/flake"
  adb push "$(readlink -f "$nixs/bin/nix")" "$SD/nix-static" >/dev/null
  adb push "$ca/etc/ssl/certs/ca-bundle.crt" "$SD/ca-bundle.crt" >/dev/null
  for f in flake.nix flake.lock home.nix native-login.sh native-setup.sh; do
    adb push "$here/$f" "$SD/flake/$f" >/dev/null
  done
  adb push "$here/native-setup.sh" "$SD/native-setup.sh" >/dev/null
  adb push "$here/native-test.sh" "$SD/native-test.sh" >/dev/null
  adb shell "ls -la $SD $SD/flake"
  echo "now on the phone (Nix-on-Droid): bash $SD/native-setup.sh install"
  echo "after the native bootstrap, test: bash $SD/native-test.sh  (log: $SD/native-test.log)" ;;

install)
  # runs inside Nix-on-Droid's proot: /nix here is the PROOT store; the real app
  # dir is reachable under its own path (proot doesn't hide /data)
  [ -d "$APP/files/usr" ] || { echo "Nix-on-Droid not bootstrapped yet"; exit 1; }
  [ -f "$SD/nix-static" ] || { echo "run 'native-setup.sh push' on your computer first"; exit 1; }
  install -m 0755 "$SD/nix-static" "$APP/files/nix-static"
  install -m 0644 "$SD/ca-bundle.crt" "$APP/files/ca-bundle.crt"
  mkdir -p "$APP/files/home/.config/nix-native"
  cp -f "$SD"/flake/* "$APP/files/home/.config/nix-native/"
  # keep Nix-on-Droid's login as the fallback (only the first time — later runs
  # would otherwise save our own login over it)
  # (2026-11-15: a failed grep here once saved our login as login.proot → no fallback)
  mark="Native login for the Nix-on-Droid app"
  if grep -q "$mark" "$APP/files/usr/bin/login"; then
    if [ ! -f "$APP/files/usr/bin/login.proot" ] || grep -q "$mark" "$APP/files/usr/bin/login.proot"; then
      echo "login.proot is missing or is our own login — restore Nix-on-Droid's login first:"
      echo "  nix-on-droid switch --flake ~/.config/nix-on-droid   (then run this install again)"
      exit 1
    fi
  else
    cp -f "$APP/files/usr/bin/login" "$APP/files/usr/bin/login.proot"
  fi
  install -m 0755 "$SD/flake/native-login.sh" "$APP/files/usr/bin/login"
  echo "installed — close the app completely and reopen it" ;;

bootstrap)
  # runs natively (from native-login.sh): /nix is the app dir, empty store
  [ -d /nix/files ] || { echo "/nix is not the app dir — not our build?"; exit 1; }
  export HOME="$APP/files/home" USER=nix-on-droid TMPDIR="$APP/cache"
  export NIX_SSL_CERT_FILE="$APP/files/ca-bundle.crt"
  mkdir -p "$TMPDIR" "$APP/files/bin"
  ln -sf "$APP/files/nix-static" "$APP/files/bin/nix"
  for c in nix-env nix-store nix-build nix-instantiate nix-channel; do ln -sf nix "$APP/files/bin/$c"; done
  export PATH="$APP/files/bin:/system/bin"
  # single-user, no user namespaces → no sandbox; apps may not hard-link →
  # never optimise (home.nix sets the same in ~/.config/nix/nix.conf later)
  # the store at /nix/store = <appdir>/store: create it first — a static nix with
  # no /nix/var/nix silently falls back to a chroot store in
  # ~/.local/share/nix/root, which needs user namespaces (none on the phone)
  mkdir -p /nix/store /nix/var/nix
  # ~/.nix-profile (home is shared with the proot session) points at the legacy
  # per-user profile path; in the fresh native /nix it doesn't exist → nix-env in
  # home-manager's installPackages failed "opening lock file …/per-user/nix-on-droid/
  # profile.lock: No such file or directory" (build 9, 2026-11-15)
  mkdir -p "/nix/var/nix/profiles/per-user/$USER" "/nix/var/nix/gcroots/per-user/$USER"
  export NIX_CONFIG="store = local
experimental-features = nix-command flakes
sandbox = false
build-users-group =
auto-optimise-store = false"
  echo "building the native home configuration (downloads ~1 GB from cache.nixos.org)…"
  nix build --out-link "$TMPDIR/hm" "$HOME/.config/nix-native#homeConfigurations.native.activationPackage"
  "$TMPDIR/hm/activate"
  rm -f "$TMPDIR/hm"
  echo "native setup done" ;;

*) sed -n '2,20p' "$0"; exit 1 ;;
esac
