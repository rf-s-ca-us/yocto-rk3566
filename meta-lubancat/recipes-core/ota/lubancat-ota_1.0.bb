SUMMARY = "lubancat OTA 板上客户端 —— 定时拉取比对安装 + 升级后自检 mark-good"
DESCRIPTION = "systemd timer 周期触发 ota-update(curl 拉 latest.json → 只比 \
run_number → 更新才 rauc install 流式写非活动槽 → 成功后才置位 env 并重启);\
开机自启 ota-selfcheck(upgrade_available=1 时跑五项自检,全过 mark-good,失败\
只写日志再重启,env 交给 u-boot 两级安全网)。契约与时序定稿见 \
docs/plans/2026-09-26-ota-phase23.md Task 3;脚本头注释同样留了一份,两处同源。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"

# 公开读基址与渠道(非凭据;拍板 1 的镜像无秘密前提)。OTA_VERSION 由 CI 的
# build.yml 写进 local.conf(run_number-sha8),本地构建无此变量时落 "0",
# 恒小于 CI 版本,永不误装。
OTA_BASE_URL ??= "https://pub-b68514853b324ecaa66d426bae01a369.r2.dev"
OTA_CHANNEL ??= "stable"
OTA_VERSION ??= "0"

SRC_URI = "file://ota-update \
           file://ota-selfcheck \
           file://lubancat-ota.service \
           file://lubancat-ota.timer \
           file://lubancat-ota-selfcheck.service \
"

RDEPENDS:${PN} = "rauc libubootenv-bin curl"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "lubancat-ota.service lubancat-ota.timer lubancat-ota-selfcheck.service"

do_install() {
	install -D -m 0755 ${WORKDIR}/ota-update ${D}${libexecdir}/lubancat-ota/ota-update
	# 拉取基址与渠道在构建期注入,板上脚本零配置
	sed -e 's,@OTA_BASE_URL@,${OTA_BASE_URL},g' \
	    -e 's,@OTA_CHANNEL@,${OTA_CHANNEL},g' \
	    -i ${D}${libexecdir}/lubancat-ota/ota-update

	install -D -m 0755 ${WORKDIR}/ota-selfcheck ${D}${libexecdir}/lubancat-ota/ota-selfcheck

	install -d ${D}${systemd_unitdir}/system
	install -m 0644 ${WORKDIR}/lubancat-ota.service ${D}${systemd_unitdir}/system/
	install -m 0644 ${WORKDIR}/lubancat-ota.timer ${D}${systemd_unitdir}/system/
	install -m 0644 ${WORKDIR}/lubancat-ota-selfcheck.service ${D}${systemd_unitdir}/system/

	echo "${OTA_VERSION}" > ${D}${sysconfdir}/ota-version

	# 屏蔽 meta-rauc 的 rauc-mark-good.service:它在 cmdline 含 rauc.slot 时
	# 会无条件 mark-good(ConditionKernelCommandLine=|rauc.slot),自检还没跑
	# 就把槽标记为 good,失败自动回退整个废掉。mask 用 /dev/null 指针,这是
	# systemd 官方的禁用手法,/etc 优先级压过 /lib。
	install -d ${D}${sysconfdir}/systemd/system
	ln -s /dev/null ${D}${sysconfdir}/systemd/system/rauc-mark-good.service
}

FILES:${PN} = "\
	${libexecdir}/lubancat-ota/ota-update \
	${libexecdir}/lubancat-ota/ota-selfcheck \
	${systemd_unitdir}/system/lubancat-ota.service \
	${systemd_unitdir}/system/lubancat-ota.timer \
	${systemd_unitdir}/system/lubancat-ota-selfcheck.service \
	${sysconfdir}/ota-version \
	${sysconfdir}/systemd/system/rauc-mark-good.service \
"
