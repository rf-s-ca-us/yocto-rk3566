SUMMARY = "板级网络配置 —— 以太口静态地址"
DESCRIPTION = "systemd-networkd 的静态地址配置。放独立 recipe 而不是改 \
systemd-conf 的 bbappend:systemd-conf 的 do_install 是写死的,加一个文件要 \
整段重写,而这份配置跟 systemd 的版本无关,分开更新更省事。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://10-eth-static.network"

inherit features_check
REQUIRED_DISTRO_FEATURES = "systemd"

do_install() {
	install -D -m 0644 ${WORKDIR}/10-eth-static.network \
		${D}${sysconfdir}/systemd/network/10-eth-static.network
}

FILES:${PN} = "${sysconfdir}/systemd/network"
