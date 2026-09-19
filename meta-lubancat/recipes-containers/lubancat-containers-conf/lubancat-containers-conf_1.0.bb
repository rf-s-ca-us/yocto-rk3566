SUMMARY = "podman 默认能力表补 NET_RAW —— 容器内 ping/raw socket 可用"
DESCRIPTION = "meta-virtualization 打包的 podman 不带 containers.conf,回退到的内置默认 \
能力表缺 NET_RAW:容器内 ping 报 permission denied,而 DNS/HTTP 出网实际正常,门与 \
现实错位(2026-09-19 实机验收定位)。本 recipe 显式给齐 podman 标准默认能力表。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://containers.conf"

S = "${WORKDIR}"

do_install() {
	install -d ${D}${sysconfdir}/containers
	install -m 0644 ${WORKDIR}/containers.conf ${D}${sysconfdir}/containers/containers.conf
}

FILES:${PN} = "${sysconfdir}/containers/containers.conf"
