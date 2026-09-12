#!/bin/sh
# OTA 阶段 0 五项上板只读验证(spec:yocto-rk3566-docs/plans/ota.md「阶段 0」)。
# 从开发机执行,走 ssh,板子上不用装任何东西:
#
#     ci/board-precheck.sh [板子地址] 2>&1 | tee ota-phase0.txt
#
# 跑完按脚本末尾打印的清单去 u-boot 串口做 saveenv 实验,断电重启后
# 再重跑一次本脚本 —— 末尾的 eMMC 搜索会给出探针变量的落盘偏移,
# 把第 2 项(env 持久化)和第 3 项(实际偏移)一起钉死。
#
# 只读保证:板上只读 /proc /sys 和 /dev/mmcblk*(dd if=,不写块设备)。
# 唯一的"写"在 u-boot 串口手工步骤:setenv 一个临时变量,见末尾打印。
#
# 为什么失败不当错误:这是取证不是验收 —— hwclock 报错、curl 301/404
# 都是结论本身。所以不设 -e,输出整体回传,由 ota.md 的阶段 0 表格判读。
set -u

HOST=${1:-192.168.0.114}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 root@$HOST"
R2HOST=pub-b68514853b324ecaa66d426bae01a369.r2.dev
R2BASE=https://$R2HOST
# u-boot env 探针:串口里 setenv precheck_ok phase0;saveenv 后它若真落了盘,
# 下面的 eMMC 搜索就能按字节偏移指认 env 的真实位置。
MARKER=precheck_ok=phase0

section() {
	echo
	echo "======== $* ========"
}

run() {
	echo "\$ $*"
	$SSH "$@" 2>&1 || true
	echo
}

echo "OTA 阶段 0 上板预检 · $HOST · $(date '+%F %T')"
echo "整体保存:ci/board-precheck.sh 2>&1 | tee ota-phase0.txt(输出是回写 ota.md 的原料)"

if ! $SSH true 2>/dev/null; then
	echo "!! ssh 连不上 root@$HOST —— 板子开机了吗?无线 DHCP(192.168.0.114)或直连(192.168.9.1)选对了?"
	exit 1
fi

section "0/5 对照组:这块板子是谁、跑的什么"
run 'uname -a'
run 'cat /proc/device-tree/model; echo'

section "第 1 项 RTC:hwclock -r 与 /dev/rtc*(判据:有结论即可;无 RTC → 时钟全靠 timesyncd)"
run 'hwclock -r'
run 'ls -l /dev/rtc* 2>&1'
run 'date'
# dmesg 给出机制级证据:常见 RTC(hym8563/rk808)有没有被 probe
run 'dmesg | grep -iE "hym8563|rk808|rk809|\brtc\b" | head -20'
run 'timedatectl 2>&1 | grep -E "synchronized|NTP" '

section "第 4 项 root= 形态(判据:决定 wks 里 RK_ROOTDEV_UUID 怎么给 a/b 槽)"
run 'cat /proc/cmdline'
run 'blkid 2>/dev/null || ls -l /dev/disk/by-partuuid 2>&1'
run 'cat /proc/partitions'
run 'for d in /sys/block/mmcblk*/device/type; do echo "$d = $(cat "$d")"; done'
run 'findmnt -n -o SOURCE / || mount | grep " on / "'

section "第 5 项 r2.dev 板端可达性与 http 行为(判据:301?200?决定拉包走 http 还是 https)"
# r2.dev 关闭目录列举,sstate/ 打出 404/403 也算"通" —— 要的是 TLS/HTTP 层有答案;
# 不带 -L 的裸 http 请求暴露重定向行为,这是要不要依赖时钟(https→证书)的依据。
run "curl -sS -o /dev/null -w 'http=%{http_code} redirect=%{redirect_url} time=%{time_total}\n' http://$R2HOST/sstate/"
run "curl -sS -I $R2BASE/sstate/ | head -8"
run "command -v curl wget"

