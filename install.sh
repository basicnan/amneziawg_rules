#!/bin/sh
# ================================================
# Полный скрипт: AmneziaWG + Stubby DoT + селективная маршрутизация
# Для OpenWrt 24.10 (ramips/mt7621)
# ================================================

set -e

check_repo() {
    printf "\033[32;1mПроверка репозитория OpenWrt...\033[0m\n"
    opkg update | grep -q "Failed to download" && {
        printf "\033[31;1mopkg не работает. Проверьте интернет или дату.\033[0m\n"
        exit 1
    }
}

# ================== Установка AmneziaWG ==================
install_awg_packages() {
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    # Определяем версию протокола
    MAJOR=$(echo "$VERSION" | cut -d. -f1)
    MINOR=$(echo "$VERSION" | cut -d. -f2)
    PATCH=$(echo "$VERSION" | cut -d. -f3)
    if [ "$MAJOR" -gt 24 ] || [ "$MAJOR" -eq 24 -a "$MINOR" -ge 10 -a "$PATCH" -ge 3 ] || \
       [ "$MAJOR" -eq 23 -a "$MINOR" -eq 5 -a "$PATCH" -ge 6 ]; then
        AWG_VERSION="2.0"
        LUCI_PACKAGE="luci-proto-amneziawg"
    else
        AWG_VERSION="1.0"
        LUCI_PACKAGE="luci-app-amneziawg"
    fi

    printf "\033[32;1mУстанавливаем AmneziaWG %s...\033[0m\n" "$AWG_VERSION"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    for pkg in kmod-amneziawg amneziawg-tools "$LUCI_PACKAGE"; do
        if opkg list-installed | grep -q "^$pkg "; then
            echo "$pkg уже установлен"
            continue
        fi
        filename="${pkg}${PKGPOSTFIX}"
        wget -O "$AWG_DIR/$filename" "${BASE_URL}v${VERSION}/$filename"
        opkg install "$AWG_DIR/$filename"
    done

    rm -rf "$AWG_DIR"
}

# ================== Настройка awg1 (ваши данные) ==================
configure_awg1() {
    printf "\033[32;1mНастраиваем интерфейс awg1 (селективный режим)...\033[0m\n"

    uci set network.awg1=interface
    uci set network.awg1.proto='amneziawg'
    uci set network.awg1.private_key='wMAsr1efyZAw8RkKZw5OrsoK8pfziAUgm4si5E5Wv3M='
    uci set network.awg1.listen_port='51821'
    uci set network.awg1.addresses='10.201.66.154/32'
    uci set network.awg1.mtu='1380'

    # Параметры AmneziaWG
    uci set network.awg1.awg_jc='43'
    uci set network.awg1.awg_jmin='50'
    uci set network.awg1.awg_jmax='70'
    uci set network.awg1.awg_s1='110'
    uci set network.awg1.awg_s2='120'
    uci set network.awg1.awg_h1='1593635057'
    uci set network.awg1.awg_h2='430880481'
    uci set network.awg1.awg_h3='1214405368'
    uci set network.awg1.awg_h4='1739253821'

    # Peer
    if ! uci show network | grep -q amneziawg_awg1; then
        uci add network amneziawg_awg1
    fi
    uci set network.@amneziawg_awg1[0]=amneziawg_awg1
    uci set network.@amneziawg_awg1[0].name='awg1_client'
    uci set network.@amneziawg_awg1[0].public_key='n0z+oioqL8meQmsU1aPx0fXiMPzStqM3VwkVSmAqzG0='
    uci set network.@amneziawg_awg1[0].preshared_key='4PnWMu0LNNrXyYt03CcI6KSI3NFb2wCCfbE1EDmdP1c='
    uci set network.@amneziawg_awg1[0].endpoint_host='nl01a.kcufwfgnkr.net'
    uci set network.@amneziawg_awg1[0].endpoint_port='62931'
    uci set network.@amneziawg_awg1[0].persistent_keepalive='25'
    uci set network.@amneziawg_awg1[0].allowed_ips='0.0.0.0/0 ::/0'
    uci set network.@amneziawg_awg1[0].route_allowed_ips='0'   # ← важно для селективной маршрутизации

    uci commit network
}

# ================== Селективная маршрутизация ==================
setup_policy_routing() {
    printf "\033[32;1mНастраиваем политику маршрутизации (mark 0x1 → таблица vpn)...\033[0m\n"

    grep -q "99 vpn" /etc/iproute2/rt_tables || echo "99 vpn" >> /etc/iproute2/rt_tables

    # Правило mark
    if ! uci show network | grep -q mark0x1; then
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
    fi

    # Маршрут по умолчанию в таблице vpn
    if ! uci show network | grep -q vpn_default; then
        uci set network.vpn_default=route
        uci set network.vpn_default.interface='awg1'
        uci set network.vpn_default.target='0.0.0.0'
        uci set network.vpn_default.netmask='0.0.0.0'
        uci set network.vpn_default.table='vpn'
        uci commit network
    fi

    # ipset/nft set
    if ! uci show firewall | grep -q vpn_domains; then
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].family='ipv4'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit firewall
    fi

    # Правило MARK
    if ! uci show firewall | grep -q mark_domains; then
        uci add firewall rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit firewall
    fi
}

# ================== Stubby (DoT) + dnsmasq-full ==================
setup_stubby() {
    printf "\033[32;1mУстанавливаем и настраиваем Stubby (DNS over TLS)...\033[0m\n"

    opkg install stubby dnsmasq-full

    # dnsmasq → Stubby
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5453'
    uci set dhcp.@dnsmasq[0].dnssec='1'
    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
    uci commit dhcp

    /etc/init.d/stubby enable
    /etc/init.d/stubby start
    /etc/init.d/dnsmasq restart
}

# ================== Список доменов (Россия inside) ==================
setup_domains() {
    printf "\033[32;1mНастраиваем список доменов (Россия inside) через nftset...\033[0m\n"

    cat << 'EOF' > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common
START=99

start() {
    DOMAINS="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    curl -f -s -m 10 -o /tmp/dnsmasq.d/vpn_domains.conf "$DOMAINS" || {
        logger -t getdomains "Не удалось скачать список доменов"
        return 1
    }
    /etc/init.d/dnsmasq restart
}
EOF

    chmod +x /etc/init.d/getdomains
    /etc/init.d/getdomains enable
    /etc/init.d/getdomains start

    # Обновление каждые 8 часов
    if ! crontab -l | grep -q getdomains; then
        (crontab -l; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -
        /etc/init.d/cron restart
    fi
}

# ================== Основной запуск ==================
check_repo
install_awg_packages
configure_awg1
setup_policy_routing
setup_stubby
setup_domains

printf "\033[32;1mПерезапускаем сеть...\033[0m\n"
service network restart

printf "\033[42;1mГотово!\033[0m\n"
printf "• AmneziaWG awg1 настроен\n"
printf "• DNS через Stubby (DoT)\n"
printf "• Маршрутизация по доменам (Россия inside) через VPN\n"
printf "• Для добавления своих доменов/IP — редактируйте /tmp/dnsmasq.d/vpn_domains.conf и перезапустите dnsmasq\n"
