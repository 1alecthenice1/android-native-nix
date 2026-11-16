#!/usr/bin/env bash
# Native /nix vs proot on the phone — same tests in both sessions:
#   native:  bash /sdcard/Download/nix-native/bench.sh
#   proot:   NIX_NATIVE=0 $PREFIX/bin/login    (from the native shell: starts the old
#            proot session inside it), then the same command; `exit` returns
# Log: /sdcard/Download/nix-native/bench-<native|proot>.log (pro: adb shell cat …)
# Each test: 1 warm-up run (fetches packages from the binary cache), then 5 timed
# runs; the median is reported. FULL=1 also rebuilds GNU hello from source.
set -u
tp=$(sed -n 's/^TracerPid:\s*//p' /proc/self/status)
mode=$([ "$tp" = 0 ] && echo native || echo proot)
d=/sdcard/Download/nix-native; [ -w "$d" ] || d=/android/sdcard/Download/nix-native  # proot binds / at /android
LOG=$d/bench-$mode.log
exec > >(tee "$LOG") 2>&1
flake=$HOME/.config/nix-native   # home is shared by both sessions: same nixpkgs pin for both
echo "mode: $mode   date: $(date -u '+%F %T UTC')   build: $( { /system/bin/getprop ro.build.date || /android/system/bin/getprop ro.build.date; } 2>/dev/null)"
echo "nix: $(nix --version)   flake for package pins: $flake"

pkg() { nix build --no-link --print-out-paths --inputs-from "$flake" "nixpkgs#$1" 2>/dev/null | grep -v -- '-man$' | head -1; }
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
t() {  # t <label> <command…>: warm-up, then median of 5 wall-clock seconds
  local label=$1; shift
  "$@" >/dev/null 2>&1
  local i s e
  for i in 1 2 3 4 5; do
    s=$(date +%s.%N); "$@" >/dev/null 2>&1; e=$(date +%s.%N)
    awk "BEGIN{print $e-$s}"
  done | median | xargs printf "%-44s %8.3f s\n" "$label"
}

echo "fetching test packages (first run per session downloads them)…"
emacs=$(pkg emacs-nox); py=$(pkg python3); hello=$(pkg hello)
[ -x "$emacs/bin/emacs" ] && [ -x "$py/bin/python3" ] || { echo "package fetch failed"; exit 1; }

echo
echo "== results (median of 5, wall clock)"
t "bash login shell start + exit"            bash -lic exit
t "python3 -c pass"                          "$py/bin/python3" -I -c pass
t "emacs -Q --batch (start + quit)"          "$emacs/bin/emacs" -Q --batch --eval '(kill-emacs)'
t "emacs --batch: load org-mode"             "$emacs/bin/emacs" -Q --batch --eval '(progn (require (quote org)) (kill-emacs))'
t "nix eval nixpkgs#hello.version"           nix eval --inputs-from "$flake" nixpkgs#hello.version
t "find over the store (stat-heavy)"         sh -c 'find /nix/store -maxdepth 2 | wc -l'
t "hello (tiny binary, exec latency)"        "$hello/bin/hello"
if [ "${FULL:-0}" = 1 ]; then
  echo "== local build: GNU hello from source (one run)"
  s=$(date +%s); nix build --no-link --rebuild --inputs-from "$flake" nixpkgs#hello && echo "rebuild hello: $(( $(date +%s) - s )) s"
fi
echo
echo "log: $LOG"
