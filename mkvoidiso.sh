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

# path to file containing custom packages
readonly CUSTOM_PACKAGE_FILE="$DIR/packages.custom.txt"

# make vim scripting results vimrc-independent
readonly VIMOPTS="-X -u NONE -U NONE"

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
                 [--with-broadcom] [--with-custom-packages]

Options:
  -h, --help                      Show this help text
  -v, --version                   Show program version
  -R, --repository <url>          Prioritized remote repository for stock packages
  -L, --local-repository <path>   Path to local repository for custom packages
  -B, --build-dir <path>          Path to local void-linux/void-mklive
  --with-broadcom                 Include broadcom-wl-dkms and iwd
  --with-custom-packages          Include packages in packages.custom.txt built locally

Examples

  # Generate ISO
  ./mkvoidiso.sh

  # Generate ISO with broadcom-wl-dkms and iwd
  ./mkvoidiso.sh --with-broadcom

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
    --with-broadcom)
      WITH_BROADCOM=true
      shift
      ;;
    --with-custom-packages)
      WITH_CUSTOM_PACKAGES=true
      shift
      ;;
    -*)
      # unknown option
      USAGE
      exit 1
      ;;
    *)
      # unknown command
      USAGE
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
  local _void_docs
  local _voidfiles
  local _voidiso
  local _voidpkgs
  local _voidvault

  # fetch dependencies for mklive.sh
  _depends+=" git"
  _depends+=" liblz4"
  _depends+=" make"
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
  _void_docs="/tmp/include/opt/void-docs"
  _voidfiles="/tmp/include/opt/voidfiles"
  _voidiso="/tmp/include/opt/voidiso"
  _voidpkgs="/tmp/include/opt/voidpkgs"
  _voidvault="/tmp/include/opt/voidvault"
  git_ensure_latest https://github.com/void-linux/void-docs "$_void_docs"
  git_ensure_latest https://github.com/atweiden/voidfiles "$_voidfiles"
  git_ensure_latest https://github.com/atweiden/voidiso "$_voidiso"
  git_ensure_latest https://github.com/atweiden/voidpkgs "$_voidpkgs"
  git_ensure_latest https://github.com/atweiden/voidvault "$_voidvault"

  # copy in etcfiles from atweiden/voidvault
  find "$_voidvault/resources" -mindepth 1 -maxdepth 1 -exec \
    basename '{}' \; | while read -r _f; do rm -rf "/tmp/include/$_f"; done
  find "$_voidvault/resources" -mindepth 1 -maxdepth 1 -exec \
    cp -R '{}' /tmp/include \;

  # rm shell timeout script on livecd
  rm -rf /tmp/include/etc/profile.d

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
             'usbguard'
             'uuidd'
             'vnstatd'
             'wireguard'
             'wpa_supplicant'
             'zramen')

  if [[ -n "$WITH_BROADCOM" ]]; then
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

enable_serial_console_grub() {
  vim \
    $VIMOPTS \
    -c 'normal gg/^\s\+menuentry' \
    -c 'normal V$%y' \
    -c 'normal /^\s\+}/ep' \
    -c 'normal 0/(@@ARCH@@)/ea (Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    grub/grub_void.cfg.in
  vim \
    $VIMOPTS \
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

}

enable_serial_console_isolinux() {
  vim \
    $VIMOPTS \
    -c 'normal gg/^LABEL linux' \
    -c 'normal V/^APPENDyP' \
    -c 'normal j/^LABEL linux/eatext' \
    -c 'normal /^MENU LABEL/eA (Text mode/Serial)' \
    -c 'normal /@@BOOT_CMDLINE@@/ea modprobe.blacklist=bochs_drm nomodeset console=tty0 console=ttyS0,115200n8' \
    -c 'wq' \
    isolinux/isolinux.cfg.in
  vim \
    $VIMOPTS \
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
}

enable_serial_console_securetty() {
  sed \
    -i \
    -e 's/^#\(ttyS0\)/\1/' \
    /tmp/include/etc/securetty
}

# credit: leahneukirchen/hrmpf
enable_serial_console() {
  # add serial console support to grub efi boot menu entries
  enable_serial_console_grub

  # add serial console support to isolinux boot menu entries
  enable_serial_console_isolinux

  # allow root logins on ttyS0
  enable_serial_console_securetty
}

