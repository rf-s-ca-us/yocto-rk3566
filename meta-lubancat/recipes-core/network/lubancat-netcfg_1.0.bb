SUMMARY = "板级网络配置 —— 以太口地址与 NTP"
DESCRIPTION = "systemd-networkd 的地址配置与 systemd-timesyncd 的 NTP 服务器。放独立 \
recipe 而不是改 systemd-conf 的 bbappend:systemd-conf 的 do_install 是写死的,加一个 \
文件要整段重写,而这两份配置跟 systemd 的版本无关,分开更新更省事。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://10-eth-static.network \
           file://10-ntp.conf"

inherit features_check
REQUIRED_DISTRO_FEATURES = "systemd"

do_install() {
	install -D -m 0644 ${WORKDIR}/10-eth-static.network \
		${D}${sysconfdir}/systemd/network/10-eth-static.network

	install -D -m 0644 ${WORKDIR}/10-ntp.conf \
		${D}${sysconfdir}/systemd/timesyncd.conf.d/10-ntp.conf
}

FILES:${PN} = "${sysconfdir}/systemd/network ${sysconfdir}/systemd/timesyncd.conf.d"
