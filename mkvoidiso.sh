#!/bin/bash

# ==============================================================================
# constants {{{

# path to directory containing this file
readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# path to void-linux/void-mklive
readonly BUILD_DIR_DEFAULT="$PWD/void-mklive"
BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"

# prioritized remote repository
readonly XBPS_REPOSITORY_DEFAULT="https://ftp.swin.edu.au/voidlinux/current"
XBPS_REPOSITORY="${XBPS_REPOSITORY:-$XBPS_REPOSITORY_DEFAULT}"

# path to local repository
readonly XBPS_REPOSITORY_LOCAL_DEFAULT="/tmp/include/opt/voidpkgs"
XBPS_REPOSITORY_LOCAL="${XBPS_REPOSITORY_LOCAL:-$XBPS_REPOSITORY_LOCAL_DEFAULT}"

# mkvoidiso version number
readonly VERSION=0.0.1

# end constants }}}
# ==============================================================================
# usage {{{

USAGE() {
  local USAGE
  read -r -d '' USAGE <<'EOF'
Usage:
  ./mkvoidiso.sh [-h|--help]
                 [--repository <url>] [--local-repository <path>]
                 [--build-dir <path>]
                 [--with-broadcom-wl-dkms] [--with-b43-firmware]
                 [--patch-wpa-supplicant]
                 [--with-custom-packages]

Options:
  -h, --help                Show this help text
  -v, --version             Show program version
  -R, --repository          Prioritized remote repository for stock packages
  -L, --local-repository    Path to local repository for custom packages
  -B, --build-dir           Path to local void-linux/void-mklive
  --patch-wpa-supplicant    Include wpa_supplicant built without CONFIG_MESH
  --with-b43-firmware       Include b43-firmware built locally and iwd
  --with-broadcom-wl-dkms   Include broadcom-wl-dkms and iwd
  --with-custom-packages    Include packages in packages.custom.txt built locally

Examples

  # Generate ISO
  ./mkvoidiso.sh

  # Generate ISO with broadcom-wl-dkms and iwd
  ./mkvoidiso.sh --with-broadcom-wl-dkms

  # Generate ISO with broadcom-wl-dkms, iwd and patched wpa_supplicant
  ./mkvoidiso.sh --with-broadcom-wl-dkms --patch-wpa-supplicant

  # Generate ISO with packages in packages.custom.txt
  ./mkvoidiso.sh --with-custom-packages
EOF
  echo "$USAGE"
}

# end usage }}}
# ==============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      USAGE
      exit 0
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    -B|--build-dir)
      BUILD_DIR="$2"
      # shift past argument and value
      shift
      shift
      ;;
    -L|--local-repository)
      XBPS_REPOSITORY_LOCAL="$2"
      shift
      shift
      ;;
    -R|--repository)
      XBPS_REPOSITORY="$2"
      shift
      shift
      ;;
    --patch-wpa-supplicant)
      PATCH_WPA_SUPPLICANT=true
      shift
      ;;
    --with-b43-firmware)
      WITH_B43_FIRMWARE=true
      shift
      ;;
    --with-broadcom-wl-dkms)
      WITH_BROADCOM_WL_DKMS=true
      shift
      ;;
    --with-custom-packages)
      WITH_CUSTOM_PACKAGES=true
      shift
      ;;
    -*)
      # unknown option
      _usage
      exit 1
      ;;
    *)
      # unknown command
      _usage
      exit 1
      ;;
  esac
done

git_ensure_latest() {
  local _git_repository_url
  local _dest
  _git_repository_url="$1"
  _dest="$2"
  if ! [[ -d "$_dest" ]]; then
    git clone "$_git_repository_url" "$_dest"
  else
    pushd "$_dest"
    git reset --hard HEAD
    git pull
    popd
  fi
}

