#!/bin/sh
#
# tenax.sh — one-stop Void Linux setup for feribsd's rice. POSIX sh.
#
# A single top menu lets you either:
#   1. INSTALL a minimal Void base system  (run as root from the live ISO)
#        * Limine bootloader (UEFI/BIOS auto-detected, file paths auto-detected)
#        * xfs root, FAT32 /boot, GPT, zram swap
#        * iwd wifi (+ iwd-connect helper), doas instead of sudo, yash login shell
#   2. SET UP the WM + dotfiles              (run as your user, after install)
#        * dwl   (Wayland) — dwl (built from source) + waybar + foot + rofi
#        * optional ly login manager (built from source via zvm)
#
# Usage:  ./tenax.sh
#         curl -sL <raw-url> | sh
#
set -eu

# ──────────────────────────────────────────────────────────────────────────
#  Shared config + helpers
# ──────────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf '%b[*]%b %s\n'  "$GREEN"  "$NC" "$*"; }
warn()  { printf '%b[!]%b %s\n'  "$YELLOW" "$NC" "$*"; }
err()   { printf '%b[x]%b %s\n'  "$RED"    "$NC" "$*"; }
step()  { printf '\n%b==>%b %s\n' "$BLUE"  "$NC" "$*"; }
die()   { err "$*"; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── installer (do_install) config ──
REPO="https://repo-default.voidlinux.org/current"
MNT="/mnt"
# base-minimal = bootable base w/o kernel/firmware. bash is kept because the
# dots step needs it; yash is the interactive login shell. kbd (loadkeys) applies
# the console KEYMAP at boot; iproute2 (ip) brings up the loopback interface in
# runit's core-services — without them base-minimal boots with warnings.
BASE_PKGS="base-minimal linux linux-firmware-network dracut xbps xfsprogs \
dosfstools iwd iproute2 openresolv opendoas limine efibootmgr zramen kbd \
ncurses bash yash"

# ── dots (do_dots) config ──
DWL_REPO="https://github.com/feribsd/dwl-backup-dots"
WALLS_REPO="https://github.com/feribsd/walls"
SRC_DIR="$HOME/.tenax-src"        # transient: walls clone + ly build, wiped at end
DWL_DIR="$HOME/dwl"                     # persistent dwl repo, kept in $HOME so you can
                                       # keep editing the configs / dwl's config.h and
                                       # rebuild without re-cloning
WALL_DIR="$HOME/Pictures/wallpapers"
DNS_SERVER="9.9.9.9"            # Quad9 primary — pinned as an immutable /etc/resolv.conf
DNS_SERVER2="149.112.112.112"   # Quad9 secondary
BETTERFOX_URL="https://github.com/yokoffing/Betterfox/raw/refs/heads/main/user.js"
LY_TAG="v1.1.2"        # ly + Zig versions pinned as a matching pair
ZIG_VER="0.14.0"
LY_TTY="2"             # tty ly takes over; its getty is disabled and ly's config
                       # is pinned to match (set to 1 to land on it straight at boot)
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"
DEFAULT_WALL="$WALL_DIR/the_interior_of_the_oude_kerk_amsterdam_2004.127.1.jpg"

# ── cachy kernel (do_cachy) config — optional source-built kernel ──
# Void packages no CachyOS kernel, so do_cachy builds mainline + a patch set from source.
# Default patch = the BORE scheduler (CONFIG_SCHED_BORE) — this is the scheduler CachyOS
# ships, taken from its UPSTREAM source (firelzrd/bore-scheduler). Why not CachyOS's own
# patch repo? Their combined patches are generated on top of each other (and EEVDF base
# work) and do NOT apply standalone to pristine mainline — verified: their bore-cachy
# patch rejects a kernel/sched/fair.c hunk on a clean 7.0.11 tree. The upstream BORE
# patch DOES apply cleanly. The full CachyOS sauce needs their whole PKGBUILD sequence,
# which is out of scope for a one-file installer. KERNEL_PATCH_URLS is a plain list of
# patch URLs applied in order — point it at other patches if you want more.
# NOTE: the BORE patch is per-kernel-series; match the URL's linux-<series> to $KERNEL_VER.
# The patch source is PINNED to a commit (not `main`) so a repo reorg for a newer kernel
# series can't silently move/404 the path mid-build; bump KERNEL_PATCH_COMMIT to update.
KERNEL_VER="7.0.11"
# sha256 of linux-$KERNEL_VER.tar.xz from kernel.org's sha256sums.asc. Set empty (or
# KERNEL_SHA256="" in the env) to skip verification if you bump KERNEL_VER without a hash.
: "${KERNEL_SHA256:=e56c8356dda01136a6041c6ef832bd0ec99bd2d35dff97832aa5ec10ed014304}"
: "${KERNEL_PATCH_COMMIT:=f8f71b1e6e59b45f74a3bcec408cb9193350e8d8}"
KERNEL_PATCH_URLS="https://raw.githubusercontent.com/firelzrd/bore-scheduler/${KERNEL_PATCH_COMMIT}/patches/stable/linux-7.0-bore/0001-linux7.0-rc2-bore-6.6.3.patch"
KERNEL_BUILD_PKGS="base-devel git curl bc bison flex perl python3 openssl-devel \
elfutils-devel libelf ncurses-devel cpio zstd kmod pahole gettext xz tar rsync"
# Override-able via env. localmodconfig trims the build to currently-loaded modules —
# far faster/smaller (minutes + a couple GB vs the full Void config); great for a quick
# kernel or a low-disk box, but it only includes what's loaded right now. Build dir can
# point at a roomy/tmpfs path so the multi-GB tree doesn't sit on the root fs.
: "${KERNEL_LOCALMODCONFIG:=no}"               # yes = `make localmodconfig` before building
: "${KERNEL_BUILD_DIR:=$HOME/.tenax-kernel}"

COMMON_PKGS="git base-devel pkgconf curl unzip \
fastfetch pfetch neovim ranger btop cava pulsemixer \
firefox Thunar gvfs tumbler brightnessctl libnotify \
xdg-user-dirs xdg-utils polkit polkit-gnome \
dbus elogind seatd nerd-fonts nerd-fonts-symbols-ttf mesa-dri"
WAYLAND_PKGS="foot rofi Waybar dunst swaybg grim wl-clipboard \
pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-wlr"
DWL_BUILD_PKGS="wlroots0.19-devel wayland-devel wayland-protocols \
libxkbcommon-devel pixman-devel libdrm-devel libinput-devel \
libxcb-devel xcb-util-wm-devel xorg-server-xwayland"

# shared small helpers (resolve globals like PRIV at call time)
xi() { $PRIV xbps-install -Sy --yes "$@"; }            # privileged install (dots)
backup() { [ -e "$1" ] && { mkdir -p "$BACKUP_DIR"; cp -r "$1" "$BACKUP_DIR/" 2>/dev/null || true; }; }
enable_sv() {
  if [ -d "/etc/sv/$1" ] && [ ! -e "/var/service/$1" ]; then
    $PRIV ln -s "/etc/sv/$1" /var/service/
    info "enabled service: $1"
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  MODE 1 — install a minimal Void base system (root, from the live ISO)     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
do_install() {
  command -v parted >/dev/null 2>&1 || xbps-install -Sy parted

  if [ -d /sys/firmware/efi ]; then FIRMWARE="uefi"; else FIRMWARE="bios"; fi
  info "Firmware detected: $FIRMWARE  (Limine deployed accordingly)"

  if ! ping -c1 -W3 repo-default.voidlinux.org >/dev/null 2>&1; then
    warn "No internet detected. Connect first, e.g.:"
    warn "   iwctl  ->  station wlan0 scan; station wlan0 connect <SSID>"
    whiptail --yesno "No internet was detected.\n\nContinue anyway? (install will fail without network)" 12 60 || exit 1
  fi

  step "Configuration"
  # Build the disk menu without arrays (here-doc runs in this shell).
  set --
  while read -r dev size rest; do
    [ -n "${dev:-}" ] || continue
    set -- "$@" "$dev" "$size ${rest:-disk}"
  done <<EOF
$(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | grep -vE 'loop|/dev/sr|/dev/ram')
EOF
  [ "$#" -gt 0 ] || die "No disks found."

  DISK=$(whiptail --title "void-install — target disk" --menu \
    "Select the disk to ERASE and install onto:" 18 74 8 "$@" \
    3>&1 1>&2 2>&3) || exit 0
  HOSTNAME=$(whiptail --inputbox "Hostname:" 10 60 "void" 3>&1 1>&2 2>&3) || exit 0
  USERNAME=$(whiptail --inputbox "Username (added to wheel for doas):" 10 60 "user" 3>&1 1>&2 2>&3) || exit 0
  TIMEZONE=$(whiptail --inputbox "Timezone (e.g. Europe/Budapest):" 10 60 "UTC" 3>&1 1>&2 2>&3) || exit 0
  KEYMAP=$(whiptail --inputbox "Console keymap:" 10 60 "us" 3>&1 1>&2 2>&3) || exit 0
  ROOTPW=$(whiptail --passwordbox "Root password:" 10 60 3>&1 1>&2 2>&3) || exit 0
  USERPW=$(whiptail --passwordbox "Password for $USERNAME:" 10 60 3>&1 1>&2 2>&3) || exit 0
  [ -n "$ROOTPW" ] && [ -n "$USERPW" ] || die "Passwords cannot be empty."

  whiptail --title "void-install — CONFIRM" --yesno \
    "This will COMPLETELY ERASE:\n\n   $DISK\n\nLayout: GPT, 1GiB FAT32 /boot, xfs root, zram swap.\nBootloader: Limine ($FIRMWARE)\nShell: yash   Host: $HOSTNAME   User: $USERNAME\n\nThere is no undo. Proceed?" \
    18 70 || { warn "Aborted."; exit 0; }

  case "$DISK" in *[0-9]) P="p" ;; *) P="" ;; esac
  BOOTPART="${DISK}${P}1"; ROOTPART="${DISK}${P}2"

  step "Partitioning $DISK"
  wipefs -a "$DISK" || true
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart boot fat32 1MiB 1025MiB
  if [ "$FIRMWARE" = "uefi" ]; then
    parted -s "$DISK" set 1 esp on
  else
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" set 1 legacy_boot on || true
  fi
  parted -s "$DISK" mkpart root xfs 1025MiB 100%
  partprobe "$DISK"; sleep 2

  step "Formatting"
  mkfs.vfat -F32 "$BOOTPART"
  mkfs.xfs -f "$ROOTPART"

  step "Mounting"
  mount "$ROOTPART" "$MNT"
  mkdir -p "$MNT/boot"
  mount "$BOOTPART" "$MNT/boot"

  step "Installing base system (minimal)"
  mkdir -p "$MNT/var/db/xbps/keys"
  cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/" 2>/dev/null || true
  # shellcheck disable=SC2086
  XBPS_ARCH=x86_64 xbps-install -Sy -R "$REPO" -r "$MNT" $BASE_PKGS

  step "Generating fstab"
  ROOTUUID=$(blkid -s UUID -o value "$ROOTPART")
  BOOTUUID=$(blkid -s UUID -o value "$BOOTPART")
  cat > "$MNT/etc/fstab" <<EOF
# <file system>   <dir>   <type>  <options>             <dump>  <pass>
UUID=$ROOTUUID    /       xfs     defaults              0       1
UUID=$BOOTUUID    /boot   vfat    defaults,noatime      0       2
tmpfs             /tmp    tmpfs   defaults,nosuid,nodev 0       0
EOF

  step "Installing iwd connect helper"
  mkdir -p "$MNT/usr/local/bin"
  cat > "$MNT/usr/local/bin/iwd-connect" <<'HELP'
#!/bin/sh
# iwd-connect — create an iwd network profile non-interactively, then connect.
# Usage: iwd-connect "<SSID>" ["<passphrase>"]   (run as root / via doas)
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root (doas iwd-connect ...)"; exit 1; }
SSID="${1:-}"; PASS="${2:-}"
[ -n "$SSID" ] || { printf 'SSID: '; read -r SSID; }
mkdir -p /var/lib/iwd
PROFILE="/var/lib/iwd/${SSID}.psk"
if [ -z "$PASS" ] && [ "${OPEN:-}" != "1" ]; then
  printf 'Passphrase (empty = open network): '
  stty -echo; read -r PASS; stty echo; echo
fi
if [ -n "$PASS" ]; then
  printf '[Security]\nPassphrase=%s\n' "$PASS" > "$PROFILE"
else
  printf '[Settings]\nAutoConnect=true\n' > "$PROFILE"
fi
chmod 600 "$PROFILE"
echo "Wrote $PROFILE"
sv restart iwd 2>/dev/null || true
DEV=$(iwctl device list 2>/dev/null | awk 'NR>4 && $2!="" {print $2; exit}')
[ -n "${DEV:-}" ] && iwctl station "$DEV" connect "$SSID" 2>/dev/null || true
echo "Done. Check with: iwctl station list"
HELP
  chmod +x "$MNT/usr/local/bin/iwd-connect"
  mkdir -p "$MNT/etc/iwd"
  cat > "$MNT/etc/iwd/main.conf" <<EOF
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=none
EOF

  step "Configuring the new system (chroot)"
  for d in dev proc sys run; do
    mount --rbind "/$d" "$MNT/$d"
    mount --make-rslave "$MNT/$d"
  done
  cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

  # config script (NO secrets) — values expanded here, then run in chroot
  cat > "$MNT/root/chroot-setup.sh" <<EOF
#!/bin/sh
set -eu
FIRMWARE="$FIRMWARE"
DISK="$DISK"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TIMEZONE="$TIMEZONE"
KEYMAP="$KEYMAP"
EOF
  cat >> "$MNT/root/chroot-setup.sh" <<'EOS'

echo "$HOSTNAME" > /etc/hostname

sed -i "s|^#\?TIMEZONE=.*|TIMEZONE=\"$TIMEZONE\"|"     /etc/rc.conf 2>/dev/null || echo "TIMEZONE=\"$TIMEZONE\""        >> /etc/rc.conf
sed -i "s|^#\?KEYMAP=.*|KEYMAP=\"$KEYMAP\"|"           /etc/rc.conf 2>/dev/null || echo "KEYMAP=\"$KEYMAP\""            >> /etc/rc.conf
sed -i "s|^#\?HARDWARECLOCK=.*|HARDWARECLOCK=\"UTC\"|" /etc/rc.conf 2>/dev/null || echo "HARDWARECLOCK=\"UTC\""         >> /etc/rc.conf
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || true

if [ -f /etc/default/libc-locales ]; then
  sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/default/libc-locales
  echo 'LANG=en_US.UTF-8' > /etc/locale.conf
fi

# yash as the login shell
YASH=$(command -v yash || echo /usr/bin/yash)
grep -qxF "$YASH" /etc/shells 2>/dev/null || echo "$YASH" >> /etc/shells
useradd -m -G wheel,audio,video,input,storage,network -s "$YASH" "$USERNAME"

# Seed ~/.yashrc so yash doesn't print its "no initialization script" banner on
# every interactive login. Prefer the bundled sample (useful history/prompt
# defaults); fall back to an empty file for bare defaults.
YASHRC="/home/$USERNAME/.yashrc"
YASH_SAMPLE=/usr/share/yash/initialization/sample
if [ -f "$YASH_SAMPLE" ]; then cp "$YASH_SAMPLE" "$YASHRC"; else : > "$YASHRC"; fi
# Greet every interactive shell (terminal) with pfetch.
grep -q 'pfetch' "$YASHRC" 2>/dev/null || \
  printf '\n# system info on each interactive shell\ncommand -v pfetch >/dev/null 2>&1 && pfetch\n' >> "$YASHRC"
chown "$USERNAME:$USERNAME" "$YASHRC"

echo 'permit persist :wheel' > /etc/doas.conf
chmod 0400 /etc/doas.conf

ln -sf /etc/sv/iwd    /var/service/ 2>/dev/null || true
ln -sf /etc/sv/zramen /var/service/ 2>/dev/null || true
ln -sf /etc/sv/dbus   /var/service/ 2>/dev/null || true

# Limine: kernel hook that regenerates limine.conf for every installed kernel
mkdir -p /etc/kernel.d/post-install
cat > /etc/kernel.d/post-install/90-limine.sh <<'HOOK'
#!/bin/sh
BOOT=/boot
ROOTUUID=$(findmnt -no UUID / 2>/dev/null)
[ -n "$ROOTUUID" ] || exit 0
conf="$BOOT/limine.conf"
{
  echo "timeout: 3"; echo
  for k in "$BOOT"/vmlinuz-*; do
    [ -e "$k" ] || continue
    ver=${k##*/vmlinuz-}
    init="initramfs-${ver}.img"
    echo "/Void Linux ($ver)"
    echo "    protocol: linux"
    echo "    path: boot():/vmlinuz-${ver}"
    [ -e "$BOOT/$init" ] && echo "    module_path: boot():/${init}"
    echo "    cmdline: root=UUID=${ROOTUUID} rw loglevel=4"
    echo
  done
} > "$conf"
HOOK
chmod +x /etc/kernel.d/post-install/90-limine.sh

xbps-reconfigure -fa
sh /etc/kernel.d/post-install/90-limine.sh || true

# Auto-detect the Limine files shipped by the package
LIMINE_EFI=$(xbps-query -f limine 2>/dev/null  | grep -i 'BOOTX64\.EFI$'    | head -n1)
LIMINE_BIOS=$(xbps-query -f limine 2>/dev/null | grep -i 'limine-bios\.sys$'| head -n1)
[ -n "$LIMINE_EFI" ]  || LIMINE_EFI=/usr/share/limine/BOOTX64.EFI
[ -n "$LIMINE_BIOS" ] || LIMINE_BIOS=/usr/share/limine/limine-bios.sys
echo "Limine EFI : $LIMINE_EFI"
echo "Limine BIOS: $LIMINE_BIOS"

if [ "$FIRMWARE" = "uefi" ]; then
  mkdir -p /boot/EFI/BOOT
  cp "$LIMINE_EFI" /boot/EFI/BOOT/BOOTX64.EFI
  command -v efibootmgr >/dev/null 2>&1 && \
    efibootmgr --create --disk "$DISK" --part 1 \
      --loader '\EFI\BOOT\BOOTX64.EFI' --label "Limine" --unicode 2>/dev/null || true
else
  cp "$LIMINE_BIOS" /boot/limine-bios.sys
  command -v limine >/dev/null 2>&1 && limine bios-install "$DISK"
fi
EOS

  chmod +x "$MNT/root/chroot-setup.sh"
  chroot "$MNT" /bin/sh /root/chroot-setup.sh

  # passwords (piped in — never written to disk)
  # NOTE: printf, not echo — dash's echo mangles backslashes in passwords.
  # NOTE: chpasswd -c SHA512 — default chpasswd hashes via PAM, which silently
  # fails inside the fresh chroot and leaves accounts unset/locked. -c bypasses
  # PAM and writes a crypt(3) hash directly to /etc/shadow.
  printf '%s:%s\n' "root"      "$ROOTPW" | chroot "$MNT" chpasswd -c SHA512
  printf '%s:%s\n' "$USERNAME" "$USERPW" | chroot "$MNT" chpasswd -c SHA512
  rm -f "$MNT/root/chroot-setup.sh"

  # Pin DNS to Quad9. iwd is set to NameResolvingService=none (above) so it
  # won't touch resolv.conf; making the file immutable also stops any DHCP
  # client / NetworkManager from overwriting it. (Use `chattr -i` to change it.)
  step "Pinning DNS to $DNS_SERVER, $DNS_SERVER2"
  printf 'nameserver %s\nnameserver %s\n' "$DNS_SERVER" "$DNS_SERVER2" > "$MNT/etc/resolv.conf"
  chattr +i "$MNT/etc/resolv.conf" 2>/dev/null \
    && info "/etc/resolv.conf -> $DNS_SERVER, $DNS_SERVER2 (immutable)" \
    || warn "/etc/resolv.conf -> $DNS_SERVER, $DNS_SERVER2 set, but chattr +i failed — a DNS manager may overwrite it"

  step "Cleaning up"
  umount -R "$MNT" 2>/dev/null || true

  whiptail --title "void-install — done" --msgbox \
    "Minimal Void install complete.\n\n  * Limine ($FIRMWARE), xfs root, zram swap\n  * login shell: yash\n  * doas instead of sudo\n  * iwd wifi — after reboot: doas iwd-connect \"<SSID>\" \"<pass>\"\n\nRemove the install media and reboot, then run this\nscript again (as your user) to set up the WMs + dots." \
    18 70 || true

  if whiptail --title "void-install — reboot" --yesno \
    "Reboot now?\n\nRemove the install media first, then on the next boot run\nthis script again as your user to set up the WM + dots." \
    12 64; then
    info "Rebooting…"; sync; reboot
  else
    info "Reboot later with: reboot"
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  MODE 2 — set up dwl + dotfiles (your user, after install)                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝
do_dots() {
  has_cmd git || { info "Installing git…"; $PRIV xbps-install -Sy --yes git; }

  GPU=$(whiptail --title "tenax — GPU drivers" --menu \
    "Choose a GPU driver to install:" 16 70 4 \
    "skip"   "Don't touch GPU drivers" \
    "amd"    "AMD — mesa + vulkan-radeon" \
    "intel"  "Intel — mesa + vulkan-intel" \
    "nvidia" "NVIDIA proprietary (enables void-repo-nonfree)" \
    3>&1 1>&2 2>&3) || GPU="skip"
  info "GPU choice: $GPU"

  if whiptail --title "tenax — greeter" --yesno \
    "Install the ly login manager?\n\nly isn't packaged on Void, so it's built from source\n(ly $LY_TAG via Zig $ZIG_VER, fetched with zvm).\nIt runs on tty2 and lists your dwl session." \
    14 70; then LY="yes"; else LY="no"; fi
  info "ly greeter: $LY"

  whiptail --title "tenax" --yesno \
    "About to install packages and deploy dotfiles for:\n\n  dwl (Wayland) + waybar + foot + rofi\n\nGPU:     $GPU\nGreeter: ly = $LY\n\nReplaced configs are backed up to:\n$BACKUP_DIR\n\nProceed?" \
    17 70 || { warn "Cancelled."; exit 0; }

  step "Installing common packages"
  xi $COMMON_PKGS

  step "Installing shared Wayland packages";   xi $WAYLAND_PKGS
  step "Installing dwl build dependencies";    xi $DWL_BUILD_PKGS

  case "$GPU" in
    amd)    step "Installing AMD drivers";   xi mesa-dri mesa-vulkan-radeon vulkan-loader xf86-video-amdgpu ;;
    intel)  step "Installing Intel drivers"; xi mesa-dri mesa-vulkan-intel  vulkan-loader ;;
    nvidia) step "Installing NVIDIA drivers"
            $PRIV xbps-install -Sy --yes void-repo-nonfree
            $PRIV xbps-install -Sy
            xi nvidia ;;
    skip)   info "Skipping GPU drivers." ;;
  esac

  step "Fetching dotfiles and wallpapers"
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
  # The dwl repo is cloned into $HOME and kept; a re-run leaves an existing clone
  # (and any local edits) untouched instead of wiping it.
  clone() {
    if [ -d "$2/.git" ]; then info "already cloned: $2 (left as-is)"; return 0; fi
    info "git clone $1 -> $2"; git clone --depth=1 "$1" "$2"
  }
  clone "$WALLS_REPO" "$SRC_DIR/walls"
  clone "$DWL_REPO"   "$DWL_DIR"

  mkdir -p "$WALL_DIR"
  find "$SRC_DIR/walls" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' \) \
    -exec cp -f {} "$WALL_DIR/" \;
  [ -f "$DWL_DIR/pont.jpg" ] && cp -f "$DWL_DIR/pont.jpg" "$WALL_DIR/"
  [ -f "$DEFAULT_WALL" ] || DEFAULT_WALL=$(find "$WALL_DIR" -maxdepth 1 -type f | head -n1)
  info "Default wallpaper: $DEFAULT_WALL"

  mkdir -p "$HOME/.config"

  # ── dwl (build from source) ──
  # Deploy the rice FIRST: the configs live at the top level of dwl-backup-dots
  # and DON'T depend on the dwl build, which can fail against wlroots — under
  # `set -e` that would otherwise skip the config copy entirely and leave an
  # incomplete rice. Copy everything the repo ships (foot/, waybar/, rofi/, the
  # dwl/ source, the wallpaper, …) into ~/.config, i.e. `cp -r ~/dwl/* ~/.config`.
  # The `*` glob skips .git.
  step "Deploying dwl config (cp -r ~/dwl/* ~/.config)"
  for src in "$DWL_DIR"/*; do
    [ -e "$src" ] || continue            # empty repo / nullglob guard
    name=$(basename "$src")
    dest="$HOME/.config/$name"
    backup "$dest"; rm -rf "$dest"; cp -r "$src" "$dest"
    info "deployed ~/.config/$name"
  done

  step "Building dwl from source"
  DWL_SRC="$DWL_DIR/dwl"
  sed -i "s#/home/feribsd#$HOME#g" "$DWL_SRC/config.h"
  ( cd "$DWL_SRC" && make clean && make CC=gcc )
  ( cd "$DWL_SRC" && $PRIV make install )
  info "dwl installed to /usr/local/bin/dwl"

  # Explicit wayland-sessions entry so greeters (ly) list a dwl session,
  # regardless of whether dwl's own `make install` placed it.
  if [ -f "$DWL_SRC/dwl.desktop" ]; then
    $PRIV mkdir -p /usr/share/wayland-sessions
    $PRIV cp -f "$DWL_SRC/dwl.desktop" /usr/share/wayland-sessions/dwl.desktop
    info "installed wayland-sessions entry: dwl.desktop"
  else
    info "WARNING: $DWL_SRC/dwl.desktop not found — no session entry installed"
  fi
  info "dwl ready — start from a TTY with: dbus-run-session dwl"

  # ── ly (built from source via zvm) ──
  if [ "$LY" = "yes" ]; then
    step "Building ly $LY_TAG (Zig $ZIG_VER via zvm)"
    # ly links against PAM; without pam-devel its Zig build fails at link time
    # with "unable to find dynamic system library 'pam'".
    xi zvm pam-devel
    zvm install "$ZIG_VER"; zvm use "$ZIG_VER"
    ZIGBIN="$HOME/.zvm/bin/zig"
    [ -x "$ZIGBIN" ] || ZIGBIN=$(PATH="$HOME/.zvm/bin:$PATH" command -v zig || true)
    if [ -z "${ZIGBIN:-}" ] || [ ! -x "$ZIGBIN" ]; then
      err "Could not locate the Zig $ZIG_VER binary from zvm — skipping ly."
    else
      git clone --depth=1 --branch "$LY_TAG" https://github.com/fairyglade/ly "$SRC_DIR/ly"
      ( cd "$SRC_DIR/ly" && "$ZIGBIN" build )
      ( cd "$SRC_DIR/ly" && $PRIV "$ZIGBIN" build installexe -Dinit_system=runit )
      info "ly installed (config: /etc/ly/config.ini, service: /etc/sv/ly)"
    fi
  fi

  # ── Firefox: privacy-hardened defaults + extensions ──
  # Two update-safe mechanisms:
  #  - enterprise policy in /etc/firefox/policies/ (survives Firefox upgrades):
  #    auto-installs the add-ons from AMO on first launch and sets Startpage as
  #    homepage + default search engine.
  #  - Betterfox user.js dropped into the default profile under $HOME.
  # Add-on install + Betterfox fetch both need network; failures are non-fatal.
  if has_cmd firefox; then
    step "Configuring Firefox (Betterfox + uBO/Privacy Badger/Vimium + Startpage)"

    AMO="https://addons.mozilla.org/firefox/downloads/latest"
    $PRIV mkdir -p /etc/firefox/policies
    # force_installed = auto-installed AND mandatory: the user can't disable or
    # remove them (use normal_installed to make them user-manageable instead).
    $PRIV tee /etc/firefox/policies/policies.json >/dev/null <<EOF
{
  "policies": {
    "ExtensionSettings": {
      "uBlock0@raymondhill.net":                 { "installation_mode": "force_installed", "install_url": "$AMO/ublock-origin/latest.xpi" },
      "jid1-MnnxcxisBPnSXQ@jetpack":             { "installation_mode": "force_installed", "install_url": "$AMO/privacy-badger17/latest.xpi" },
      "{d7742d87-e61d-4b78-b8a1-b469842139fa}":  { "installation_mode": "force_installed", "install_url": "$AMO/vimium-ff/latest.xpi" }
    },
    "Homepage": { "URL": "https://www.startpage.com/", "StartPage": "homepage" },
    "SearchEngines": {
      "Default": "Startpage",
      "Add": [
        { "Name": "Startpage", "URLTemplate": "https://www.startpage.com/sp/search?query={searchTerms}", "Method": "GET", "Alias": "sp" }
      ]
    },
    "DontCheckDefaultBrowser": true
  }
}
EOF
    info "wrote /etc/firefox/policies/policies.json (extensions + Startpage)"

    # Betterfox user.js -> default profile. It takes effect on the next real
    # launch and lives in $HOME, so it survives Firefox upgrades.
    FFDIR="$HOME/.mozilla/firefox"
    mkdir -p "$FFDIR"
    ff_profiles() { ls -d "$FFDIR"/*.default-release "$FFDIR"/*.default 2>/dev/null; }

    # Stage the user.js ONCE so we don't re-download per profile (and so a
    # network failure is reported clearly instead of silently no-op'ing).
    USERJS="$SRC_DIR/user.js"
    if ! curl -fsSL "$BETTERFOX_URL" -o "$USERJS"; then
      warn "couldn't fetch Betterfox user.js (no network?) — skipping; re-run setup once online."
      USERJS=""
    fi

    if [ -n "$USERJS" ]; then
      # Firefox must have a profile before user.js means anything. A headless
      # launch makes Firefox build its own default-release profile (the one a
      # real launch then uses); poll for it appearing instead of trusting a
      # fixed timeout, and only fall back to -CreateProfile if that fails.
      if [ -z "$(ff_profiles)" ]; then
        firefox --headless --no-remote about:blank >/dev/null 2>&1 &
        ff_pid=$!
        i=0; while [ "$i" -lt 30 ] && [ -z "$(ff_profiles)" ]; do sleep 1; i=$((i+1)); done
        kill "$ff_pid" 2>/dev/null || true
      fi
      if [ -z "$(ff_profiles)" ]; then
        firefox --headless -CreateProfile "void $FFDIR/void.default-release" >/dev/null 2>&1 \
          || mkdir -p "$FFDIR/void.default-release"
      fi

      seeded=""
      for p in $(ff_profiles); do
        [ -d "$p" ] || continue
        cp -f "$USERJS" "$p/user.js" && { info "Betterfox user.js -> ${p##*/}"; seeded=1; }
      done
      [ -n "$seeded" ] || warn "no Firefox profile materialised — Betterfox user.js skipped (launch Firefox once, then re-run setup)."
    fi
  fi

  step "Enabling services and adding user to groups"
  enable_sv dbus
  enable_sv elogind
  enable_sv polkitd
  enable_sv seatd

  # Networking: keep iwd if the system already uses it; else NetworkManager.
  if [ -d /etc/sv/iwd ] && { [ -e /var/service/iwd ] || has_cmd iwctl; }; then
    info "iwd present — keeping it for networking (skipping NetworkManager)."
    enable_sv iwd
  else
    info "Installing NetworkManager for networking…"
    xi NetworkManager
    enable_sv NetworkManager
    if [ -e /var/service/dhcpcd ]; then
      $PRIV rm -f /var/service/dhcpcd
      warn "disabled dhcpcd service (NetworkManager now manages networking)"
    fi
  fi

  if [ "$LY" = "yes" ]; then
    if [ ! -d /etc/sv/ly ]; then
      err "ly was requested but /etc/sv/ly is missing — the runit service didn't"
      err "install (the 'zig build installexe -Dinit_system=runit' step failed)."
      err "ly will NOT autostart. Re-run, or install /etc/sv/ly by hand."
    else
      # Pin ly to LY_TTY in its own config AND free that tty's getty. If these two
      # disagree, agetty and ly fight over consoles and the greeter never shows.
      if [ -f /etc/ly/config.ini ]; then
        $PRIV sed -i "s/^[#[:space:]]*tty[[:space:]]*=.*/tty = $LY_TTY/" /etc/ly/config.ini \
          || warn "could not pin tty in /etc/ly/config.ini — set 'tty = $LY_TTY' yourself"
      fi
      if [ -e "/var/service/agetty-tty$LY_TTY" ]; then
        $PRIV rm -f "/var/service/agetty-tty$LY_TTY"
        warn "disabled agetty-tty$LY_TTY (ly runs there)"
      fi
      enable_sv ly
      if [ -e /var/service/ly ]; then
        info "ly enabled — greeter comes up on tty$LY_TTY at boot (switch with Ctrl+Alt+F$LY_TTY)."
        # Start it now so you don't have to reboot to test. runit needs a moment
        # to spawn runsv for the freshly symlinked service before `sv up` works.
        sleep 2
        $PRIV sv up ly 2>/dev/null || warn "couldn't 'sv up ly' yet — it'll start on next boot."
      else
        err "ly service did not enable (/var/service/ly missing) — it won't autostart."
      fi
    fi
  fi

  for g in _seatd video input audio; do
    getent group "$g" >/dev/null 2>&1 && $PRIV usermod -aG "$g" "$(id -un)" || true
  done
  has_cmd xdg-user-dirs-update && xdg-user-dirs-update || true

  # Safety net: base-install seeds ~/.yashrc, but that step is skipped when the
  # user already exists. Seed it here too so yash never prints its "no
  # initialization script" banner on interactive logins.
  if [ ! -e "$HOME/.yashrc" ]; then
    YASH_SAMPLE=/usr/share/yash/initialization/sample
    if [ -f "$YASH_SAMPLE" ]; then cp "$YASH_SAMPLE" "$HOME/.yashrc"; else : > "$HOME/.yashrc"; fi
  fi
  # Greet every interactive shell (terminal) with pfetch (idempotent).
  grep -q 'pfetch' "$HOME/.yashrc" 2>/dev/null || \
    printf '\n# system info on each interactive shell\ncommand -v pfetch >/dev/null 2>&1 && pfetch\n' >> "$HOME/.yashrc"

  # ly build artifacts may be root-owned, so fall back to privileged removal
  rm -rf "$SRC_DIR" 2>/dev/null || $PRIV rm -rf "$SRC_DIR"

  START_NOTES=""
  [ "$LY" = "yes" ] && START_NOTES="${START_NOTES}  ly starts on boot (tty2) — pick your session there.\n"
  START_NOTES="${START_NOTES}  Or start manually from a TTY:\n"
  START_NOTES="${START_NOTES}    dwl   : dbus-run-session dwl\n"

  whiptail --title "tenax — done" --msgbox \
    "Setup complete.\n\nStart your WM:\n$START_NOTES\nBackups of replaced configs:\n$BACKUP_DIR\n\nLog out/in (or reboot) so new group membership takes effect." \
    18 70 || true
  step "All done."
  printf '%b\n' "$START_NOTES"
  warn "Reboot (or re-login) recommended so seat/group changes take effect."
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  MODE 3 — build a CachyOS-patched mainline kernel from source (optional)    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# Void has no CachyOS kernel package, so this fetches mainline $KERNEL_VER, applies the
# pinned CachyOS patch(es) (default: the BORE scheduler), seeds .config from the RUNNING
# kernel so hardware support carries over, builds, installs modules + vmlinuz, rebuilds
# the initramfs, and lets 90-limine.sh regenerate limine.conf. It is deliberately separate
# from do_install: a long compile that can fail on a patch-apply must never block getting a
# bootable base system. (Tip: `make localmodconfig` instead of the running config trims the
# build to loaded modules — far faster/smaller, but only what's loaded right now.)
do_cachy() {
  KMAJOR=${KERNEL_VER%%.*}                 # 7.0.11 -> 7
  KSERIES=${KERNEL_VER%.*}                  # 7.0.11 -> 7.0
  KTAR="linux-${KERNEL_VER}.tar.xz"
  KURL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/${KTAR}"
  BUILD="$KERNEL_BUILD_DIR"
  LOCALVER="-cachyos"
  KVER_FULL="${KERNEL_VER}${LOCALVER}"

  PATCH_NAMES=""; for u in $KERNEL_PATCH_URLS; do PATCH_NAMES="$PATCH_NAMES $(basename "$u")"; done
  whiptail --title "tenax — BORE/Cachy kernel" --yesno \
    "Build a BORE-scheduled (CachyOS scheduler) kernel from source?\n\n  mainline: $KERNEL_VER  (series $KSERIES)\n  patches: $PATCH_NAMES\n  config:   running kernel + olddefconfig (localmodconfig=$KERNEL_LOCALMODCONFIG)\n  name:     vmlinuz-$KVER_FULL  (CONFIG_SCHED_BORE)\n  builddir: $BUILD\n\nDownloads ~150MB of source and COMPILES a kernel — expect\n20-40 min and several GB (less with localmodconfig). Proceed?" \
    18 74 || { warn "Cancelled."; exit 0; }

  step "Installing kernel build dependencies"
  xi $KERNEL_BUILD_PKGS

  step "Fetching mainline $KERNEL_VER source"
  # Clean prior artifacts but NOT $BUILD itself — it may be a mount point or a dir the
  # user wants kept (rm -rf on a mountpoint fails with "Device or resource busy").
  mkdir -p "$BUILD"; cd "$BUILD"
  rm -rf "$BUILD/linux-${KERNEL_VER}" "$BUILD/patches" "$BUILD/$KTAR"
  curl -fL --retry 3 -o "$KTAR" "$KURL"
  if [ -n "$KERNEL_SHA256" ]; then
    info "verifying $KTAR sha256"
    echo "$KERNEL_SHA256  $KTAR" | sha256sum -c - \
      || die "sha256 mismatch on $KTAR — corrupt download or wrong KERNEL_SHA256 for $KERNEL_VER."
  else
    warn "KERNEL_SHA256 empty — skipping tarball checksum verification."
  fi
  tar xf "$KTAR"
  KSRC="$BUILD/linux-${KERNEL_VER}"

  step "Fetching + applying patches"
  mkdir -p "$BUILD/patches"
  for url in $KERNEL_PATCH_URLS; do
    pf="$BUILD/patches/$(basename "$url")"
    info "fetch $(basename "$url")"
    curl -fL --retry 3 -o "$pf" "$url"
    # Dry-run first so a version mismatch fails loudly here, not mid-build. (Patches are
    # kernel-series-specific — a reject usually means KERNEL_VER and the patch disagree.)
    if ! ( cd "$KSRC" && patch -p1 --dry-run < "$pf" >/dev/null 2>&1 ); then
      ( cd "$KSRC" && patch -p1 --dry-run < "$pf" 2>&1 | grep -i 'fail' | head ) || true
      die "patch does not apply to linux-$KERNEL_VER: $(basename "$url") — wrong kernel/patch version?"
    fi
    info "patch -p1 < $(basename "$url")"
    ( cd "$KSRC" && patch -p1 < "$pf" )
  done

  step "Seeding .config from the running kernel"
  if [ -f "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" "$KSRC/.config"
  elif [ -r /proc/config.gz ]; then
    zcat /proc/config.gz > "$KSRC/.config"
  else
    warn "no running-kernel config found — using 'make defconfig'"
    ( cd "$KSRC" && make defconfig )
  fi
  if [ "$KERNEL_LOCALMODCONFIG" = yes ]; then
    step "Trimming config to loaded modules (localmodconfig)"
    ( cd "$KSRC" && yes "" | make localmodconfig )
  fi
  ( cd "$KSRC"
    scripts/config --enable  SCHED_BORE             2>/dev/null || true   # from the cachy patch
    scripts/config --enable  CACHY                  2>/dev/null || true   # CachyOS knob, if present
    scripts/config --disable LOCALVERSION_AUTO      2>/dev/null || true
    scripts/config --disable DEBUG_INFO             2>/dev/null || true   # smaller/faster build
    scripts/config --disable DEBUG_INFO_BTF         2>/dev/null || true   # BTF builds a huge unstripped
    scripts/config --disable DEBUG_INFO_BTF_MODULES 2>/dev/null || true   # vmlinux (needs pahole, lots of
    scripts/config --disable DEBUG_INFO_DWARF5      2>/dev/null || true   # disk/RAM) — skip for a desktop
    scripts/config --disable DEBUG_INFO_DWARF4      2>/dev/null || true   # kernel; it's only for BPF CO-RE
    scripts/config --set-str SYSTEM_TRUSTED_KEYS    "" 2>/dev/null || true   # clear Void's inherited
    scripts/config --set-str SYSTEM_REVOCATION_KEYS "" 2>/dev/null || true   # signing-key paths (string
    scripts/config --disable SYSTEM_TRUSTED_KEYS    2>/dev/null || true      # symbols — empty them so the
    scripts/config --disable SYSTEM_REVOCATION_KEYS 2>/dev/null || true      # certs/ stage needs no .pem
    scripts/config --set-str LOCALVERSION "$LOCALVER"
    make olddefconfig )

  step "Building kernel (make -j$(nproc)) — the long part"
  ( cd "$KSRC" && make -j"$(nproc)" )

  step "Installing modules + kernel image"
  ( cd "$KSRC" && $PRIV make modules_install )       # -> /lib/modules/$KVER_FULL
  $PRIV cp -f "$KSRC/arch/x86/boot/bzImage" "/boot/vmlinuz-$KVER_FULL"
  $PRIV cp -f "$KSRC/System.map"            "/boot/System.map-$KVER_FULL"
  $PRIV cp -f "$KSRC/.config"               "/boot/config-$KVER_FULL"

  step "Generating initramfs (dracut)"
  $PRIV dracut --force "/boot/initramfs-$KVER_FULL.img" "$KVER_FULL"

  step "Updating Limine boot entries"
  if [ -x /etc/kernel.d/post-install/90-limine.sh ]; then
    $PRIV sh /etc/kernel.d/post-install/90-limine.sh
  else
    warn "90-limine.sh hook missing — add a Limine entry for vmlinuz-$KVER_FULL by hand."
  fi

  info "Built and installed: $KVER_FULL  (rm -rf $BUILD to reclaim space)"
  whiptail --title "tenax — CachyOS kernel" --msgbox \
    "CachyOS-patched kernel installed:\n\n  /boot/vmlinuz-$KVER_FULL\n  /lib/modules/$KVER_FULL\n\nScheduler: BORE (CONFIG_SCHED_BORE).\nLimine was updated — reboot and pick it from the menu." \
    16 70 || true
  step "All done."
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Entry: detect environment, ask the mode, dispatch                         ║
# ╚══════════════════════════════════════════════════════════════════════════╝
step "tenax: pre-flight"
has_cmd xbps-install || die "'xbps-install' not found — this is for Void Linux only."

# privilege: root needs none; otherwise sudo/doas
if [ "$(id -u)" -eq 0 ]; then
  PRIV=""
  IS_ROOT=1
else
  if   has_cmd sudo; then PRIV="sudo"
  elif has_cmd doas; then PRIV="doas"
  else die "Neither 'sudo' nor 'doas' is installed. Install one and re-run."
  fi
  IS_ROOT=0
  info "Using '$PRIV' for privilege escalation."
fi

# whiptail is needed for the menus. The Void live ISO ships an xbps older than the
# current repo, and xbps refuses to install ANY package until it updates itself
# ("The 'xbps' package must be updated, please run `xbps-install -u xbps`"). So when
# whiptail is missing (live ISO / fresh system) self-update xbps first, otherwise the
# newt install — and later parted + the base install — die under `set -e`.
if ! has_cmd whiptail; then
  info "Updating xbps (live ISO ships an older xbps)…"; $PRIV xbps-install -Suy xbps
  info "Installing newt (whiptail)…";                   $PRIV xbps-install -Sy --yes newt
fi

MODE=$(whiptail --title "tenax" --menu \
  "What do you want to do?" 16 78 3 \
  "setup"   "Set up dwl + shell + dotfiles (installed system)" \
  "install" "ALSO install a minimal Void base system first (from live ISO)" \
  "kernel"  "Build an optional CachyOS-patched kernel from source" \
  3>&1 1>&2 2>&3) || exit 0

case "$MODE" in
  install)
    [ "$IS_ROOT" -eq 1 ] || die "The system installer must run as root from the Void live ISO."
    do_install
    ;;
  setup)
    [ "$IS_ROOT" -eq 0 ] || die "Run the dotfiles setup as your normal user, not root."
    do_dots
    ;;
  kernel)
    do_cachy
    ;;
esac
