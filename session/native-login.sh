#!/system/bin/sh
# Native login for the Nix-on-Droid app on our LineageOS build (lineage-rango
# docs/nix-design.md): the app executes $PREFIX/bin/login
# (= /data/data/com.termux.nix/files/usr/bin/login); this replaces Nix-on-Droid's
# proot login, which is kept as login.proot and used whenever the native setup
# isn't there (official LineageOS, store not bootstrapped yet, or NIX_NATIVE=0).
# Native = zygote bound the app's data dir on /nix (ro.nix.package), so /nix/files
# exists, and home-manager's profile has a bash.
# Installed by phone/native-setup.sh. Note: a proot `nix-on-droid switch`
# rewrites files/usr/bin/login — rerun native-setup.sh install-login afterwards.
APP=/data/data/com.termux.nix
export USER=nix-on-droid
export HOME="$APP/files/home"
export TMPDIR="$APP/cache"
export LANG=C.UTF-8
P="$HOME/.nix-profile"
# passwd/group entries for nss_wrapper (ssh needs one; Android has none for app
# UIDs) — rewritten at every start, the UID changes when the app is reinstalled
nss() {
  # runtime dir (XDG_RUNTIME_DIR, TMUX_TMPDIR in flake.nix); Android may clear the cache
  /system/bin/mkdir -p "$TMPDIR/run" && /system/bin/chmod 700 "$TMPDIR/run"
  /system/bin/mkdir -p "$HOME/.config/nss"
  echo "$USER:x:$(/system/bin/id -u):$(/system/bin/id -g):Nix-on-Droid:$HOME:$P/bin/bash" > "$HOME/.config/nss/passwd"
  echo "$USER:x:$(/system/bin/id -g):" > "$HOME/.config/nss/group"
}
if [ "${NIX_NATIVE:-1}" != 0 ] && [ -d /nix/files ] && [ -d /nix/store ] && [ -x "$P/bin/bash" ]; then
  nss
  export PATH="$P/bin:$APP/files/bin:/system/bin"  # files/bin = static nix from the bootstrap (fallback)
  # home-manager's session variables (NIX_SSL_CERT_FILE, TZ, …) come from
  # ~/.profile, which a login bash reads
  exec "$P/bin/bash" -l "$@"
fi
# our build, store not bootstrapped yet, static nix installed → bootstrap once
S="$HOME/.config/nix-native/native-setup.sh"
if [ "${NIX_NATIVE:-1}" != 0 ] && [ -d /nix/files ] && [ ! -x "$P/bin/bash" ] && [ -x "$APP/files/nix-static" ] && [ -f "$S" ]; then
  echo "native /nix found, setting it up (log: $HOME/native-bootstrap.log)…"
  if PATH=/system/bin /system/bin/sh "$S" bootstrap 2>&1 | /system/bin/tee "$HOME/native-bootstrap.log" && [ -x "$P/bin/bash" ]; then
    nss
    export PATH="$P/bin:$APP/files/bin:/system/bin"  # files/bin = static nix from the bootstrap (fallback)
    exec "$P/bin/bash" -l "$@"
  fi
  echo "native bootstrap failed — starting the proot session; see $HOME/native-bootstrap.log"
fi
exec "$APP/files/usr/bin/login.proot" "$@"
