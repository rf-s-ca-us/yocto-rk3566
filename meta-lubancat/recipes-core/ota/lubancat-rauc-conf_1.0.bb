SUMMARY = "RAUC 系统配置 —— 只装 /etc/rauc/system.conf,无 keyring"
DESCRIPTION = "槽位映射表见 files/system.conf 头注释。不沿用 meta-rauc 的 \
rauc-conf.bb:它的 SRC_URI 强制要一个 keyring 文件(RAUC_KEYRING_FILE,缺省 \
ca.cert.pem 还会 bbwarn),与拍板 3「暂不做签名」冲突;本板信任根是 R2 写 \
权限,板上无 keyring。照 lubancat-fw-env 先例做独立小 recipe,经 \
RPROVIDES virtual-rauc-conf 闭环 meta-rauc 的 RRECOMMENDS。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit features_check
REQUIRED_DISTRO_FEATURES = "systemd"

SRC_URI = "file://system.conf"

RPROVIDES:${PN} += "virtual-rauc-conf"

do_install() {
	install -D -m 0644 ${WORKDIR}/system.conf \
		${D}${sysconfdir}/rauc/system.conf
}

FILES:${PN} = "${sysconfdir}/rauc/system.conf"
