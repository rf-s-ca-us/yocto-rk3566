# 跨槽配置的共同规则,被 mount-persistent 与 rauc-slot-hook 一起 source。
# 允许名单就这四棵目录。秘密文件收成 0600,目录收成 0700;
# 只去掉组/其他权限,不给文件加任何权限。

persist_log() {
	echo "persistent: $*"
}

# 树上至少有一个普通文件或符号链接才算有配置。镜像自带的空目录不算。
persist_has_payload() {
	dir=$1
	[ -d "$dir" ] && [ ! -L "$dir" ] || return 1
	[ -n "$(find "$dir" -mindepth 1 \( -type f -o -type l \) -print 2>/dev/null | head -n 1)" ]
}

# 选出要拷进新槽的那一份。空串表示不拷。
# 已经挂到 data 上、并且里面有文件:那份就是共享存储,新槽开机再 bind,这里不重复拷。
# 挂载点是空的,或者本槽根本没有文件:不能用它盖住另一槽 salvaged 的配置。
persist_choose_source() {
	live=$1
	salvage=$2
	if persist_is_mount "$live" && persist_has_payload "$live"; then
		return 0
	fi
	if ! persist_is_mount "$live" && persist_has_payload "$live"; then
		printf '%s\n' "$live"
		return 0
	fi
	if [ -n "$salvage" ] && persist_has_payload "$salvage"; then
		printf '%s\n' "$salvage"
		return 0
	fi
}

# 只在目的端真有文件时才 bind。空目录绑上去之后,钩子会把它当成
# 「已经迁到 data」,不再去看另一槽里的配置。
persist_should_bind() {
	persist_has_payload "$1"
}

# $1 必须是 /proc/mounts 第二列的挂载点(精确匹配,不是前缀)。
persist_is_mount() {
	awk -v p="$1" '$2 == p { found = 1 } END { exit (found ? 0 : 1) }' /proc/mounts
}

# 独立 data 挂载才允许把配置放上去。和根文件系统同一块设备时,
# bind 只是把根文件系统上的目录又挂了一次,换槽照样丢。
persist_data_is_separate() {
	root_dev=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
	data_dev=$(awk '$2 == "/var/lib/containers" { print $1; exit }' /proc/mounts)
	[ -n "$data_dev" ] && [ "$data_dev" != "$root_dev" ]
}

