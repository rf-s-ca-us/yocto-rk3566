SUMMARY = "共享 data 分区的空白格式化与跨槽运行时配置"
DESCRIPTION = "update.img 的 data:grow 不带文件系统字节。本包的首启服务只在 \
GPT 名 data 的分区没有 blkid 签名、且前 1MiB 全为零时创建 LABEL=data 的 ext4, \
已有文件系统一律不写。Wi-Fi 凭据、/root/.hermes、/root/.local/state/hermes \
和 /etc/mihomo 开机 bind 到 /var/lib/containers/persistent,换槽还在。 \
从旧槽升级时,打进 bundle 的 post-install 钩子先把这四份拷进新槽,新槽再收入 \
data。秘密不进镜像。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://persistent-common.sh \
           file://format-data-if-empty \
           file://mount-persistent \
           file://rauc-slot-hook \
           file://lubancat-format-data.service \
           file://lubancat-persistent.service \
"

inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"

RDEPENDS:${PN} = "e2fsprogs-mke2fs util-linux"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "lubancat-format-data.service lubancat-persistent.service"

do_install() {
	install -d ${D}${libexecdir}/lubancat-persistent
	install -m 0644 ${WORKDIR}/persistent-common.sh \
		${D}${libexecdir}/lubancat-persistent/persistent-common.sh
	install -m 0755 ${WORKDIR}/format-data-if-empty \
		${D}${libexecdir}/lubancat-persistent/format-data-if-empty
	install -m 0755 ${WORKDIR}/mount-persistent \
		${D}${libexecdir}/lubancat-persistent/mount-persistent
	install -m 0755 ${WORKDIR}/rauc-slot-hook \
		${D}${libexecdir}/lubancat-persistent/rauc-slot-hook

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${WORKDIR}/lubancat-format-data.service \
		${D}${systemd_system_unitdir}/lubancat-format-data.service
	install -m 0644 ${WORKDIR}/lubancat-persistent.service \
		${D}${systemd_system_unitdir}/lubancat-persistent.service
}

FILES:${PN} = "\
	${libexecdir}/lubancat-persistent/persistent-common.sh \
	${libexecdir}/lubancat-persistent/format-data-if-empty \
	${libexecdir}/lubancat-persistent/mount-persistent \
	${libexecdir}/lubancat-persistent/rauc-slot-hook \
	${systemd_system_unitdir}/lubancat-format-data.service \
	${systemd_system_unitdir}/lubancat-persistent.service \
"
