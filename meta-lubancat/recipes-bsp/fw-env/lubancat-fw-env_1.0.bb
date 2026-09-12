SUMMARY = "u-boot env 读写配置 —— 告诉 fw_printenv/fw_setenv env 在哪"
DESCRIPTION = "装 /etc/fw_env.config 一份文件。poky 的 u-boot.inc 自带一套 fw_env.config \
机制,但它挂在 bootloader 的包上,而 bootloader 不进 rootfs —— 板上真正读这个文件的 \
是 libubootenv 的工具,所以按 lubancat-netcfg 的先例做成独立小 recipe,跟 systemd 或 \
u-boot 的版本都解耦。偏移与 u-boot 补丁同源,见 files/fw_env.config 的注释。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://fw_env.config"

do_install() {
	install -D -m 0644 ${WORKDIR}/fw_env.config \
		${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "${sysconfdir}/fw_env.config"
