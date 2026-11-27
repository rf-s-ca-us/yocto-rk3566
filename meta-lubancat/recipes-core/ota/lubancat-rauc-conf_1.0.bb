SUMMARY = "RAUC 系统配置与 OTA 验签证书"
DESCRIPTION = "装 /etc/rauc/system.conf 与公钥证书 /etc/rauc/keyring.pem。 \
槽位映射见 files/system.conf 头注释。私钥不进镜像,只在 CI 的 GitHub \
Secret RAUC_SIGNING_KEY。不沿用 meta-rauc 的 rauc-conf.bb:它的 keyring \
文件名随 RAUC_KEYRING_FILE 变,本板把路径钉死在 /etc/rauc/keyring.pem。 \
照 lubancat-fw-env 先例做独立小 recipe,经 RPROVIDES virtual-rauc-conf \
闭环 meta-rauc 的 RRECOMMENDS。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit features_check
REQUIRED_DISTRO_FEATURES = "systemd"

SRC_URI = "file://system.conf file://keyring.pem"

RPROVIDES:${PN} += "virtual-rauc-conf"

do_install() {
	install -D -m 0644 ${WORKDIR}/system.conf \
		${D}${sysconfdir}/rauc/system.conf
	install -D -m 0644 ${WORKDIR}/keyring.pem \
		${D}${sysconfdir}/rauc/keyring.pem
}

FILES:${PN} = "${sysconfdir}/rauc/system.conf ${sysconfdir}/rauc/keyring.pem"
