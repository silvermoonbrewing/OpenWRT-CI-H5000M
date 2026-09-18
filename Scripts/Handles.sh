#==============================================================
# QModem 处理
#
# H5000M 不使用完整 QModem 管理器。
#
# QModem feed 仅用于给 luci-app-mt5700m 提供：
#
#   ubus-at-daemon
#   sms-tool_q
#
# 禁止：
#
#   qmodem
#   modem_scan
#   luci-app-qmodem
#   luci-app-qmodem-next
#
# 否则 QModem 会识别 hiveton,h5000m，
# 并通过 alias USB 创建：
#
#   USB
#   USBv6
#
# 与专用 MT5700M manager 创建的：
#
#   MT5700M
#   MT5700Mv6
#
# 重复管理同一个 eth2。
#==============================================================


#--------------------------------------------------------------
# 修正 QModem 版本号
#
# apk 不接受类似：
#
#   3.4.0-rc.3
#
# 这样的版本格式。
#
# 转换为：
#
#   3.4.0_rc3
#--------------------------------------------------------------

QMODEM_VER_MK="$PKG_PATH/../feeds/qmodem/version.mk"

if [ -f "$QMODEM_VER_MK" ]; then

	OLD_VER="$(grep -oP '^QMODEM_VERSION:=\K.*' "$QMODEM_VER_MK" 2>/dev/null || true)"

	NEW_VER="$(
		echo "$OLD_VER" |
		sed -E \
			's/-rc\.?([0-9]+)/_rc\1/;
			 s/-beta\.?([0-9]+)/_beta\1/;
			 s/-alpha\.?([0-9]+)/_alpha\1/'
	)"

	if [ -n "$OLD_VER" ] && [ "$OLD_VER" != "$NEW_VER" ]; then

		sed -i \
			"s|^QMODEM_VERSION:=.*|QMODEM_VERSION:=$NEW_VER|" \
			"$QMODEM_VER_MK"

		echo "QModem 版本号已修正：$OLD_VER -> $NEW_VER"

	else

		echo "QModem 版本号无需修正：$OLD_VER"

	fi

else

	echo "未找到 QModem version.mk，跳过版本号修正"

fi


#--------------------------------------------------------------
# 修正 luci-app-qmodem-next 中文包依赖
#
# QModem 原始 Makefile 中：
#
#   DEFAULT:=LUCI_LANG_zh_Hans||(ALL&&m)
#   DEPENDS:=+luci-app-qmodem-next
#
# 当固件开启：
#
#   CONFIG_LUCI_LANG_zh_Hans=y
#
# 中文语言包会被默认选中。
#
# 前面的 "+" 又会反向自动选中 luci-app-qmodem-next，
# 最终继续拉入完整 qmodem。
#
# 正常语言包只应该依赖主包，而不应该反向强制选择主包。
#--------------------------------------------------------------

QMODEM_NEXT_MK="$PKG_PATH/../feeds/qmodem/luci/luci-app-qmodem-next/Makefile"

if [ -f "$QMODEM_NEXT_MK" ]; then

	echo "检查 QModem Next 中文语言包依赖..."

	if grep -qE \
		'^[[:space:]]*DEPENDS:=[[:space:]]*\+luci-app-qmodem-next[[:space:]]*$' \
		"$QMODEM_NEXT_MK"; then

		sed -i -E \
			's|^([[:space:]]*)DEPENDS:=[[:space:]]*\+luci-app-qmodem-next[[:space:]]*$|\1DEPENDS:=luci-app-qmodem-next|' \
			"$QMODEM_NEXT_MK"

		echo "QModem Next 中文语言包依赖已修正"
		echo "  原：DEPENDS:=+luci-app-qmodem-next"
		echo "  新：DEPENDS:=luci-app-qmodem-next"

	else

		echo "QModem Next 中文语言包依赖无需修正"

	fi

else

	echo "未找到 luci-app-qmodem-next Makefile，跳过依赖修正"

fi


#--------------------------------------------------------------
# 输出检查结果
#--------------------------------------------------------------

echo ""
echo "========== QModem Feed 状态 =========="

if [ -d "$PKG_PATH/../feeds/qmodem" ]; then

	echo "QModem feed：存在"

else

	echo "QModem feed：不存在"

fi


if [ -f "$QMODEM_NEXT_MK" ]; then

	echo ""
	echo "QModem Next 中文包当前依赖："

	grep -E \
		'DEFAULT:=|DEPENDS:=.*luci-app-qmodem-next' \
		"$QMODEM_NEXT_MK" \
		2>/dev/null || true

fi

echo "======================================"
echo ""
