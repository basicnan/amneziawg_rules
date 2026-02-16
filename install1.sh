#!/bin/sh
# =============================================================================
# Дополнение после установки AmneziaWG 2.0
# Настройка awg1 + маршрутизация + Stubby + списки доменов
# =============================================================================

set -e

echo "=== Настраиваем AmneziaWG awg1 + маршрутизацию + DNS over TLS ==="

# 1. Создаём интерфейс awg1 (твои точные настройки)
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
set network.@amneziawg_awg1[-1].route_allowed_ips='0'   # селективный режим (не full-tunnel)
commit network
EOF

# 2. Firewall-зона + forwarding lan → awg1
uci batch << 'EOF'
delete firewall.@zone[?name='awg1']
add firewall zone
set firewall.@zone[-1].name='awg1'
set firewall.@zone[-1].network='awg1'
set firewall.@zone[-1].input='REJECT'
set firewall.@zone[-1].output='ACCEPT'
set firewall.@zone[-1].forward='REJECT'
set firewall.@zone[-1].masq='1'
set firewall.@zone[-1].mtu_fix='1'
set firewall.@zone[-1].family='ipv4'

delete firewall.@forwarding[?src='lan' && dest='awg1']
add firewall forwarding
set firewall.@forwarding[-1].src='lan'
set firewall.@forwarding[-1].dest='awg1'
commit firewall
EOF

# 3. Селективная маршрутизация (mark 0x1 → таблица vpn)
grep -q "99 vpn" /etc/iproute2/rt_tables || echo "99 vpn" >> /etc/iproute2/rt_tables

uci batch << 'EOF'
delete network.@rule[?name='mark0x1']
add network rule
set network.@rule[-1].name='mark0x1'
set network.@rule[-1].mark='0x1'
set network.@rule[-1].priority='100'
set network.@rule[-1].lookup='vpn'

delete network.vpn_default
set network.vpn_default=route
set network.vpn_default.interface='awg1'
set network.vpn_default.target='0.0.0.0'
set network.vpn_default.netmask='0.0.0.0'
set network.vpn_default.table='vpn'

delete firewall.@ipset[?name='vpn_domains']
add firewall ipset
set firewall.@ipset[-1].name='vpn_domains'
set firewall.@ipset[-1].family='ipv4'
set firewall.@ipset[-1].match='dst_net'

delete firewall.@rule[?name='mark_domains']
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

# 4. dnsmasq-full + Stubby (DoT)
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

# 5. Список доменов (Россия inside) + cron-обновление
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

# cron: каждые 8 часов
(crontab -l 2>/dev/null; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -

# 6. Финальный рестарт
echo "Перезапускаем сеть и DNS..."
/etc/init.d/network restart
/etc/init.d/dnsmasq restart

echo "=== ГОТОВО! ==="
echo "• AmneziaWG 2.0 установлен + русский интерфейс в LuCI"
echo "• Соединение awg1 настроено (проверь статус в LuCI → Interfaces)"
echo "• DNS → Stubby (DoT) на 127.0.0.1#5453"
echo "• Только российские домены идут через VPN (mark 0x1)"
echo "Проверь:"
echo "  ip rule show"
echo "  ip route show table vpn"
echo "  logread | grep amnezia"
echo "  logread | grep stubby"
echo "  ping google.com"
