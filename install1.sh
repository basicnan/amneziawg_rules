#!/bin/sh
# ================================================
# ПОЛНЫЙ СКРИПТ ДЛЯ ЧИСТОГО OpenWrt 24.10
# AmneziaWG + Stubby (DoT) + селективная маршрутизация (Россия inside)
# ================================================

set -e

printf "\033[36;1m=== Начинаем установку с нуля ===\033[0m\n"

# 1. Обновляем репозитории
opkg update

# 2. Безопасная замена dnsmasq → dnsmasq-full
printf "\033[32;1mУстанавливаем dnsmasq-full (заменяем обычный dnsmasq)...\033[0m\n"
cd /tmp
opkg download dnsmasq-full
opkg remove dnsmasq --force-removal-of-dependent-packages
opkg install dnsmasq-full --cache /tmp/
rm -f dnsmasq-full*.ipk

# 3. Устанавливаем AmneziaWG + Stubby
printf "\033[32;1mУстанавливаем AmneziaWG и Stubby...\033[0m\n"
opkg install kmod-amneziawg amneziawg-tools luci-proto-amneziawg stubby

# 4. Настройка интерфейса awg1 (твои данные)
printf "\033[32;1mНастраиваем AmneziaWG awg1...\033[0m\n"
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

# Peer
delete network.@amneziawg_awg1[-1]
add network amneziawg_awg1
set network.@amneziawg_awg1[-1].name='awg1_client'
set network.@amneziawg_awg1[-1].public_key='n0z+oioqL8meQmsU1aPx0fXiMPzStqM3VwkVSmAqzG0='
set network.@amneziawg_awg1[-1].preshared_key='4PnWMu0LNNrXyYt03CcI6KSI3NFb2wCCfbE1EDmdP1c='
set network.@amneziawg_awg1[-1].endpoint_host='nl01a.kcufwfgnkr.net'
set network.@amneziawg_awg1[-1].endpoint_port='62931'
set network.@amneziawg_awg1[-1].persistent_keepalive='25'
set network.@amneziawg_awg1[-1].allowed_ips='0.0.0.0/0 ::/0'
set network.@amneziawg_awg1[-1].route_allowed_ips='0'   # важно для селективной маршрутизации
commit network
EOF

# 5. Селективная маршрутизация (mark 0x1 → таблица vpn)
printf "\033[32;1mНастраиваем маршрутизацию по доменам...\033[0m\n"
grep -q "99 vpn" /etc/iproute2/rt_tables || echo "99 vpn" >> /etc/iproute2/rt_tables

uci batch << 'EOF'
# правило mark
delete network.@rule[-1]
add network rule
set network.@rule[-1].name='mark0x1'
set network.@rule[-1].mark='0x1'
set network.@rule[-1].priority='100'
set network.@rule[-1].lookup='vpn'

# маршрут в отдельной таблице
set network.vpn_default=route
set network.vpn_default.interface='awg1'
set network.vpn_default.target='0.0.0.0'
set network.vpn_default.netmask='0.0.0.0'
set network.vpn_default.table='vpn'

# ipset
delete firewall.@ipset[-1]
add firewall ipset
set firewall.@ipset[-1].name='vpn_domains'
set firewall.@ipset[-1].family='ipv4'
set firewall.@ipset[-1].match='dst_net'

# правило MARK
delete firewall.@rule[-1]
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

# 6. Stubby (DNS over TLS)
printf "\033[32;1mНастраиваем Stubby (DoT)...\033[0m\n"
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
printf "\033[32;1mСоздаём список российских доменов...\033[0m\n"
cat << 'EOF' > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common
START=99

start() {
    curl -f -s -m 15 -o /tmp/dnsmasq.d/vpn_domains.conf \
    https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst || {
        logger -t getdomains "Не удалось скачать список"
        return 1
    }
    /etc/init.d/dnsmasq restart
}
EOF

chmod +x /etc/init.d/getdomains
/etc/init.d/getdomains enable
/etc/init.d/getdomains start

# cron — обновление каждые 8 часов
if ! crontab -l | grep -q getdomains; then
    (crontab -l; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -
    /etc/init.d/cron restart
fi

# 8. Финальный рестарт
printf "\033[32;1mПерезапускаем сеть и DNS...\033[0m\n"
 /etc/init.d/network restart
 /etc/init.d/dnsmasq restart

printf "\033[42;1m=== УСТАНОВКА ЗАВЕРШЕНА ===\033[0m\n"
printf "Проверь:\n"
printf "• ping google.com\n"
printf "• ip rule show          (должен быть mark 0x1 lookup vpn)\n"
printf "• ip route show table vpn\n"
printf "• logread | grep stubby\n"
printf "• logread | grep dnsmasq\n\n"
printf "Если всё ок — трафик к российским сайтам пойдёт через AmneziaWG.\n"
