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

# 用 quay.io 不用 docker.io:实测 registry-1.docker.io 从本网络连不上
# (i/o timeout,且 DNS 把它解析到一个 facebook 的地址),而 quay.io 与
# ghcr.io 的 /v2/ 都正常返回 401 —— 那是未认证探测的健康响应,不是故障。
# 这里要验的是"容器能不能跑",不该被镜像源可达性拖下水。
IMG=quay.io/libpod/busybox:latest

# 真跑一个容器 —— 这一步才是整个脚本存在的理由。前面全过、这里挂过的情况
# 已经发生过两次:先是缺 BRIDGE / POSIX_MQUEUE,再是缺 iptables 的
# xt_comment(见 docs/known-issues/check-config-misses-iptables-extensions.md)。
check "拉镜像"              "podman pull -q $IMG"
check "跑容器(默认网络)"   "podman run --rm $IMG true"
check "容器出网"            "podman run --rm $IMG ping -c2 -W3 223.5.5.5"

# ---- OTA 只读三例(2026-09-26-ota-phase23.md Task 7):不触发安装、不写
# 任何槽位状态。拉真 bundle、跑升级、断电回退属上板手册 §C 的人验项,
# 不在这里做;这里只验"分发链与客户端的本体在位、可读"。
OTA_BASE_URL=${OTA_BASE_URL:-https://pub-b68514853b324ecaa66d426bae01a369.r2.dev}

# ① 分发链匿名可达且 version 字段可解析。板上没装 jq(镜像无此包,ota-update
#    的 json_str 同款 sed 截字段),不为解析引入新依赖。
check "OTA latest.json 匿名可达且 version 可解析" \
	"curl -fsS --max-time 15 '$OTA_BASE_URL/ota/stable/latest.json' | sed -n 's/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' | grep -q ."

# ② RAUC 客户端本体在位且能读槽位(status 是只读子命令)
check "rauc 已装且能读状态" 'command -v rauc && rauc status'

# ③ 槽位变量与本地/远端版本并列打印,供人核对。自动断言只到"非空/可读":
#    本地与远端版本是否一致取决于升级是否已发生,只读用例判不了 —— 那个
#    对账是上板手册 §C1 的实机门,这里把三行证据摆在一起省得人拼。
if $SSH 'fw_printenv BOOT_ORDER' >/tmp/ba-bootorder 2>&1 && [ -s /tmp/ba-bootorder ]; then
	printf '  ok   %s\n' "BOOT_ORDER 非空"
	pass=$((pass + 1))
	printf '       | %-10s: %s\n' "BOOT_ORDER" "$(cat /tmp/ba-bootorder)"
	printf '       | %-10s: %s\n' "本地版本" "$($SSH 'cat /etc/ota-version' 2>/dev/null || true) (/etc/ota-version)"
	printf '       | %-10s: %s\n' "远端版本" "$($SSH "curl -fsS --max-time 15 '$OTA_BASE_URL/ota/stable/latest.json'" 2>/dev/null | sed -n 's/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p') (latest.json)"
else
	printf '  FAIL %s\n' "BOOT_ORDER 非空"
	sed 's/^/       | /' /tmp/ba-bootorder
	fail=$((fail + 1))
fi

echo
echo "通过 $pass,失败 $fail"
[ $fail -eq 0 ]
