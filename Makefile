include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI read-only WAN policy routing monitor
LUCI_DESCRIPTION:=Read-only PBR, conntrack and dual-WAN observability with real traffic animation
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
