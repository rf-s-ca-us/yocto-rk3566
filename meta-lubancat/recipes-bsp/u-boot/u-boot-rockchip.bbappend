# u-boot 侧的 A/B OTA 前提:env 落盘 eMMC + bootcount 安全网。
#
# stock(2017.09 vendor)的 env 存储是 NOWHERE —— saveenv 命令在,但没有
# 后端,写了也不落盘(阶段 0 上板实证:无 bad-CRC 警告、盘上无任何已保存
# env、默认偏移处全零)。没有 env 持久化,A/B 的选槽与失败回退都没有地基。
#
# 偏移 0x1F8000 是本板 eMMC 实测值:Kconfig 默认 0x3f8000 撞在 uboot 分区
# (扇区 4096 起)正中;0x1F8000 落在 idbloader 四份冗余副本之后的空隙
# 尾部(扇区 4032,32KB),与 wks 分区布局互不相扰。改动依据全文见补丁
# 头注释与 docs/plans/ota.md。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 顺序即应用顺序:0002 的 defconfig/头文件 hunk 以 0001 之后的树为基准生成,
# 两者次序不能对调。
SRC_URI += "file://0001-rk3568-ota-env-mmc-bootcount.patch \
            file://0002-rk3568-ab-slot-boot.patch \
"
