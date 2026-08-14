#!/bin/bash
#
# PRIVATE.sh —— 自动拉取最新版 wmsxwd 并生成源码包
#
# 由 Scripts/Packages.sh 在末尾 source 执行，此时工作目录是 wrt/package/
# 移植自本地的 wmsxwd-sync.sh，改为从 OpenList 网盘自动取最新版
#

WMSXWD_BASE="${WMSXWD_URL:-http://172.233.138.55:5255}"
WMSXWD_PATH="/wmsxwd1"
PKG_NAME="wmsxwd-openwrt"
ARCH_TAG="arm64"
EXTRA_ARCH="aarch64_generic"
# 依赖：dnsmasq 故意不写（固件用的是 dnsmasq-full，写死会打架）
WMSXWD_DEPENDS="+luci-base +luci-compat +luci-lua-runtime +nftables +kmod-nft-tproxy +kmod-nft-nat +ip-full"

echo ""
echo "=================================================="
echo " wmsxwd 自动拉取"
echo "=================================================="

wm_die() { echo "[wmsxwd][致命] $*" >&2; exit 1; }
wm_say() { echo "[wmsxwd] $*"; }

command -v jq >/dev/null 2>&1 || wm_die "运行环境缺少 jq"

# ---------- 1. 列目录，找最新版本号 ----------
wm_api_list() {
	curl -fsS --connect-timeout 20 --max-time 90 --retry 3 --retry-delay 3 \
		-X POST "$WMSXWD_BASE/api/fs/list" \
		-H "Content-Type: application/json" \
		-d "{\"path\":\"$1\",\"password\":\"\",\"page\":1,\"per_page\":0,\"refresh\":false}"
}

WM_JSON="$(wm_api_list "$WMSXWD_PATH")" \
	|| wm_die "连不上 $WMSXWD_BASE 或接口报错"

WM_CODE="$(echo "$WM_JSON" | jq -r '.code // empty')"
[ "$WM_CODE" = "200" ] \
	|| wm_die "接口返回异常：$(echo "$WM_JSON" | jq -r '.message // "无 message"')"

WM_VER="$(echo "$WM_JSON" \
	| jq -r '.data.content[]?.name' \
	| grep -E '^[0-9]+(\.[0-9]+)+$' \
	| sort -V | tail -n1)"

[ -n "$WM_VER" ] || wm_die "$WMSXWD_PATH 下没找到版本号目录"
wm_say "最新版本：$WM_VER"

# ---------- 2. 在版本目录里挑 arm64 的包 ----------
WM_SUB="$(wm_api_list "$WMSXWD_PATH/$WM_VER")" \
	|| wm_die "无法列出 $WMSXWD_PATH/$WM_VER"

WM_NAMES="$(echo "$WM_SUB" | jq -r '.data.content[]?.name')"

# 优先用 ipk：格式简单，任何 Linux 都能解；apk 是 ADB 格式，需要专用工具
WM_FILE="$(echo "$WM_NAMES" | grep -E "_${ARCH_TAG}\.ipk$" | sort -V | tail -n1)"
WM_KIND="ipk"
if [ -z "$WM_FILE" ]; then
	WM_FILE="$(echo "$WM_NAMES" | grep -E "\-${ARCH_TAG}\-full\.tar\.gz$" | sort -V | tail -n1)"
	WM_KIND="tar"
fi
[ -n "$WM_FILE" ] || wm_die "$WM_VER 目录里没有 ${ARCH_TAG} 的 ipk 或 full.tar.gz。
   实际文件：$(echo "$WM_NAMES" | tr '\n' ' ')"

wm_say "选用文件：$WM_FILE（$WM_KIND）"

# ---------- 3. 下载（每轮都重新换取签名直链，签名失效自动重试）----------
WM_TMP="$(mktemp -d)"
trap 'rm -rf "$WM_TMP"' RETURN 2>/dev/null || true

wm_fresh_url() {
	curl -fsS --connect-timeout 20 --max-time 60 --retry 2 \
		-X POST "$WMSXWD_BASE/api/fs/get" \
		-H "Content-Type: application/json" \
		-d "{\"path\":\"$WMSXWD_PATH/$WM_VER/$WM_FILE\",\"password\":\"\"}" \
		2>/dev/null | jq -r '.data.raw_url // empty'
}

