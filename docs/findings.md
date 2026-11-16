# Findings: running Nix natively in an Android app

Each obstacle as it showed up on a real device (Pixel 10 Pro Fold, LineageOS 24 /
Android 17, kernel 6.6 GKI, glibc 2.42 from nixpkgs 26.05), what caused it, and why the
fix is the narrowest that works. Several of these also explain long-standing
Nix-on-Droid issues.

## 1. There is no way to get `/nix` from inside an app

- The root image is read-only and dm-verity-protected → a `/nix` mountpoint must exist
  at **build time** (`PRODUCT_COPY_FILES … $(TARGET_COPY_OUT_ROOT)/nix/README`).
- Apps have no capabilities and, on stock GKI kernels, **no user namespaces**
  (`CONFIG_USER_NS` off) → no `unshare`, no own mount namespace, no chroot store
  (`~/.local/share/nix/root` needs userns; the static nix silently falls back to it
  if `/nix/var/nix` doesn't exist).
- SELinux decides the rest: only app domains may execute files stored on `/data`; only
  zygote (and run-as/simpleperf) may start a process in an app domain; an untrusted app
  may create files only as `app_data_file`. → A root daemon can't run store code or
  hand a process to an app. **The only place to set it up is zygote**, which already
  builds a mount namespace per app: one more bind mount of the app's own data dir onto
  `/nix`, for the one configured package. The store stays ordinary app data.

## 2. "Unknown signal 31" — the seccomp filter (nix-on-droid#252)

Every nixpkgs (glibc) program died at startup with SIGSYS. Android's app seccomp
filter (bionic `SYSCALLS.TXT` + allowlists, default action TRAP) lacks system calls
glibc 2.42 makes:

- `set_robust_list`, `rseq` — inside ld.so, in every program, before any LD_PRELOAD
  could intervene;
- `faccessat2` — `faccessat()` tries it first (bash's `[ -x ]`);
- `fchmodat2` — `fchmodat()` with `AT_SYMLINK_NOFOLLOW`;
- `openat2` — Go's `os.Root`, newer Rust/systemd (an ENOSYS fallback exists, but SIGSYS
  kills first).

An app can only tighten its own filter, never loosen it, so the fix is a second app
filter (stock + those five) that zygote installs only for the configured app.
Deliberately **not** added: io_uring, SysV IPC, landlock, futex2, NUMA calls.

## 3. No prompt, and "getting pseudoterminal attributes: Permission denied"

glibc ≥ 2.42 implements `tcgetattr`/`tcsetattr` with the termios2 ioctls
`TCGETS2`/`TCSETS2`/`TCSETSW2`/`TCSETSF2` (0x542a–0x542d). Android's policy allows apps
only the classic `TCGETS`/`TCSETS*` on their ptys. Effects: `isatty()` fails → bash
starts **non-interactive** (no prompt, no line editing, but commands still run); Nix's
builder aborts. **The denial is not logged.** Likely also the real cause behind
nix-on-droid#495 under proot.

Trap we fell into: app ptys are not labelled `devpts` but **`untrusted_app_all_devpts`**
(AOSP's `create_pty(untrusted_app_all)`). A rule on `devpts` compiles fine and does
nothing. Fix: `allowxperm nix_app untrusted_app_all_devpts:chr_file ioctl { TCGETS2 …
TCSETSF2 }`. The only pty neverallow is `TIOCSTI`.

Workaround without a ROM change: a static **musl** Nix (`pkgs.nixStatic`) still uses
`TCGETS`.

## 4. Hard links: forbidden, and silently

`neverallow all_untrusted_apps file_type:file link` — on purpose (installd must be able
to delete app files; hard links feature in exploits). No denial is logged. Effects:
`auto-optimise-store` breaks the store, local builds that create links fail, and —
less obvious — **glibc's `sem_open()` creates a temp file in `/dev/shm` and `link()`s
it**, so Python `multiprocessing` fails with `PermissionError` even once `/dev/shm`
exists.

Allowing it needs the platform policy itself: a dedicated `nix_app` domain (same rules
as the app's normal `untrusted_app_27`, every one of its neverallow exceptions
mirrored), the neverallow changed to `{ all_untrusted_apps -nix_app }`, and `nix_app`
limited to linking `app_data_file`. Android requires a per-package domain for a normal
app to be tied to a non-default `seinfo` — i.e. to the app's **signing key** via
`mac_permissions.xml`, which is what you want anyway.

## 5. `/dev/shm`

Android has none, so `shm_open`/`sem_open` fail. init creates an empty `/dev/shm`;
zygote mounts a private tmpfs for the app with `context=` the app data dir's label
(app_data_file + the app's MLS categories — the only label an untrusted app may create
files with). A `context=` mount checks `relabelfrom` **and** `mount` against the new
label: `allow zygote app_data_file:filesystem { mount relabelfrom relabelto }` (domain.te's
filesystem neverallow exempts zygote).

## 6. The phantom process killer

Android 12+ kills an app's child processes once there are more than 32 (or on heavy
background CPU): `Killing PhantomProcessRecord … Trimming phantom processes`. On test it
killed 40 background processes **and the session's bash** at once ("[Process completed
(signal 9)]"), even with the app in the foreground. The global switch
(`settings_enable_monitor_phantom_procs`, read from `Settings.Global`, then
`persist.sys.fflag.override.*`) stops it; the ROM ships the property as default.

## 7. Smaller things

- `#!/usr/bin/env`: no `/usr` — zygote binds `/system/bin` (toybox) on `/usr/bin` for
  the app.
- DNS: glibc/musl read only `/etc/resolv.conf`, which Android doesn't have (apps use
  netd).
- No passwd entry for the app UID: OpenSSH refuses to run → `nss_wrapper` for the ssh
  tools only.
- `/proc/stat` is closed to apps (side channel): Boehm GC (in Nix) warns on every call
  → `GC_NPROCS`.
- No `/run`, no writable `/tmp` → `XDG_RUNTIME_DIR`, `TMPDIR`, `TMUX_TMPDIR` in the
  app's cache dir. (Zygote may not mount over Android's `/tmp`.)
- Debugging tip: audit "granted" messages for `execute_no_trans` on app data can rotate
  logcat's main buffer within minutes and hide the app's start; `nix_app` drops that
  `auditallow`.