# 槽位挂载点必须落在 RAUC 的 mount prefix 下面,且自己是一个挂载点。
# 先 realpath,挡掉 /mnt/rauc/../../etc 这种逃逸。
persist_slot_guard() {
	slot=$1
	[ -n "$slot" ] || return 1
	prefix=$(readlink -f "${RAUC_MOUNT_PREFIX:-/mnt/rauc}" 2>/dev/null || true)
	canon=$(readlink -f "$slot" 2>/dev/null || true)
	[ -n "$prefix" ] && [ -n "$canon" ] || return 1
	[ "$canon" != "/" ] || return 1
	[ "$canon" != "$prefix" ] || return 1
	case "$canon" in
		"$prefix"/*) ;;
		*) return 1 ;;
	esac
	persist_is_mount "$canon"
}

# 把 live 目录的内容拷进 dest。dest 已有任何条目则整棵不动。
# live 是挂载点或符号链接时也不动:前者已经是共享存储,后者可能指到别处。
# 失败返回非 0,调用方不得接着 bind(否则空目录会盖住根文件系统上的原件)。
persist_seed_dir() {
	live=$1
	dest=$2
	if [ -L "$live" ]; then
		persist_log "跳过符号链接 $live"
		return 0
	fi
	if persist_is_mount "$live"; then
		persist_log "跳过已挂载的 $live"
		return 0
	fi
	if [ ! -d "$dest" ]; then
		persist_log "目的 $dest 不是目录"
		return 1
	fi
	if [ -n "$(find "$dest" -mindepth 1 -print 2>/dev/null | head -n 1)" ]; then
		persist_log "$dest 已有内容,不覆盖"
		return 0
	fi
	if [ ! -d "$live" ]; then
		return 0
	fi
	if [ -z "$(find "$live" -mindepth 1 -print 2>/dev/null | head -n 1)" ]; then
		return 0
	fi
	cp -a "$live"/. "$dest"/
	chmod -R go-rwx "$dest"
}

# 拷进新槽。和 seed 不同:新槽是刚装的镜像,目的端允许被盖上。
# 源是挂载点时不拷——内容已经在 data 上,新槽开机再 bind 同一处。
persist_copy_one() {
	live=$1
	dest=$2
	if [ -L "$live" ]; then
		persist_log "跳过符号链接 $live"
		return 0
	fi
	if persist_is_mount "$live"; then
		persist_log "跳过已挂载的 $live(新槽会 bind 同一存储)"
		return 0
	fi
	if [ ! -d "$live" ]; then
		return 0
	fi
	if [ -z "$(find "$live" -mindepth 1 -print 2>/dev/null | head -n 1)" ]; then
		return 0
	fi
	mkdir -p "$dest"
	cp -a "$live"/. "$dest"/
	chmod -R go-rwx "$dest"
}

# $1 是「看起来像根」的目录:真根用空前缀调用时传 "/",槽位则传挂载点。
# 路径拼接时避免出现双斜杠以外的意外;下面直接拼 "$root/etc/..."。
persist_tighten_live() {
	root=$1
	for d in \
		"$root/etc/wpa_supplicant" \
		"$root/etc/mihomo" \
		"$root/root/.hermes" \
		"$root/root/.local" \
		"$root/root/.local/state" \
		"$root/root/.local/state/hermes"
	do
		if [ -d "$d" ] && [ ! -L "$d" ]; then
			chmod 0700 "$d"
		fi
	done
	if [ -f "$root/etc/wpa_supplicant/wpa_supplicant-wlan.conf" ]; then
		chmod 0600 "$root/etc/wpa_supplicant/wpa_supplicant-wlan.conf"
	fi
	if [ -f "$root/etc/mihomo/config.yaml" ]; then
		chmod 0600 "$root/etc/mihomo/config.yaml"
	fi
	if [ -f "$root/root/.hermes/.env" ]; then
		chmod 0600 "$root/root/.hermes/.env"
	fi
}

# 安装前把「即将被整槽覆盖」的那份配置先抄出来。跑在写盘之前,
# 失败就让 RAUC 中止,旧槽上的文件还在。
# 落点在正在运行的根文件系统上,不进 tmpfs:Hermes 状态可能比内存大,
# 拷不进去就失败返回,不能先把有配置的槽擦掉。
persist_salvage_root() {
	printf '%s\n' "${PERSIST_SALVAGE:-/var/lib/lubancat-persist-salvage}"
}

persist_salvage_clear() {
	root=$(persist_salvage_root)
	case "$root" in
		/var/lib/lubancat-persist-salvage|/tmp/*|/var/tmp/*) ;;
		*)
			echo "rauc-slot-hook: 拒绝清理意外路径 $root" >&2
			return 1
			;;
	esac
	rm -rf "$root"
}

persist_salvage_reset() {
	persist_salvage_clear
	root=$(persist_salvage_root)
	mkdir -p "$root"
	chmod 0700 "$root"
}

persist_hook_slot_pre_install() {
	if [ "${RAUC_SLOT_CLASS:-}" != "rootfs" ]; then
		persist_log "非 rootfs 槽(${RAUC_SLOT_CLASS:-}),跳过"
		return 0
	fi
	slot=${RAUC_SLOT_MOUNT_POINT:-}
	if ! persist_slot_guard "$slot"; then
		echo "rauc-slot-hook: 拒绝在 ${slot:-<空>} 上抢救配置" >&2
		return 1
	fi
	slot=$(readlink -f "$slot")
	persist_salvage_reset
	root=$(persist_salvage_root)
	# 只抢救真有文件的树。目标槽上的空目录(镜像自带的 /etc/mihomo)不记。
	persist_copy_one "$slot/etc/wpa_supplicant" "$root/wpa"
	persist_copy_one "$slot/etc/mihomo" "$root/mihomo"
	persist_copy_one "$slot/root/.hermes" "$root/hermes"
	persist_copy_one "$slot/root/.local/state/hermes" "$root/hermes-state"
	persist_log "已从即将覆盖的槽抢救配置到 $root"
}

persist_hook_slot_post_install() {
	if [ "${RAUC_SLOT_CLASS:-}" != "rootfs" ]; then
		persist_log "非 rootfs 槽(${RAUC_SLOT_CLASS:-}),跳过"
		return 0
	fi
	slot=${RAUC_SLOT_MOUNT_POINT:-}
	if ! persist_slot_guard "$slot"; then
		echo "rauc-slot-hook: 拒绝在 ${slot:-<空>} 上迁移配置" >&2
		return 1
	fi
	slot=$(readlink -f "$slot")
	root=$(persist_salvage_root)
	# 正在跑的槽有文件就用它。它是空的(当前板子跑在没有配置的 B),
	# 而 pre-install 从即将被盖掉的 A 抢救出了文件,就用抢救的那份。
	# 两边都空则什么都不写,避免造出空树。
	src=$(persist_choose_source /etc/wpa_supplicant "$root/wpa")
	if [ -n "$src" ]; then
		persist_copy_one "$src" "$slot/etc/wpa_supplicant"
	fi
	src=$(persist_choose_source /etc/mihomo "$root/mihomo")
	if [ -n "$src" ]; then
		persist_copy_one "$src" "$slot/etc/mihomo"
	fi
	src=$(persist_choose_source /root/.hermes "$root/hermes")
	if [ -n "$src" ]; then
		persist_copy_one "$src" "$slot/root/.hermes"
	fi
	src=$(persist_choose_source /root/.local/state/hermes "$root/hermes-state")
	if [ -n "$src" ]; then
		persist_copy_one "$src" "$slot/root/.local/state/hermes"
	fi
	persist_tighten_live "$slot"
	persist_salvage_clear
}