WM_DL="$WM_TMP/pkg.bin"
WM_GOT=0

for WM_TRY in 1 2 3; do
	# 每一轮都重新换签名，不复用上一轮的
	WM_RAW="$(wm_fresh_url)"

	if [ -n "$WM_RAW" ]; then
		wm_say "第 $WM_TRY 次尝试：已换取新的签名直链"
	else
		echo "[wmsxwd][警告] 第 $WM_TRY 次换取直链失败，改试无签名地址"
	fi

	for WM_URL in "$WM_RAW" "$WMSXWD_BASE/d$WMSXWD_PATH/$WM_VER/$WM_FILE" "$WMSXWD_BASE/p$WMSXWD_PATH/$WM_VER/$WM_FILE"; do
		[ -n "$WM_URL" ] || continue
		rm -f "$WM_DL"
		if curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 5 \
			-o "$WM_DL" "$WM_URL" && [ -s "$WM_DL" ]; then
			WM_GOT=1
			break
		fi
	done

	[ "$WM_GOT" -eq 1 ] && break

	if [ "$WM_TRY" -lt 3 ]; then
		echo "[wmsxwd][警告] 第 $WM_TRY 次下载失败（签名可能已失效），10 秒后重新换签名再试"
		sleep 10
	fi
done

[ "$WM_GOT" -eq 1 ] || wm_die "连试 3 轮都下载失败，请检查网盘是否可访问"

wm_say "下载完成：$(du -h "$WM_DL" | cut -f1)"

# ---------- 4. 解包 ----------
WM_RAWDIR="$WM_TMP/raw"; WM_CTRL="$WM_TMP/ctrl"
mkdir -p "$WM_RAWDIR" "$WM_CTRL" "$WM_TMP/x"

if [ "$WM_KIND" = "ipk" ]; then
	if ar t "$WM_DL" >/dev/null 2>&1; then
		( cd "$WM_TMP/x" && ar x "$WM_DL" ) || wm_die "ar 解包失败"
	else
		tar -xaf "$WM_DL" -C "$WM_TMP/x" || wm_die "tar 解包失败"
	fi

	WM_DATA="$(find "$WM_TMP/x" -maxdepth 2 -name 'data.tar*' -print -quit)"
	[ -n "$WM_DATA" ] || wm_die "ipk 里没找到 data.tar.*"
	tar -xaf "$WM_DATA" -C "$WM_RAWDIR" || wm_die "data.tar 展开失败"

	WM_CT="$(find "$WM_TMP/x" -maxdepth 2 -name 'control.tar*' -print -quit)"
	[ -n "$WM_CT" ] && tar -xaf "$WM_CT" -C "$WM_CTRL" 2>/dev/null
else
	tar -xaf "$WM_DL" -C "$WM_RAWDIR" || wm_die "tar.gz 展开失败"
fi

# 校验：解出来得像个 rootfs
WM_OK=0
for d in etc usr lib www sbin bin opt; do
	[ -e "$WM_RAWDIR/$d" ] && WM_OK=1
done
[ "$WM_OK" -eq 1 ] || wm_die "解出来的内容不像 rootfs：$(ls -A "$WM_RAWDIR" | head | tr '\n' ' ')"

wm_say "解包完成：$(find "$WM_RAWDIR" -type f | wc -l) 个文件，共 $(du -sh "$WM_RAWDIR" | cut -f1)"

# 服务名
WM_INIT=""
[ -d "$WM_RAWDIR/etc/init.d" ] && WM_INIT="$(ls "$WM_RAWDIR/etc/init.d" 2>/dev/null | head -n1)"
[ -n "$WM_INIT" ] && wm_say "服务：/etc/init.d/$WM_INIT" || echo "[wmsxwd][警告] 包里没有 init.d 脚本"

# 原包的安装后脚本
WM_POST=""
for p in "$WM_CTRL/postinst" "$WM_CTRL/postinst-pkg" "$WM_CTRL/.post-install"; do
	[ -f "$p" ] && { WM_POST="$p"; break; }
done

