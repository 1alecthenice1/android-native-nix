# android-native-nix — include from your device/product makefile:
#   $(call inherit-product, vendor/native-nix/native-nix.mk)
# and apply patches/ to bionic, frameworks/base and system/sepolicy (apply-patches.sh).
#
# The one app that gets a native /nix. Its data dir is bind-mounted on /nix in its own
# mount namespace by zygote. Empty = feature off. The SELinux nix_app domain is
# additionally pinned to the app's signing key (sepolicy/private/mac_permissions.xml).
NATIVE_NIX_PACKAGE ?= com.termux.nix
PRODUCT_SYSTEM_EXT_PROPERTIES += ro.nix.package=$(NATIVE_NIX_PACKAGE)

# Mountpoints in the verified root image (dm-verity: they must exist at build time)
PRODUCT_COPY_FILES += \
    vendor/native-nix/nix/README:$(TARGET_COPY_OUT_ROOT)/nix/README \
    vendor/native-nix/usr-bin/README:$(TARGET_COPY_OUT_ROOT)/usr/bin/README
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += root/nix/README root/usr/bin/README

# /dev/shm mountpoint (init); zygote mounts a private tmpfs there for the app only
PRODUCT_COPY_FILES += vendor/native-nix/nix/nix.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/nix.rc
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/etc/init/nix.rc

# /etc/resolv.conf for glibc/musl programs
PRODUCT_COPY_FILES += vendor/native-nix/nix/resolv.conf:$(TARGET_COPY_OUT_SYSTEM)/etc/resolv.conf
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/etc/resolv.conf

# Android 12+ "phantom process killer" kills app child processes above 32 — it took
# down parallel `nix build`s and the session's own shell. Off by default (same as the
# developer option "Disable child process restrictions"; a Settings.Global value wins).
PRODUCT_SYSTEM_EXT_PROPERTIES += persist.sys.fflag.override.settings_enable_monitor_phantom_procs=false

SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += vendor/native-nix/sepolicy/private
