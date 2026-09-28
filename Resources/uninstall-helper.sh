#!/bin/bash
set -euo pipefail
[ "$EUID" -eq 0 ] || exit 77
/usr/sbin/networksetup -setdhcp 'Wi-Fi'
/bin/rm -f /etc/sudoers.d/cn.wangshan.home-ip /etc/sudoers.d/cn-wangshan-home-ip /Library/PrivilegedHelperTools/cn.wangshan.home-ip /Library/PrivilegedHelperTools/cn.wangshan.home-ip.conf
