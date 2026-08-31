# 板级内核定制的挂载点。
# 现在挂的是本板自己的 dts —— EVB2 的 dtb 让本板联不上网(见 dts 里的对照表)。

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://rk3566-lubancat-1io.dts"

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
