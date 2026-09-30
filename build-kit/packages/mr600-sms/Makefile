# MR600 SMS glue: the parts of SMS support this device needs that upstream does not do.
#
# Two jobs, both of them specific to this router:
#
#   1. the MR600's defaults for luci-app-sms-tool-js. Its own defaults are for a different kind
#      of modem, and on this one they fail silently - an unset port falls back to /dev/ttyUSB0
#      (which exists here but is not the AT port), the default storage SM is empty (this modem
#      stores in ME), and a call-log daemon wants to hold the AT port open. See
#      files/etc/uci-defaults/99-mr600-sms for each one and what it costs to get wrong.
#
#   2. MQTT forwarding of arriving SMS. The app cannot do this at all: its only forwarding
#      target is e-mail (mailsend), and only for a message a person selects by hand. The
#      poller here publishes each new message to a broker as JSON.
#
# Why this is a separate package instead of a patch on the app: the vendored app stays
# byte-identical to the upstream commit it was taken from, so "is this the code we reviewed?"
# is answerable with `diff -r` against that commit rather than by reading a fork. Everything
# this kit adds to SMS support lives here or in files/.
#
# A mosquitto client is NOT a dependency, on purpose: mosquitto-client-ssl and
# mosquitto-client-nossl provide the same binaries and conflict, so choosing one belongs to the
# image. The poller says so and fails loudly if it is missing, rather than looking like a modem
# that never receives anything. See ../README.md, "SMS over MQTT".
include $(TOPDIR)/rules.mk

PKG_NAME:=mr600-sms
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=kristofer84 <kristofer.nilsson@outlook.com>
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/mr600-sms
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=MR600 defaults and MQTT forwarding for luci-app-sms-tool-js
  DEPENDS:=+sms-tool +ucode +ucode-mod-fs +ucode-mod-uci
  PKGARCH:=all
endef

define Package/mr600-sms/description
  Device-specific glue for SMS on the TP-Link Archer MR600 v1:
  MR600 defaults for luci-app-sms-tool-js (AT port, storage area, the call-log daemon that must
  stay off) and a poller that publishes arriving SMS to an MQTT broker.
endef

define Package/mr600-sms/conffiles
/etc/config/sms_mqtt
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/mr600-sms/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/sbin
	$(INSTALL_CONF) ./files/etc/config/sms_mqtt $(1)/etc/config/sms_mqtt
	$(INSTALL_BIN) ./files/etc/init.d/sms-mqtt $(1)/etc/init.d/sms-mqtt
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-mr600-sms $(1)/etc/uci-defaults/99-mr600-sms
	$(INSTALL_BIN) ./files/usr/sbin/sms-mqtt-poll $(1)/usr/sbin/sms-mqtt-poll
endef

$(eval $(call BuildPackage,mr600-sms))
