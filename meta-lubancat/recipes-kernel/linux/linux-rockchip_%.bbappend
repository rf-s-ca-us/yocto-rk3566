# 板级内核定制的挂载点。
# P2 阶段是空的——此时还在用 EVB 的 dtb(见 machine conf)。
# P4 把自写的 rk3566-lubancat.dts 从这里塞进内核源码树。

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
