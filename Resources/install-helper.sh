#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$EUID" -eq 0 ] || { echo '需要管理员授权'; exit 77; }
[ "$#" -eq 2 ] || exit 64
account="$1"; ip="$2"
[[ "$account" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || exit 64
[[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || exit 64
IFS=. read -r a b c d <<< "$ip"
(( a >= 1 && a <= 223 && a != 127 && b <= 255 && c <= 255 && d >= 1 && d <= 254 )) || exit 64
id "$account" >/dev/null
resources="$(cd "$(dirname "$0")" && pwd)"
helper=/Library/PrivilegedHelperTools/cn.wangshan.home-ip
config=/Library/PrivilegedHelperTools/cn.wangshan.home-ip.conf
rule=/etc/sudoers.d/cn-wangshan-home-ip
mkdir -p /Library/PrivilegedHelperTools /etc/sudoers.d
# The only writable address is a root-owned, single-line IPv4 value.
tmp_config=$(mktemp /Library/PrivilegedHelperTools/home-ip-conf.XXXXXX)
tmp_rule=$(mktemp /etc/sudoers.d/home-ip.XXXXXX)
trap 'rm -f "$tmp_config" "$tmp_rule"' EXIT
printf '%s\n' "$ip" > "$tmp_config"
chown root:wheel "$tmp_config"
chmod 644 "$tmp_config"
printf '%s ALL=(root) NOPASSWD: %s home, %s dhcp\n' "$account" "$helper" "$helper" > "$tmp_rule"
chmod 440 "$tmp_rule"
/usr/sbin/visudo -cf "$tmp_rule"
chown root:wheel "$tmp_rule"
install -o root -g wheel -m 755 "$resources/network-helper" "$helper"
mv -f "$tmp_config" "$config"
mv -f "$tmp_rule" "$rule"
rm -f /etc/sudoers.d/cn.wangshan.home-ip
/usr/sbin/visudo -c
/usr/bin/sudo -u "$account" /usr/bin/sudo -n -l "$helper" home >/dev/null
echo '网络助手安装完成，免密码权限检查通过'