# credit: leahneukirchen/hrmpf
include_memtest86plus() {
  # add memtest86+ to isolinux boot menu
  sed \
    -i \
    -e '/chain/a\ \ \ \ cp -f $SYSLINUX_DATADIR/memdisk "$ISOLINUX_DIR"' \
    mklive.sh.in
  vim \
    $VIMOPTS \
    -c 'normal gg/^generate_initramfs$%O    if [ "$BOOT_FILES" ]; then cp $BOOT_FILES $BOOT_DIR; fi' \
    -c 'normal /^while getopts/e' \
    -c 'normal /:b/ea:B' \
    -c 'normal /C)O        B) BOOT_FILES="$BOOT_FILES $OPTARG";;' \
    -c 'wq' \
    mklive.sh.in
  vim \
    $VIMOPTS \
    -c 'normal gg/^LABEL c' \
    -c 'normal V/^APPENDyP' \
    -c 'normal /cCmemtest86+' \
    -c 'normal /^MENU LABEL/e2lCmemtest86+ 5.31b' \
    -c 'normal /^COM32CKERNEL memdisk' \
    -c 'normal oINITRD /boot/memtest86+-5.31b.iso' \
    -c 'normal /^APPEND/e2lCiso' \
    -c 'wq' \
    isolinux/isolinux.cfg.in
}

facilitate_custom_packages() {
  vim \
    $VIMOPTS \
    -c 'normal gg/\s\+mount_pseudofso    # install custom packages first' \
    -c 'normal o    LANG=C XBPS_ARCH=$BASE_ARCH "${XBPS_INSTALL_CMD}" -U -r "$ROOTFS" \' \
    -c 'normal o        ${XBPS_REPOSITORY_LOCAL} ${XBPS_REPOSITORY} -i -c "$XBPS_REPOSITORY_LOCAL/hostdir/repocache-$BASE_ARCH" -y $PACKAGE_LIST_CUSTOM' \
    -c 'normal o    [ $? -ne 0 ] && die "Failed to install local repo custom packages $PACKAGE_LIST_CUSTOM"' \
    -c 'normal /^while getopts/e' \
    -c 'normal /:r/ea:l' \
    -c 'normal /:p/ea:P' \
    -c 'normal /r)o        l) XBPS_REPOSITORY_LOCAL="--repository=$OPTARG $XBPS_REPOSITORY_LOCAL";;' \
    -c 'normal /p)o        P) PACKAGE_LIST_CUSTOM="$OPTARG";;' \
    -c 'wq' \
    mklive.sh.in
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
  include_memtest86plus
  facilitate_custom_packages
  make clean
  make

  _mklive_opts+=" -b base-minimal"
  _mklive_opts+=" -r $XBPS_REPOSITORY"
  _mklive_opts+=" -r $XBPS_REPOSITORY/nonfree"
  _mklive_opts+=" -I /tmp/include"
  _mklive_opts+=" -B $DIR/resources/memtest86+-5.31b.iso"
  _mklive_opts+=" -o $DIR/void.iso"
  _package_files="$DIR/packages.txt"

  if [[ -n "$WITH_BROADCOM" ]]; then
    _package_files+=" $DIR/packages.broadcom.txt"
  fi

  if [[ -n "$WITH_CUSTOM_PACKAGES" ]]; then
    for _package in $(grep --no-filename '^[^#].' "$CUSTOM_PACKAGE_FILE"); do
      pkg_custom "$_package"
    done
    _mklive_opts+=" -l $XBPS_REPOSITORY_LOCAL/hostdir/binpkgs"
    _mklive_opts+=" -l $XBPS_REPOSITORY_LOCAL/hostdir/binpkgs/nonfree"
    sudo ./mklive.sh \
      -p "$(grep --no-filename '^[^#].' $_package_files)" \
      -P "$(grep --no-filename '^[^#].' $CUSTOM_PACKAGE_FILE)" \
      $_mklive_opts
  else
    sudo ./mklive.sh \
      -p "$(grep --no-filename '^[^#].' $_package_files)" \
      $_mklive_opts
  fi
}

main