section "第 5 项附:开发机侧对照(同一 URL,区分板子问题还是网络问题)"
curl -sS -o /dev/null -w "开发机 http=%{http_code} redirect=%{redirect_url} time=%{time_total}\n" \
	http://$R2HOST/sstate/ || true
curl -sS -o /dev/null -w "开发机 https=%{http_code} time=%{time_total}\n" \
	$R2BASE/sstate/ || true

section "第 3 项 fw_env 偏移:板上实证(源码侧参考值见下,不得当事实写进 wks)"
echo "源码侧(pinned SHA 已查证,仅供参考):ENV_OFFSET=0x3f8000 ENV_SIZE=0x8000 SYS_MMC_ENV_DEV=0"
echo "实证方式:在 eMMC 上搜探针串 \"$MARKER\"(串口 saveenv 后重跑本脚本即可命中)"
echo "          另搜 bootdelay=:任何曾落盘过的 env 都含它,可指认 env 区域,哪怕探针还没写"
DEVS=$($SSH 'ls -1 /dev/mmcblk[0-9] /dev/mmcblk[0-9]boot[0-1] 2>/dev/null')
[ -n "$DEVS" ] || echo "!! 板上没看到 /dev/mmcblk* —— 记录这条,本身是异常结论"
TMPBIN=$(mktemp)
trap 'rm -f "$TMPBIN"' EXIT
for dev in $DEVS; do
	case $dev in
		*boot*) count=16384 ;;   # boot0/boot1 一般 4MB,整个 dump
		*)      count=65536 ;;   # 用户区前 32MB,足够盖住 0x3f8000≈4MB
	esac
	if $SSH "dd if=$dev bs=512 count=$count 2>/dev/null" >"$TMPBIN" 2>/dev/null && [ -s "$TMPBIN" ]; then
		for pat in "$MARKER" bootdelay=; do
			off=$(grep -abo -- "$pat" "$TMPBIN" | head -1 | cut -d: -f1)
			if [ -n "$off" ]; then
				printf '  命中 %s @ %s:字节 %s = 0x%x(扇区 %s)\n' \
					"$pat" "$dev" "$off" "$off" "$((off / 512))"
			else
				printf '  %s 前 %sMB 内没有 %s\n' "$dev" "$((count * 512 / 1024 / 1024))" "$pat"
			fi
		done
	else
		echo "  $dev:dd 读取失败(原样记录;boot 分区被只读挡住也是一种证据)"
	fi
done

section "附带(HANDOFF 待查证):内核配置重烧复验(CI 验不了最终 .config)"
run "zcat /proc/config.gz | grep -E '^CONFIG_(CGROUP_BPF|OVERLAY_FS|POSIX_MQUEUE|BRIDGE|VETH)='"

section "第 2 项 u-boot env 持久化与选槽能力(串口手工 —— 全案成立的前提,最后做)"
cat <<'EOF'
串口接好,板子断电重启,在 u-boot 倒计时阶段按 Ctrl+C 打进提示符,逐条执行
并把输出抄进保存的输出文件:

  version
  printenv bootdelay bootcmd bootcount altbootcmd BOOT_ORDER upgrade_available
  help saveenv setexpr
  mmc list
  setenv precheck_ok phase0
  saveenv                 ← 若报错,原样抄 —— 这就是第 2 项的结论
  printenv precheck_ok

然后断电、重新上电,再打进 u-boot 提示符:

  printenv precheck_ok    ← 变量还在 = env 持久化成立(主案);没了/报错 = 退路触发

最后让板子正常启动进 Linux,重跑一次本脚本:
末尾"第 3 项"的搜索应给出 precheck_ok=phase0 的落盘字节偏移 —— 那就是 env 真实位置。
EOF

echo
echo "======== 跑完了:把整份输出(含串口部分抄录)交回 ========"
