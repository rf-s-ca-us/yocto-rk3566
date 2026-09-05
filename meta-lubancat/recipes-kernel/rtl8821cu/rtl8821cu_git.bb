SUMMARY = "RTL8821CU 无线网卡驱动(树外)"
DESCRIPTION = "板载模块是 TL8821CUB,走 USB,枚举出来是 0bda:c820。vendor 6.1 树里 \
无路可走:rtw88 只有 PCIe 变体(目录里只有 rtw8821ce.c,Kconfig 里也只有 \
RTW88_8821CE),rtl8xxxu 的 82 条 USB ID 里没有 c820。所以挂 Realtek 的树外驱动。"

LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=ab842b299d0a92fb908d6eb122cd6de9"

SRC_URI = "git://github.com/morrownr/8821cu-20210916.git;protocol=https;branch=main"
SRCREV = "bda65aac150d2cde0df9603206eec23a6f3b77c4"

S = "${WORKDIR}/git"

inherit module

# 驱动 Makefile 的 autodetect 段里 ARCH 与 CROSS_COMPILE 都是 `?=`,而
# module-base 已经把这两个导进环境,`?=` 对环境变量不生效,所以不用再传。
# KSRC 是 `:=` 硬赋值(指向宿主机 /lib/modules/$(uname -r)/build),只有命令行
# 变量压得住 —— 这一条不传,构建会去啃 runner 自己的内核头文件。
EXTRA_OEMAKE = "KSRC=${STAGING_KERNEL_DIR}"

# 驱动自带的 install 目标把 .ko 装进宿主机的 /lib/modules 再跑 depmod -a,
# 在交叉构建里既装错地方又污染宿主机,所以整个换掉,不用 modules_install。
do_install() {
	install -d ${D}${nonarch_base_libdir}/modules/${KERNEL_VERSION}/kernel/drivers/net/wireless
	install -m 0644 ${B}/8821cu.ko \
		${D}${nonarch_base_libdir}/modules/${KERNEL_VERSION}/kernel/drivers/net/wireless/
}

# modalias 自动加载要 udev 参与;这块板上无线是基础设施不是可选外设,
# 直接写死开机加载,少一层不确定。
KERNEL_MODULE_AUTOLOAD += "8821cu"
