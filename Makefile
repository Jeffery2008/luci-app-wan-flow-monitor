include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI 只读多 WAN 分流监控
LUCI_DESCRIPTION:=只读查看 PBR、conntrack 与多 WAN 实时流量，并按实测数据绘制拓扑
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ip-full +ss +conntrack +nftables-json
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-wan-flow-monitor
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Jeffery2008

# Works both inside feeds/luci/applications and as a standalone feed in the SDK.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
