#!/usr/bin/env bash
# Native-Nix test for our LineageOS build (build 9+: seccomp for the Nix app,
# /etc/resolv.conf in the image, /usr/bin bind, /dev/shm tmpfs). Run on the PHONE
# in the Nix-on-Droid app after the update:
#     bash /sdcard/Download/nix-native/native-test.sh
# (pushed by `native-setup.sh push`). Writes
# /sdcard/Download/nix-native/native-test.log, which you can read with
#     adb shell cat /sdcard/Download/nix-native/native-test.log
# Read-only apart from the log and a temp dir; fetches python3 from the binary
# cache (also tests DNS + TLS for nix itself).
set -u
LOG=/sdcard/Download/nix-native/native-test.log
exec > >(tee "$LOG") 2>&1
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
sec() { printf '\n== %s\n' "$*"; }
gp() { /system/bin/getprop "$1"; }

sec "environment"
echo "date: $(date -u '+%F %T UTC')"
echo "build: $(gp ro.build.date) | lineage $(gp ro.lineage.version) | slot $(gp ro.boot.slot_suffix)"
echo "ro.nix.package=$(gp ro.nix.package)"
echo "uid: $(id 2>/dev/null || /system/bin/id)"
echo "selinux: $(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')"
tp=$(sed -n 's/^TracerPid:\s*//p' /proc/self/status)
if [ "$tp" = 0 ] && [ -d /nix/files ]; then ok "native session (no proot tracer, /nix = app dir)"
else bad "not native: TracerPid=$tp, /nix/files $( [ -d /nix/files ] && echo present || echo missing) — proot fallback?"; fi
[ -x "$HOME/.nix-profile/bin/bash" ] && ok "home-manager profile has bash" || bad "no bash in ~/.nix-profile"

sec "seccomp (glibc needs these; build 9 allows them for this app only)"
# this bash is a glibc binary: reaching this line already means set_robust_list + rseq pass
ok "glibc bash runs (set_robust_list, rseq at startup)"

sec "/usr/bin/env (bind of /system/bin)"
if [ -x /usr/bin/env ]; then
  ok "/usr/bin/env exists ($(ls -l /usr/bin/env 2>&1 | awk '{print $NF}'))"
  t=$(mktemp -d "${TMPDIR:-/data/data/com.termux.nix/cache}/nt.XXXXXX")
  printf '#!/usr/bin/env sh\necho shebang-ok\n' > "$t/s"; chmod +x "$t/s"
  [ "$("$t/s" 2>&1)" = shebang-ok ] && ok "#!/usr/bin/env script runs" || bad "#!/usr/bin/env script: $("$t/s" 2>&1)"
  rm -rf "$t"
else bad "/usr/bin/env missing"; fi

sec "DNS (/etc/resolv.conf from the image)"
if [ -f /etc/resolv.conf ]; then ok "/etc/resolv.conf: $(grep -c nameserver /etc/resolv.conf) nameservers ($(awk '/nameserver/{printf "%s ",$2}' /etc/resolv.conf))"
else bad "/etc/resolv.conf missing"; fi
ls -ld /data/adb/modules/nix-resolv 2>/dev/null && echo "note: Magisk resolv module still installed (remove after this test)"
if nix store info --store https://cache.nixos.org >/dev/null 2>&1 || nix store ping --store https://cache.nixos.org >/dev/null 2>&1; then
  ok "nix reaches cache.nixos.org (DNS + TLS)"
else bad "nix can't reach cache.nixos.org"; fi

sec "/dev/shm (tmpfs mounted by zygote)"
ls -ldZ /dev/shm 2>&1
grep ' /dev/shm ' /proc/mounts || echo "(no /dev/shm mount line)"
if grep -q ' /dev/shm tmpfs ' /proc/mounts; then ok "/dev/shm is a tmpfs"; else bad "/dev/shm is not a tmpfs"; fi
if f=$(mktemp /dev/shm/nt.XXXXXX 2>/dev/null); then rm -f "$f"; ok "/dev/shm writable"; else bad "/dev/shm not writable"; fi

