# meta-rockchip 的 gen_rkparameter 只输出 `uuid: rootfs=...`,适用它默认的
# 单槽 `rootfs` 分区。本镜像将分区改名为 rootfs_a/rootfs_b 后,
# RKDevTool 会按分区名精确匹配 UUID;旧键匹配不上,两槽就会获得随机
# PARTUUID,而 boot.img 仍按 RK_ROOTDEV_UUID 找根分区,导致启动卡在 rootwait。
#
# 直接追加到 class 的 parameter 生成函数末尾,保证修正发生在
# IMAGE_POSTPROCESS_COMMAND 中下一步 gen_rkupdateimg 打包之前。
gen_rkparameter:append() {
	parameter="${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.parameter"
	boot_image="${DEPLOY_DIR_IMAGE}/boot.img"

	[ -s "$parameter" ] || bbfatal "Rockchip parameter 未生成: $parameter"
	grep -Fq '(rootfs_a)' "$parameter" || bbfatal "parameter 缺 rootfs_a 分区"
	grep -Fq '(rootfs_b)' "$parameter" || bbfatal "parameter 缺 rootfs_b 分区"
	grep -qx "uuid: rootfs=${RK_ROOTDEV_UUID}" "$parameter" \
		|| bbfatal "meta-rockchip 的 rootfs UUID 输出已变,拒绝静默重写"

	sed -i '/^uuid: rootfs=/d' "$parameter"
	echo "uuid: rootfs_a=${RK_ROOTDEV_UUID}" >> "$parameter"
	echo "uuid: rootfs_b=${RK_ROOTDEV_B_UUID}" >> "$parameter"

	# boot.img 上的 root= 用 PARTUUID 前缀匹配。在打包前直接问最终
	# boot 产物,防止 parameter 修好了但内核仍指向另一个 UUID。
	rootdev_prefix=$(echo "${RK_ROOTDEV_UUID}" | cut -d- -f1-2)
	strings "$boot_image" | grep -Fq "root=PARTUUID=$rootdev_prefix" \
		|| bbfatal "boot.img 的 root=PARTUUID 与 rootfs_a 不一致"
}