# conffiles
WM_CONF=""
if [ -d "$WM_RAWDIR/etc/config" ]; then
	for c in "$WM_RAWDIR/etc/config"/*; do
		[ -f "$c" ] && WM_CONF="$WM_CONF
/etc/config/$(basename "$c")"
	done
fi

# ---------- 5. 生成源码包（当前目录就是 wrt/package/）----------
WM_PKGDIR="./$PKG_NAME"
rm -rf "$WM_PKGDIR"
mkdir -p "$WM_PKGDIR/files/etc/uci-defaults"
cp -a "$WM_RAWDIR"/. "$WM_PKGDIR/files/"

{
	echo '#!/bin/sh'
	echo '# 由 PRIVATE.sh 生成，首次启动 / 恢复出厂后自动执行一次'
	echo ''
	echo '# 坑1：包声明 aarch64_generic，设备是 aarch64_cortex-a53，补进去'
	echo "grep -qx '$EXTRA_ARCH' /etc/apk/arch 2>/dev/null || echo '$EXTRA_ARCH' >> /etc/apk/arch"
	echo ''
	echo '# 坑2：清掉 LuCI 缓存，菜单立刻出来'
	echo 'rm -rf /tmp/luci-modulecache/* /tmp/luci-indexcache* 2>/dev/null'
	echo ''
	if [ -n "$WM_POST" ]; then
		echo '# ---- 原包 post-install（自动搬运，失败不阻断开机）----'
		echo '('
		sed 's/^/  /' "$WM_POST"
		echo ') 2>/dev/null || true'
		echo '# ---- 原包 post-install 结束 ----'
		echo ''
	fi
	if [ -n "$WM_INIT" ]; then
		echo "if [ -x /etc/init.d/$WM_INIT ]; then"
		echo "  /etc/init.d/$WM_INIT enable"
		echo "  /etc/init.d/$WM_INIT start"
		echo 'fi'
		echo ''
	fi
	echo 'exit 0'
} > "$WM_PKGDIR/files/etc/uci-defaults/99-$PKG_NAME"
chmod 755 "$WM_PKGDIR/files/etc/uci-defaults/99-$PKG_NAME"

cat > "$WM_PKGDIR/Makefile" <<WMEOF
#
# 本文件由 Scripts/PRIVATE.sh 在云编译时自动生成，请勿手改
# 源包：$WM_FILE
#
include \$(TOPDIR)/rules.mk

PKG_NAME:=$PKG_NAME
PKG_VERSION:=$WM_VER
PKG_RELEASE:=1
PKG_MAINTAINER:=lujunxi
PKG_LICENSE:=Proprietary

# 预编译二进制，禁止 buildroot 再 strip
RSTRIP:=:
STRIP:=:

include \$(INCLUDE_DIR)/package.mk

define Package/$PKG_NAME
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=wmsxwd (atlas + mihomo) prebuilt binaries
  DEPENDS:=$WMSXWD_DEPENDS
endef

define Package/$PKG_NAME/description
  预编译的 wmsxwd-openwrt 插件（atlas 管理进程 + mihomo 内核），
  云编译时自动从网盘取最新版，随固件编译进 rootfs，
  恢复出厂设置后依然存在。
endef
$( [ -n "$WM_CONF" ] && printf 'define Package/%s/conffiles\n%s\nendef\n' "$PKG_NAME" "$WM_CONF" || true )
define Build/Prepare
	mkdir -p \$(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$PKG_NAME/install
	\$(CP) ./files/. \$(1)/
endef

\$(eval \$(call BuildPackage,$PKG_NAME))
WMEOF

rm -rf "$WM_TMP"

wm_say "源码包已生成：package/$PKG_NAME （版本 $WM_VER）"
echo "=================================================="
echo ""

echo ""
echo "=================================================="
echo " OpenClash 内核 + Geo 数据（编译时内置）"
echo "=================================================="

# files/ 在源码树根目录，当前工作目录是 wrt/package/
OC_FILES="../files"

oc_say()  { echo "[openclash] $*"; }
oc_warn() { echo "[openclash][警告] $*" >&2; }

# ---- 按平台选内核架构 ----
# WRT_TARGET 由 WRT-CORE.yml 从 Config/*.txt 的第一条 CONFIG_TARGET_xxx=y 取得
#   x86        -> amd64-compatible
#   mediatek   -> arm64（MT7986A / MT7981 均为 Cortex-A53 64 位）
#   qualcommax -> arm64
# 取不到就跳过，绝不猜——下错架构的二进制在设备上根本跑不起来，
# 而且 OpenClash 只会报“内核不可用”，很难定位。
# 需要手动指定时，在 workflow 里设 OC_ARCH_FORCE 环境变量即可覆盖。
case "${OC_ARCH_FORCE:-${WRT_TARGET:-}}" in
	amd64-compatible|arm64|armv7|armv5|mipsle-softfloat|mips-softfloat)
		OC_ARCH="${OC_ARCH_FORCE}" ;;
	x86)
		OC_ARCH="amd64-compatible" ;;
	mediatek|qualcommax|rockchip|sunxi|armsr|bcm27xx)
		OC_ARCH="arm64" ;;
	*)
		OC_ARCH="" ;;
esac

OC_BRANCH="master"
OC_TYPE="meta"

if [ -z "$OC_ARCH" ]; then
	oc_warn "无法从 WRT_TARGET='${WRT_TARGET:-未设置}' 判断内核架构，跳过内置，刷机后需在面板手动下载"
else
	OC_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/${OC_BRANCH}/${OC_TYPE}/clash-linux-${OC_ARCH}.tar.gz"
	oc_say "平台 ${WRT_TARGET:-?} -> 内核架构 ${OC_ARCH}"

	OC_TMP="$(mktemp -d)"
	if curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 5 \
		-o "$OC_TMP/core.tar.gz" "$OC_URL" && [ -s "$OC_TMP/core.tar.gz" ]; then

		if tar -xzf "$OC_TMP/core.tar.gz" -C "$OC_TMP" && [ -f "$OC_TMP/clash" ]; then
			mkdir -p "$OC_FILES/etc/openclash/core"
			mv -f "$OC_TMP/clash" "$OC_FILES/etc/openclash/core/clash_meta"
			chmod 755 "$OC_FILES/etc/openclash/core/clash_meta"
			oc_say "内核已内置：/etc/openclash/core/clash_meta （${OC_BRANCH}/${OC_TYPE}/${OC_ARCH}，$(du -h "$OC_FILES/etc/openclash/core/clash_meta" | cut -f1)）"
		else
			oc_warn "内核解包失败，本次固件不含内核，刷机后需在面板手动下载"
		fi
	else
		oc_warn "内核下载失败，本次固件不含内核，刷机后需在面板手动下载"
	fi
	rm -rf "$OC_TMP"
fi

# ---- Geo 数据：每次编译抓上游最新 ----
# 路径与 SSR+ / PassWall / OpenClash 官方脚本一致
GEO_TMP="$(mktemp -d)"
mkdir -p "$OC_FILES/usr/share/v2ray" "$OC_FILES/usr/share/shadowsocksr"

geo_fetch() {
	local name="$1" url="$2" dest="$3"
	if curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 5 \
		-o "$GEO_TMP/$name" "$url" && [ -s "$GEO_TMP/$name" ]; then
		mv -f "$GEO_TMP/$name" "$dest"
		echo "[geo] $name -> ${dest#$OC_FILES}  （$(du -h "$dest" | cut -f1)）"
	else
		echo "[geo][警告] $name 下载失败，跳过" >&2
	fi
}

# 用完整版 geoip.dat（PassWall 也依赖它，不能用 cn-only 那份覆盖）
geo_fetch "geoip.dat" \
	"https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat" \
	"$OC_FILES/usr/share/v2ray/geoip.dat"

geo_fetch "geosite.dat" \
	"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
	"$OC_FILES/usr/share/v2ray/geosite.dat"

geo_fetch "Country.mmdb" \
	"https://github.com/alecthw/mmdb_china_ip_list/releases/latest/download/Country-lite.mmdb" \
	"$OC_FILES/usr/share/shadowsocksr/Country.mmdb"

rm -rf "$GEO_TMP"

echo "=================================================="
echo ""
