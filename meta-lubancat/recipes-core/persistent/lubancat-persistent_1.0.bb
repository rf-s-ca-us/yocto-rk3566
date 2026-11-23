SUMMARY = "共享 data 分区的空白格式化与跨槽运行时配置"
DESCRIPTION = "update.img 的 data:grow 不带文件系统字节。本包的首启服务只在 \
分区名 data、内容探测没有识别出文件系统或加密卷、且将写入的范围全为零时 \
创建 LABEL=data 的 ext4。blkid -p 不加 -D 时,空分区也会因分区表项退出 0, \
不能拿那个退出码当已有文件系统。已有内容、探测失败一律不写。data 没挂上时 \
用只读挂载挡住往 rootfs 写容器数据。Wi-Fi 凭据、/root/.hermes、 \
/root/.local/state/hermes 和 /etc/mihomo 开机 bind 到 \
/var/lib/containers/persistent,换槽还在。从旧槽升级时,bundle 在写盘前先 \
抢救目标槽上已有的配置;正在运行的槽没有对应凭据文件时不用空树或日志盖掉它。 \
新槽再收入 data。秘密不进镜像。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://persistent-common.sh \
           file://format-data-if-empty \
           file://mount-persistent \
           file://rauc-slot-hook \
           file://seal-data-store \
           file://lubancat-format-data.service \
           file://lubancat-persistent.service \
           file://lubancat-data-seal.service \
"

inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"

RDEPENDS:${PN} = "e2fsprogs-mke2fs util-linux"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "lubancat-format-data.service lubancat-data-seal.service lubancat-persistent.service"

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
	install -m 0755 ${WORKDIR}/seal-data-store \
		${D}${libexecdir}/lubancat-persistent/seal-data-store

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${WORKDIR}/lubancat-format-data.service \
		${D}${systemd_system_unitdir}/lubancat-format-data.service
	install -m 0644 ${WORKDIR}/lubancat-persistent.service \
		${D}${systemd_system_unitdir}/lubancat-persistent.service
	install -m 0644 ${WORKDIR}/lubancat-data-seal.service \
		${D}${systemd_system_unitdir}/lubancat-data-seal.service
}

FILES:${PN} = "\
	${libexecdir}/lubancat-persistent/persistent-common.sh \
	${libexecdir}/lubancat-persistent/format-data-if-empty \
	${libexecdir}/lubancat-persistent/mount-persistent \
	${libexecdir}/lubancat-persistent/rauc-slot-hook \
	${libexecdir}/lubancat-persistent/seal-data-store \
	${systemd_system_unitdir}/lubancat-format-data.service \
	${systemd_system_unitdir}/lubancat-persistent.service \
	${systemd_system_unitdir}/lubancat-data-seal.service \
"