prepare() {
  local _depends
  local _service_dir
  local _services
  local _voidfiles
  local _voidpkgs
  local _voidvault

  # fetch dependencies for mklive.sh
  _depends+=" git"
  _depends+=" liblz4"
  _depends+=" make"
  _depends+=" rsync"
  _depends+=" squashfs-tools"
  _depends+=" vim"
  sudo xbps-install $_depends

  # clean up service directory
  _service_dir="/tmp/include/etc/sv"
  if [[ -d "$_service_dir" ]]; then
    rm -rf "$_service_dir"
  fi

  # fetch void-mklive sources
  git_ensure_latest https://github.com/void-linux/void-mklive "$BUILD_DIR"

  # fetch repos to include
  _voidfiles="/tmp/include/opt/voidfiles"
  _voidpkgs="/tmp/include/opt/voidpkgs"
  _voidvault="/tmp/include/opt/voidvault"
  git_ensure_latest https://github.com/atweiden/voidfiles "$_voidfiles"
  git_ensure_latest https://github.com/atweiden/voidpkgs "$_voidpkgs"
  git_ensure_latest https://github.com/atweiden/voidvault "$_voidvault"

  # copy in etcfiles from atweiden/voidvault except shell timeout script
  rsync \
    --recursive \
    --perms \
    --exclude='profile.d' \
    --inplace \
    --human-readable \
    --progress \
    --delete \
    --force \
    --delete-after \
    --verbose \
    "$_voidvault/resources/" \
    /tmp/include

  # allow root logins on tty1
  sed \
    -i \
    -e 's/^#\(tty1\)/\1/' \
    /tmp/include/etc/securetty

  # prevent services from automatically starting on livecd
  _services=('acpid'
             'adb'
             'busybox-klogd'
             'busybox-ntpd'
             'busybox-syslogd'
             'chronyd'
             'cronie'
             'darkhttpd'
             'dhclient'
             'dhcpcd'
             'dhcpcd-eth0'
             'dmeventd'
             'dnsmasq'
             'fake-hwclock'
             'haveged'
             'hostapd'
             'i2pd'
             'iptables'
             'ip6tables'
             'lvmetad'
             'rsyncd'
             'sftpgo'
             'sshd'
             'tor'
             'unbound'
             'uuidd'
             'vnstatd'
             'wireguard'
             'wpa_supplicant'
             'zramen')

  if [[ -n "$WITH_BROADCOM_WL_DKMS" ]] || [[ -n "$WITH_B43_FIRMWARE" ]]; then
    _services+=('dbus')
    # from iwd package
    _services+=('ead')
    _services+=('iwd')
  fi

  for _service in ${_services[@]}; do
    mkdir -p "$_service_dir/$_service"
    touch "$_service_dir/$_service/down"
  done
}

# credit: leahneukirchen/hrmpf
enable_serial_console() {
  # add serial console support to grub efi boot menu entries
  vim \
    -c 'normal gg/^\s\+menuentry' \
    -c 'normal V$%y' \
    -c 'normal /^\s\+}/ep' \
    -c 'normal 0/(@@ARCH@@)/ea (Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    grub/grub_void.cfg.in
  vim \
    -c 'normal G?^\s\+menuentry' \
    -c 'normal V$%yP' \
    -c 'normal G?^\s\+menuentry' \
    -c 'normal 0/(RAM)/ea (Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    grub/grub_void.cfg.in
  sed \
    -i \
    -e 's/^\(\s\+terminal_input\).*/\1 console serial/' \
    -e 's/^\(\s\+terminal_output\).*/\1 console serial/' \
    grub/grub_void.cfg.in
  {
    echo insmod serial
    echo serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
  } >> grub/grub_void.cfg.in

  # add serial console support to isolinux boot menu entries
  vim \
    -c 'normal gg/^LABEL linux' \
    -c 'normal V/^APPENDyP' \
    -c 'normal j/^LABEL linux/eatext' \
    -c 'normal /^MENU LABEL/eA (Text mode/Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea modprobe.blacklist=bochs_drm nomodeset console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    isolinux/isolinux.cfg.in
  vim \
    -c 'normal G?^LABEL linuxram' \
    -c 'normal V/^APPENDyP' \
    -c 'normal j/^LABEL linuxram/eatext' \
    -c 'normal /^MENU LABEL/eA (Text mode/Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea modprobe.blacklist=bochs_drm nomodeset console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    isolinux/isolinux.cfg.in
  sed \
    -i \
    -e '1iSERIAL 0 115200' \
    isolinux/isolinux.cfg.in
  sed \
    -i \
    -e 's/vesamenu/menu/' \
    isolinux/isolinux.cfg.in \
    mklive.sh.in

  # allow root logins on ttyS0
  sed \
    -i \
    -e 's/^#\(ttyS0\)/\1/' \
    /tmp/include/etc/securetty
}

