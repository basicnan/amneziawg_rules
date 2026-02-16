#!/bin/sh
# =============================================================================
# Автоматическая установка AmneziaWG 2.0 + русский интерфейс + тестовое соединение
# Для OpenWrt 24.10.3 и новее (автоматически определяет версию)
# =============================================================================

set -e

# Проверка версии OpenWrt
VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
PATCH=$(echo "$VERSION" | cut -d. -f3)

if [ "$MAJOR" -lt 24 ] || \
   [ "$MAJOR" -eq 24 -a "$MINOR" -lt 10 ] || \
   [ "$MAJOR" -eq 24 -a "$MINOR" -eq 10 -a "$PATCH" -lt 3 ]; then
    echo "Ошибка: Этот скрипт требует OpenWrt 24.10.3 или новее"
    echo "Текущая версия: $VERSION"
    exit 1
fi

echo "Обнаружена версия OpenWrt $VERSION → AmneziaWG 2.0 + русский интерфейс"

# 1. Обновляем репозитории
opkg update

# 2. Установка AmneziaWG 2.0 (luci-proto-amneziawg)
PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max=$3; arch=$2}} END {print arch}')
TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d/ -f1)
SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d/ -f2)
PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"

BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VERSION}"

AWG_DIR="/tmp/awg_install"
mkdir -p "$AWG_DIR"

for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg luci-i18n-amneziawg-ru; do
    filename="${pkg}${PKGPOSTFIX}"
    echo "Скачиваем $pkg..."
    wget -O "$AWG_DIR/$filename" "${BASE_URL}/${filename}" || {
        echo "Ошибка скачивания $pkg — проверьте интернет или репозиторий"
        exit 1
    }
    opkg install "$AWG_DIR/$filename"
done

rm -rf "$AWG_DIR"

# 3. Создаём тестовое соединение awg1 с твоими настройками
echo "Создаём интерфейс awg1 с твоими параметрами..."

uci batch << 'EOC'
delete network.awg1
set network.awg1=interface
set network.awg1.proto='amneziawg'
set network.awg1.private_key='wMAsr1efyZAw8RkKZw5OrsoK8pfziAUgm4si5E5Wv3M='
set network.awg1.listen_port='51821'
set network.awg1.addresses='10.201.66.154/32'
set network.awg1.mtu='1380'

set network.awg1.awg_jc='43'
set network.awg1.awg_jmin='50'
set network.awg1.awg_jmax='70'
set network.awg1.awg_s1='110'
set network.awg1.awg_s2='120'
set network.awg1.awg_h1='1593635057'
set network.awg1.awg_h2='430880481'
set network.awg1.awg_h3='1214405368'
set network.awg1.awg_h4='1739253821'

# Peer
delete network.@amneziawg_awg1[-1]
add network amneziawg_awg1
set network.@amneziawg_awg1[-1].name='awg1_test'
set network.@amneziawg_awg1[-1].public_key='n0z+oioqL8meQmsU1aPx0fXiMPzStqM3VwkVSmAqzG0='
set network.@amneziawg_awg1[-1].preshared_key='4PnWMu0LNNrXyYt03CcI6KSI3NFb2wCCfbE1EDmdP1c='
set network.@amneziawg_awg1[-1].endpoint_host='nl01a.kcufwfgnkr.net'
set network.@amneziawg_awg1[-1].endpoint_port='62931'
set network.@amneziawg_awg1[-1].persistent_keepalive='25'
set network.@amneziawg_awg1[-1].allowed_ips='0.0.0.0/0 ::/0'
set network.@amneziawg_awg1[-1].route_allowed_ips='1'   # full-tunnel (весь трафик через VPN)
commit network
EOC

# 4. Базовая firewall-зона (если нужно — добавь forwarding вручную в LuCI)
if ! uci show firewall | grep -q "@zone.*name='awg1'"; then
    uci batch << 'EOC'
    add firewall zone
    set firewall.@zone[-1].name='awg1'
    set firewall.@zone[-1].network='awg1'
    set firewall.@zone[-1].input='REJECT'
    set firewall.@zone[-1].output='ACCEPT'
    set firewall.@zone[-1].forward='REJECT'
    set firewall.@zone[-1].masq='1'
    set firewall.@zone[-1].mtu_fix='1'
    set firewall.@zone[-1].family='ipv4'

    add firewall forwarding
    set firewall.@forwarding[-1].src='lan'
    set firewall.@forwarding[-1].dest='awg1'
    commit firewall
EOC
fi

# 5. Перезапуск
echo "Перезапускаем сеть..."
/etc/init.d/network restart

echo "Готово!"
echo "Проверь в LuCI → Network → Interfaces → awg1"
echo "Статус: Up / Down"
echo "В LuCI теперь должен быть русский интерфейс AmneziaWG"
echo "Если VPN не поднялся — проверь логи: logread | grep amnezia"