sec "nix_app domain (build 11+: own SELinux domain, hard links, termios2, phantom killer)"
ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
phantom=$(gp persist.sys.fflag.override.settings_enable_monitor_phantom_procs)
if [ "$phantom" = false ]; then   # the property exists only from build 11 on
  ok "ROM default: phantom process killer off (persist.sys.fflag.override…=false)"
  case "$ctx" in *:nix_app:*) ok "process runs as nix_app ($ctx)";;
    *) bad "process is NOT in the nix_app domain ($ctx) — seinfo/mac_permissions mapping failed? (then no hard links, no prompt)";; esac
  t=$(mktemp -d "${TMPDIR:-/data/data/com.termux.nix/cache}/nt.XXXXXX")
  : > "$t/a"
  if ln "$t/a" "$t/b" 2>"$t/err"; then ok "hard link in app data works (auto-optimise-store possible)"
  else bad "hard link: $(cat "$t/err")"; fi
  rm -rf "$t"
  # coreutils stty is glibc: tcgetattr → TCGETS2 (0x542a); on build 9 this was "Permission denied"
  if out=$(stty -a </dev/tty 2>&1); then ok "termios2 ioctls on the pty (stty -a: $(echo "$out" | head -c 40)…)"
  else bad "termios2 on the pty: $out"; fi
else
  echo "note: build 10 or older (no phantom-killer property) — nix_app checks skipped"
fi

sec "python3 from the binary cache (glibc, threads, syscalls, multiprocessing)"
py=$(nix build --no-link --print-out-paths --inputs-from "$HOME/.config/nix-native" nixpkgs#python3 2>&1 | tail -1)
if [ -x "$py/bin/python3" ]; then
  ok "python3 fetched ($("$py/bin/python3" --version 2>&1))"
  "$py/bin/python3" -I - <<'EOF'
import ctypes, os, signal, subprocess, sys, threading
fails = 0
def r(ok, msg):
    global fails
    fails += not ok
    print(("PASS  " if ok else "FAIL  ") + msg, flush=True)
# each syscall in a child: a seccomp TRAP kills it with SIGSYS (31); any errno = allowed
calls = {"set_robust_list": 99, "rseq": 293, "openat2": 437, "faccessat2": 439, "fchmodat2": 452}
for name, nr in calls.items():
    code = f"import ctypes;ctypes.CDLL(None,use_errno=True).syscall({nr},0,0,0,0)"
    p = subprocess.run([sys.executable, "-I", "-c", code])
    r(p.returncode != -signal.SIGSYS, f"syscall {name} ({nr}): " + ("SIGSYS" if p.returncode == -signal.SIGSYS else f"allowed (exit {p.returncode})"))
t = threading.Thread(target=lambda: None); t.start(); t.join(); r(True, "threads start (rseq per thread)")
try:
    import multiprocessing as mp
    l = mp.Lock(); l.acquire(); l.release()
    from multiprocessing import shared_memory
    s = shared_memory.SharedMemory(create=True, size=4096); s.buf[0] = 42; s.close(); s.unlink()
    with mp.Pool(2) as pool: res = pool.map(abs, [-1, -2, -3])
    r(res == [1, 2, 3], "multiprocessing Lock + SharedMemory + Pool (/dev/shm)")
except Exception as e:
    r(False, f"multiprocessing: {type(e).__name__}: {e}")
import socket
try:
    r(bool(socket.getaddrinfo("cache.nixos.org", 443)), "glibc resolver (getaddrinfo cache.nixos.org)")
except Exception as e:
    r(False, f"glibc resolver: {e}")
sys.exit(fails)
EOF
  fail=$((fail+$?))
else bad "could not fetch python3: $py"; fi

sec "summary"
if [ "$fail" = 0 ]; then echo "ALL PASSED"; else echo "$fail FAILED — see FAIL lines above"; fi
echo "log: $LOG"