_set_xbps_mirror=
set_xbps_mirror() {
  if [[ -z "$_set_xbps_mirror" ]]; then
    echo XBPS_MIRROR="$XBPS_REPOSITORY" >> etc/conf \
      && _set_xbps_mirror=true
  fi
}

_xbps_src_binary_bootstrap=
xbps_src_binary_bootstrap() {
  if [[ -z "$_xbps_src_binary_bootstrap" ]]; then
    ./xbps-src binary-bootstrap \
      && _xbps_src_binary_bootstrap=true
  fi
}

# void mirrors don't distribute restricted packages like b43-firmware
pkg_b43_firmware() {
  pushd "$XBPS_REPOSITORY_LOCAL"
  set_xbps_mirror
  echo XBPS_ALLOW_RESTRICTED="yes" >> etc/conf
  xbps_src_binary_bootstrap
  ./xbps-src pkg b43-firmware
  popd
}

# patch wpa_supplicant for broadcom wireless without resorting to iwd
# https://bugzilla.redhat.com/show_bug.cgi?id=1703745
pkg_wpa_supplicant() {
  pushd "$XBPS_REPOSITORY_LOCAL"
  set_xbps_mirror
  xbps_src_binary_bootstrap
  sed -i 's/^\(CONFIG_MESH.*\)/#\1/' srcpkgs/wpa_supplicant/files/config
  ./xbps-src pkg wpa_supplicant
  popd
}

pkg_custom() {
  local _package

  _package="$1"

  pushd "$XBPS_REPOSITORY_LOCAL"
  set_xbps_mirror
  xbps_src_binary_bootstrap
  ./xbps-src -E pkg "$_package"
  popd
}

main() {
  local _mklive_opts
  local _package_files

  cd "$BUILD_DIR"
  prepare
  enable_serial_console
  make clean
  make

  _mklive_opts+=" -b base-minimal"
  _mklive_opts+=" -I /tmp/include"
  _package_files="$DIR/packages.txt"

  if [[ -n "$PATCH_WPA_SUPPLICANT" ]]; then
    pkg_wpa_supplicant
  fi

  if [[ -n "$WITH_B43_FIRMWARE" ]]; then
    pkg_b43_firmware
    _package_files+=" $DIR/packages.b43.txt"
  fi

  if [[ -n "$WITH_BROADCOM_WL_DKMS" ]]; then
    _package_files+=" $DIR/packages.broadcom.txt"
  fi

  if [[ -n "$WITH_CUSTOM_PACKAGES" ]]; then
    for _package in "$(grep '^[^#].' "$DIR/packages.custom.txt")"; do
      pkg_custom "$_package"
    done
    _package_files+=" $DIR/packages.custom.txt"
  fi

  if [[ -n "$WITH_CUSTOM_PACKAGES" ]] \
  || [[ -n "$PATCH_WPA_SUPPLICANT" ]] \
  || [[ -n "$WITH_B43_FIRMWARE" ]]; then
    _mklive_opts+=" -r $XBPS_REPOSITORY_LOCAL"
  fi

  export XBPS_REPOSITORY="--repository=$XBPS_REPOSITORY --repository=$XBPS_REPOSITORY/nonfree"
  sudo --preserve-env=XBPS_REPOSITORY \
    ./mklive.sh \
      -p "$(grep '^[^#].' $_package_files)" \
      $_mklive_opts
}

main
