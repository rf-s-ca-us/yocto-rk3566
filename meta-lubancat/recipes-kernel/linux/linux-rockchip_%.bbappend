# 板级内核定制的挂载点。
# 现在挂的是本板自己的 dts —— EVB2 的 dtb 让本板联不上网(见 dts 里的对照表)。

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://rk3566-lubancat-1io.dts"

# vendor 的 6.1 defconfig 里 `# CONFIG_OVERLAY_FS is not set`,于是 podman 起不了
# 任何容器:`kernel does not support overlay fs: 'overlay' is not supported over
# extfs`。装了 podman 却没有它,等于装了个跑不动的东西。
#
# 这是 distro 层的诉求不是板级的 —— 跟 lubancat.conf 里那个 virtualization
# 同因(这个产品要跑容器),换块板子照样要。暂放这里是因为三层现在挤在同一个
# layer 里;等 BSP / distro 分开,它跟 virtualization 一起走。
SRC_URI += "file://overlayfs.cfg"

# 放在 do_configure 之前:此时 ${S} 已经解包好,而内核尚未开始配置/编译。
do_configure:prepend() {
	install -m 0644 ${WORKDIR}/rk3566-lubancat-1io.dts \
		${S}/arch/arm64/boot/dts/rockchip/

	# 登记到 dts Makefile。kbuild 有通用的 %.dtb: %.dts 规则,不登记也多半
	# 能编出来,但登记一次成本为零,而漏了会在 do_compile 才炸 —— 那时已经
	# 编了半小时内核。幂等,重复执行不会写第二遍。
	MK=${S}/arch/arm64/boot/dts/rockchip/Makefile
	grep -q 'rk3566-lubancat-1io\.dtb' $MK || \
		echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3566-lubancat-1io.dtb' >> $MK
}
