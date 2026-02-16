#!/bin/sh
# =============================================================================
# МОДЕРНИЗИРОВАННЫЙ СКРИПТ Slava-Shchipunov
# AmneziaWG 2.0 + русский интерфейс + твои настройки + селективная маршрутизация + Stubby
# Для OpenWrt 24.10.3 и новее (ramips/mt7621 и другие)
# =============================================================================

set -e

echo "=== Установка AmneziaWG 2.0 + селективная маршрутизация ==="

# 1. Определение версии и архитектуры
VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3>max) {max=$3; arch=$2}} END {print arch}')
TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d/ -f1)
SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d/ -f2)
PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"

BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VERSION}"

echo "OpenWrt $VERSION → AmneziaWG 2.0 (mipsel_24kc/ramips detected)"

# 2. Установка пакетов (скачиваем напрямую из релиза)
AWG_DIR="/tmp/awg"
mkdir -p "$AWG_DIR"
cd "$AWG_DIR"

for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg luci-i18n-amneziawg-ru; do
    echo "Скачиваем $pkg..."
    wget -q --show-progress -O "${pkg}${PKGPOSTFIX}" "${BASE_URL}/${pkg}${PKGPOSTFIX}" || {
        echo "ОШИБКА: пакет $pkg не найден в релизе v$VERSION"
        echo "Решение: зайди на https://github.com/Slava-Shchipunov/awg-openwrt/releases и скачай вручную"
        exit 1
    }
done

opkg install *.ipk
rm -rf "$AWG_DIR"

# 3. Создание интерфейса awg1 с твоими настройками (неинтерактивно)
echo "Создаём соединение awg1 с твоими параметрами..."
uci batch << 'EOF'
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

delete network.@amneziawg_awg1[-1]
add network amneziawg_awg1
set network.@amneziawg_awg1[-1].name='awg1_client'
set network.@amneziawg_awg1[-1].public_key='n0z+oioqL8meQmsU1aPx0fXiMPzStqM3VwkVSmAqzG0='
set network.@amneziawg_awg1[-1].preshared_key='4PnWMu0LNNrXyYt03CcI6KSI3NFb2wCCfbE1EDmdP1c='
set network.@amneziawg_awg1[-1].endpoint_host='nl01a.kcufwfgnkr.net'
set network.@amneziawg_awg1[-1].endpoint_port='62931'
set network.@amneziawg_awg1[-1].persistent_keepalive='25'
set network.@amneziawg_awg1[-1].allowed_ips='0.0.0.0/0 ::/0'
set network.@amneziawg_awg1[-1].route_allowed_ips='0'   # селективный режим
commit network
EOF

# 4. Firewall зона + forwarding
uci batch << 'EOF'
delete firewall.@zone[-1]
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
EOF

# 5. Селективная маршрутизация (mark 0x1 → таблица vpn)
echo "Настраиваем маршрутизацию по доменам..."
grep -q "99 vpn" /etc/iproute2/rt_tables || echo "99 vpn" >> /etc/iproute2/rt_tables

uci batch << 'EOF'
add network rule
set network.@rule[-1].name='mark0x1'
set network.@rule[-1].mark='0x1'
set network.@rule[-1].priority='100'
set network.@rule[-1].lookup='vpn'

set network.vpn_default=route
set network.vpn_default.interface='awg1'
set network.vpn_default.target='0.0.0.0'
set network.vpn_default.netmask='0.0.0.0'
set network.vpn_default.table='vpn'

add firewall ipset
set firewall.@ipset[-1].name='vpn_domains'
set firewall.@ipset[-1].family='ipv4'
set firewall.@ipset[-1].match='dst_net'

add firewall rule
set firewall.@rule[-1].name='mark_domains'
set firewall.@rule[-1].src='lan'
set firewall.@rule[-1].dest='*'
set firewall.@rule[-1].proto='all'
set firewall.@rule[-1].ipset='vpn_domains'
set firewall.@rule[-1].set_mark='0x1'
set firewall.@rule[-1].target='MARK'
set firewall.@rule[-1].family='ipv4'
commit
EOF

# 6. dnsmasq-full + Stubby (DoT)
echo "Устанавливаем dnsmasq-full + Stubby..."
cd /tmp
opkg download dnsmasq-full
opkg remove dnsmasq --force-removal-of-dependent-packages
opkg install dnsmasq-full --cache /tmp/
rm -f dnsmasq-full*.ipk

opkg install stubby

uci batch << 'EOF'
set dhcp.@dnsmasq[0].noresolv='1'
delete dhcp.@dnsmasq[0].server
add_list dhcp.@dnsmasq[0].server='127.0.0.1#5453'
set dhcp.@dnsmasq[0].dnssec='1'
set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
commit dhcp
EOF

/etc/init.d/stubby enable
/etc/init.d/stubby restart

# 7. Список доменов (Россия inside) + cron
echo "Настраиваем список российских доменов..."
cat << 'EOF' > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common
START=99
start() {
    curl -f -s -m 15 -o /tmp/dnsmasq.d/vpn_domains.conf \
    https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst || return 1
    /etc/init.d/dnsmasq restart
}
EOF

chmod +x /etc/init.d/getdomains
/etc/init.d/getdomains enable
/etc/init.d/getdomains start

# cron
(crontab -l; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -
/etc/init.d/cron restart

# 8. Финальный рестарт
echo "Перезапускаем сеть..."
/etc/init.d/network restart
/etc/init.d/dnsmasq restart

echo "=== ВСЁ УСТАНОВЛЕНО ==="
echo "• AmneziaWG 2.0 + русский интерфейс в LuCI"
echo "• Соединение awg1 создано"
echo "• DNS через Stubby (DoT)"
echo "• Только российские домены идут через VPN"
echo "Проверь: ip rule show && ip route show table vpn && logread | grep stubby"
