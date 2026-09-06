#!/bin/sh
# 烧完之后对着实机跑一遍。从开发机执行,走 ssh,板子上不需要装任何东西。
#
#     ci/board-acceptance.sh [板子地址]
#
# 为什么要有这个:CI 只验得了「包在不在、文件在不在」,验不了「它能不能工作」。
# podman 在镜像里躺了很久,拉得下镜像,但从来没在板子上跑起来过一个容器 ——
# 因为没有任何一步去跑。这个脚本就是那一步。
set -eu

HOST=${1:-192.168.0.114}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 root@$HOST"

pass=0
fail=0
check() {
	name=$1
	shift
	if $SSH "$@" >/tmp/ba.out 2>&1; then
		printf '  ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf '  FAIL %s\n' "$name"
		sed 's/^/       | /' /tmp/ba.out
		fail=$((fail + 1))
	fi
}

echo "== $HOST"

check "ssh 公钥登录"        true
check "有线 end1 up"        '[ "$(cat /sys/class/net/end1/operstate)" = up ]'
check "无线 wlu1i2 up"      '[ "$(cat /sys/class/net/wlu1i2/operstate)" = up ]'
check "出网"                'ping -c2 -W3 223.5.5.5'
check "DNS"                 'ping -c2 -W3 www.baidu.com'

# 时钟没同步 → TLS 全挂 → 镜像拉不动,而报错长得像证书问题。先验它,
# 后面容器那步失败时才知道该不该往这个方向查。
check "NTP 已同步"          'timedatectl | grep -q "System clock synchronized: yes"'

check "overlay 存储驱动"    'podman info --format "{{.Store.GraphDriverName}}" | grep -qx overlay'

# 真跑一个容器 —— 这一步才是整个脚本存在的理由。前面全过、这里挂过的
# 情况已经发生过一次(缺 BRIDGE / POSIX_MQUEUE)。
check "拉镜像"              'podman pull -q docker.io/library/busybox:latest'
check "跑容器(默认网络)"   'podman run --rm docker.io/library/busybox:latest true'
check "容器出网"            'podman run --rm docker.io/library/busybox:latest ping -c2 -W3 223.5.5.5'

echo
echo "通过 $pass,失败 $fail"
[ $fail -eq 0 ]
