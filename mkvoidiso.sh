#!/bin/bash

# ==============================================================================
# constants {{{

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

Options:
  -h, --help                Show this help text
  -v, --version             Show program version
  -R, --repository          Prioritized remote repository for stock packages
  -L, --local-repository    Path to local repository for custom packages
  -B, --build-dir           Path to local void-linux/void-mklive
  --patch-wpa-supplicant    Add wpa_supplicant built without CONFIG_MESH
  --with-b43-firmware       Add b43-firmware built locally and iwd
  --with-broadcom-wl-dkms   Add broadcom-wl-dkms and iwd

Examples

  # Generate ISO
  ./mkvoidiso.sh

  # Generate ISO with broadcom-wl-dkms and iwd
  ./mkvoidiso.sh --with-broadcom-wl-dkms

  # Generate ISO with broadcom-wl-dkms, iwd and patched wpa_supplicant
  ./mkvoidiso.sh --with-broadcom-wl-dkms --patch-wpa-supplicant
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

prepare() {
  local _services

  # fetch dependencies for mklive.sh
  sudo xbps-install git liblz4 make squashfs-tools vim

  # fetch void-mklive sources
  if ! [[ -d "$BUILD_DIR" ]]; then
    git clone https://github.com/void-linux/void-mklive "$BUILD_DIR"
  fi

  # fetch repos to include
  git clone https://github.com/atweiden/voidfiles /tmp/include/opt/voidfiles
  git clone https://github.com/atweiden/voidpkgs /tmp/include/opt/voidpkgs
  git clone https://github.com/atweiden/voidvault /tmp/include/opt/voidvault

  # copy in etcfiles from atweiden/voidvault
  find /tmp/include/opt/voidvault/resources -mindepth 1 -maxdepth 1 \
    -exec cp -R '{}' /tmp/include \;

  # rm shell timeout script on livecd
  rm -rf /tmp/include/etc/profile.d

  # allow root logins on tty1
  sed \
    -i \
    -e 's/^#\(tty1\)/\1/' \
    /tmp/include/etc/securetty

  # prevent services from automatically starting on livecd
  _services=('acpid'
             'busybox-klogd'
             'busybox-ntpd'
             'busybox-syslogd'
             'chronyd'
             'cronie'
             'darkhttpd'
             'dhclient'
             'dhcpcd'
             'dhcpcd-eth0'
             'dnsmasq'
             'fake-hwclock'
             'haveged'
             'hostapd'
             'iptables'
             'ip6tables'
             'rsyncd'
             'sftpgo'
             'sshd'
             'tor'
             'unbound'
             'uuidd'
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
    mkdir -p "/tmp/include/etc/sv/$_service"
    touch "/tmp/include/etc/sv/$_service/down"
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

main() {
  local _mklive_opts
  local _package_files

  cd "$BUILD_DIR"
  prepare
  enable_serial_console
  make

  _mklive_opts="-I /tmp/include"
  _package_files="packages.txt"

  if [[ -n "$PATCH_WPA_SUPPLICANT" ]]; then
    pkg_wpa_supplicant
  fi

  if [[ -n "$WITH_B43_FIRMWARE" ]]; then
    pkg_b43_firmware
    _package_files+=" packages.b43.txt"
  fi

  if [[ -n "$WITH_BROADCOM_WL_DKMS" ]]; then
    _package_files+=" packages.broadcom.txt"
  fi

  if [[ -n "$PATCH_WPA_SUPPLICANT" ]] || [[ -n "$WITH_B43_FIRMWARE" ]]; then
    _mklive_opts+=" -r $XBPS_REPOSITORY_LOCAL"
  fi

  export XBPS_REPOSITORY="--repository=$XBPS_REPOSITORY --repository=$XBPS_REPOSITORY/nonfree"
  sudo --preserve-env=XBPS_REPOSITORY \
    ./mklive.sh \
      -p "$(grep '^[^#].' $_package_files)" \
      $_mklive_opts
}

main
