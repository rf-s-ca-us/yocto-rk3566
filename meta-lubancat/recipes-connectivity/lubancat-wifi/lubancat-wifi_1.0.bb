SUMMARY = "无线开机自连 —— wpa_supplicant 配置与接口自识别"
DESCRIPTION = "驱动(rtl8821cu)让 wlan 接口出现,这份让它自己连上 AP。凭据不进 \
仓:SSID 与口令从构建配置读,仓是公开的,把家里的 Wi-Fi 口令提交进去等于公布它。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
	file://lubancat-wifi-up \
	file://wpa-supplicant-wlan.service \
	file://25-wlan.network \
"

inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"

SYSTEMD_SERVICE:${PN} = "wpa-supplicant-wlan.service"

# 凭据由构建配置给(CI 从 secret 注入,本地从 local.conf)。留空就只装机制不装
# 凭据 —— 镜像照样能编、能烧,只是不会自己连,而不是编到一半炸掉。
WIFI_SSID ?= ""
WIFI_PSK ?= ""

# 不声明的话改了 SSID/口令不会触发重新 do_install,拿到的还是上一版凭据。
do_install[vardeps] += "WIFI_SSID WIFI_PSK"

do_install() {
	install -D -m 0755 ${WORKDIR}/lubancat-wifi-up ${D}${sbindir}/lubancat-wifi-up
	install -D -m 0644 ${WORKDIR}/wpa-supplicant-wlan.service \
		${D}${systemd_system_unitdir}/wpa-supplicant-wlan.service
	install -D -m 0644 ${WORKDIR}/25-wlan.network \
		${D}${sysconfdir}/systemd/network/25-wlan.network

	if [ -z "${WIFI_SSID}" ]; then
		bbwarn "WIFI_SSID 为空:只装机制不装凭据,板子不会自动连 Wi-Fi"
		return
	fi

	# 0600:口令明文躺在 rootfs 里,这是 wpa_supplicant 的既定形态,能做的是
	# 别让它世界可读。服务里 ConditionPathExists 盯的就是这个文件。
	install -d -m 0700 ${D}${sysconfdir}/wpa_supplicant
	# 不用 heredoc:bitbake 的 shell 函数以第 0 列的 `}` 收尾,而 wpa_supplicant
	# 的 network={...} 块正好要一个 `}`。写成 heredoc 会让函数在那里被截断,
	# 报的还是下一行 EOF "unparsed line",跟真正的原因隔着一行。
	{
		echo 'ctrl_interface=/run/wpa_supplicant'
		echo 'update_config=1'
		echo ''
		echo 'network={'
		echo '    ssid="${WIFI_SSID}"'
		echo '    psk="${WIFI_PSK}"'
		echo '    key_mgmt=WPA-PSK'
		echo '}'
	} > ${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-wlan.conf
	chmod 0600 ${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-wlan.conf
}

FILES:${PN} += "${systemd_system_unitdir} ${sysconfdir}/systemd/network ${sysconfdir}/wpa_supplicant"
