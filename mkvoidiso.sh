#!/bin/bash

readonly MKLIVE="$PWD/void-mklive"
readonly REMOTE="https://ftp.swin.edu.au/voidlinux/current"
readonly LOCAL="/tmp/include/opt/voidpkgs"

USAGE() {
  read -r -d '' _usage_string <<EOF
Usage:
  mkvoidiso [-h|--help] [<broadcom|b43> [patch_wpa_supplicant]]

Options:
  -h, --help      Show this help text

Arguments:
  broadcom
    Include broadcom-wl-dkms and iwd in generated ISO
  b43
    Include b43-firmware built locally and iwd in generated ISO (not recommended)
  patch_wpa_supplicant
    Include wpa_supplicant built without CONFIG_MESH setting in generated ISO

Examples

    # Generate ISO
    mkvoidiso

    # Generate ISO with broadcom-wl-dkms and iwd
    mkvoidiso broadcom patch_wpa_supplicant

    # Generate ISO with broadcom-wl-dkms, iwd and patched wpa_supplicant
    mkvoidiso broadcom patch_wpa_supplicant
EOF

  echo "$_usage_string"
}

prepare() {
  local _services

  # fetch dependencies for mklive.sh
  sudo xbps-install git liblz4 make squashfs-tools

  # fetch void-mklive sources
  git clone https://github.com/void-linux/void-mklive

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

  if [[ "$1" =~ broadcom|b43 ]]; then
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

# patch wpa_supplicant for broadcom wireless without resorting to iwd
# https://bugzilla.redhat.com/show_bug.cgi?id=1703745
pkg_wpa_supplicant() {
  pushd "$LOCAL"
  echo XBPS_MIRROR="$REMOTE" >> etc/conf
  ./xbps-src binary-bootstrap
  sed -i 's/^\(CONFIG_MESH.*\)/#\1/' srcpkgs/wpa_supplicant/files/config
  ./xbps-src pkg wpa_supplicant
  popd
}

# void mirrors don't distribute restricted packages like b43-firmware
pkg_b43_firmware() {
  pushd "$LOCAL"
  echo XBPS_MIRROR="$REMOTE" >> etc/conf
  echo XBPS_ALLOW_RESTRICTED="yes" >> etc/conf
  ./xbps-src binary-bootstrap
  ./xbps-src pkg b43-firmware
  popd
}

main() {
  cd "$MKLIVE"

  prepare "$1"
  enable_serial_console

  make

  if [[ "$1" =~ broadcom|b43 ]]; then
    # patch wpa_supplicant
    if [[ -n "$2" ]]; then
      pkg_wpa_supplicant
    fi
  fi

  export XBPS_REPOSITORY="--repository=$REMOTE --repository=$REMOTE/nonfree"
  # include broadcom-wl-dkms, iwd, patched wpa_supplicant if applicable
  if [[ "$1" =~ broadcom ]]; then
    sudo --preserve-env=XBPS_REPOSITORY \
      ./mklive.sh \
        -p "$(grep '^[^#].' packages.txt packages.broadcom.txt)" \
        -I /tmp/include
  # include b43-firmware, iwd, patched wpa_supplicant if applicable
  elif [[ "$1" =~ b43 ]]; then
    pkg_b43_firmware
    sudo --preserve-env=XBPS_REPOSITORY \
      ./mklive.sh \
        -p "$(grep '^[^#].' packages.txt packages.b43.txt)" \
        -I /tmp/include
  # just include packages listed in packages.txt
  else
    sudo --preserve-env=XBPS_REPOSITORY \
      ./mklive.sh \
        -p "$(grep '^[^#].' packages.txt)" \
        -I /tmp/include
  fi
}

main "$@"
