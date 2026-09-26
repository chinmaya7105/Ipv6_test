#!/usr/bin/env bash
#
# qmi_ipv6_wan_jetson.sh
#
# Standalone QMI IPv6 WAN setup for Jetson/Linux + Airtel.
#
# Usage:
#   sudo bash qmi_ipv6_wan_jetson.sh airtelgprs.com
#
# Defaults:
#   QMI WDM   : /dev/cdc-wdm0
#   WWAN      : wwan_airtel
#   APN       : airtelgprs.com
#
# Environment overrides:
#   QMI_WDM=/dev/cdc-wdm1 QMI_IFACE=wwan0 sudo -E bash qmi_ipv6_wan_jetson.sh airtelgprs.com
#

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
APN="${1:-${QMI_APN:-airtelgprs.com}}"

WDM_PORT="${QMI_WDM:-/dev/cdc-wdm0}"
WWAN_IFACE="${QMI_IFACE:-wwan_airtel}"

IPV6=""
GATEWAY6=""
DNS1=""
DNS2=""
MTU=""
QMI_HANDLE=""
LOG_DIR="/tmp/qmi-ipv6-wan"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/qmi_ipv6_$(date +%Y%m%d_%H%M%S).log"

log() {
    local level="$1"
    shift
    printf '[%s] %s\n' "$level" "$*" | tee -a "$LOG_FILE"
}
info() { log INFO "$*"; }
ok()   { log OK "$*"; }
warn() { log WARN "$*"; }
fail() { log FAIL "$*"; exit 1; }

require_root() {
    [[ "$EUID" -eq 0 ]] || fail "Run with sudo."
}

require_commands() {
    local missing=()
    local c
    for c in qmicli ip ping grep sed awk find sort head tr xargs python3; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || fail "Missing command(s): ${missing[*]}"
}

check_wdm() {
    [[ -e "$WDM_PORT" ]] || fail "QMI WDM device not found: $WDM_PORT"

    qmicli -p -d "$WDM_PORT" --dms-get-operating-mode 2>&1 | tee -a "$LOG_FILE" ||
        fail "QMI device is not responding: $WDM_PORT"

    ok "QMI WDM        : $WDM_PORT"
}

check_iface() {
    [[ -d "/sys/class/net/$WWAN_IFACE" ]] ||
        fail "WWAN interface not found: $WWAN_IFACE"

    ok "WWAN           : $WWAN_IFACE"
}

stop_modemmanager() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ModemManager 2>/dev/null; then
            info "Stopping ModemManager..."
            systemctl stop ModemManager.service 2>&1 | tee -a "$LOG_FILE" || \
                fail "Could not stop ModemManager"
            sleep 2
        fi

        if systemctl is-active --quiet ModemManager 2>/dev/null; then
            fail "ModemManager is still active"
        fi
    else
        pkill -x ModemManager 2>/dev/null || true
        sleep 2
    fi

    ok "MODEMMANAGER   : stopped"
}

check_sim() {
    info "Checking SIM..."

    local out
    out="$(qmicli -p -d "$WDM_PORT" --uim-get-card-status 2>&1)"
    printf '%s\n' "$out" | tee -a "$LOG_FILE"

    grep -qi "Card state: 'present'" <<<"$out" ||
        fail "SIM is not present"

    grep -qi "Application state: 'ready'" <<<"$out" ||
        fail "SIM application is not ready"

    ok "SIM            : READY"
}

check_registration() {
    info "Checking network registration..."

    local out state
    out="$(qmicli -p -d "$WDM_PORT" --nas-get-serving-system 2>&1)"
    printf '%s\n' "$out" | tee -a "$LOG_FILE"

    state="$(grep -Eio "Registration state:[[:space:]]*'[^']+'" <<<"$out" |
        head -n1 | sed -E "s/.*'([^']+)'.*/\1/i")"

    [[ "${state,,}" == "registered" ]] ||
        fail "Network not registered (state=${state:-unknown})"

    ok "REGISTRATION   : registered"
}

set_raw_ip() {
    local raw_file="/sys/class/net/$WWAN_IFACE/qmi/raw_ip"

    if [[ ! -e "$raw_file" ]]; then
        warn "RAW-IP control file not found; continuing."
        return 0
    fi

    local raw
    raw="$(cat "$raw_file" 2>/dev/null || true)"
    info "RAW IP         : ${raw:-unknown}"

    if [[ "$raw" == "N" ]]; then
        info "Enabling RAW-IP..."
        ip link set "$WWAN_IFACE" down 2>&1 | tee -a "$LOG_FILE" || \
            fail "Failed to bring $WWAN_IFACE down"

        printf 'Y' > "$raw_file" 2>/dev/null || \
            fail "Failed to set RAW-IP=Y"

        ip link set "$WWAN_IFACE" up 2>&1 | tee -a "$LOG_FILE" || \
            fail "Failed to bring $WWAN_IFACE up"

        sleep 1
        raw="$(cat "$raw_file" 2>/dev/null || true)"
    fi

    [[ "$raw" == "Y" ]] || warn "RAW-IP is ${raw:-unknown}"
    [[ "$raw" == "Y" ]] && ok "RAW IP         : Y"
}

get_session_status() {
    local out status
    out="$(qmicli -p -d "$WDM_PORT" --wds-get-packet-service-status 2>&1 || true)"
    printf '%s\n' "$out" >> "$LOG_FILE"

    status="$(grep -Eio "Connection status:[[:space:]]*'[^']+'" <<<"$out" |
        head -n1 | sed -E "s/.*'([^']+)'.*/\1/i")"

    echo "${status,,}"
}

start_or_reuse_session() {
    local status
    status="$(get_session_status)"

    if [[ "$status" == "connected" ]]; then
        info "Existing QMI IPv6 data session is CONNECTED"
        return 0
    fi

    info "Starting QMI IPv6 data session..."
    local out rc

    out="$(qmicli -p -d "$WDM_PORT" \
        --wds-start-network="apn=$APN,ip-type=6" \
        --client-no-release-cid 2>&1)"
    rc=$?

    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    ((rc == 0)) || fail "QMI IPv6 DATA SESSION START FAILED"

    QMI_HANDLE="$(grep -Eio "Packet data handle:[[:space:]]*'?[0-9]+'?" <<<"$out" |
        head -n1 | grep -Eo '[0-9]+' | head -n1 || true)"

    sleep 2

    status="$(get_session_status)"
    [[ "$status" == "connected" ]] ||
        fail "IPv6 DATA SESSION NOT CONNECTED (status=${status:-unknown})"

    ok "DATA SESSION   : IPv6 CONNECTED"
}

read_qmi_settings() {
    info "Reading current QMI IPv6 settings..."

    local out rc
    out="$(qmicli -p -d "$WDM_PORT" --wds-get-current-settings 2>&1)"
    rc=$?

    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    ((rc == 0)) || fail "FAILED TO OBTAIN QMI CURRENT SETTINGS"

    IPV6="$(awk -F': ' '/IPv6 address:/ {print $2; exit}' <<<"$out" |
        tr -d "'" | xargs)"

    GATEWAY6="$(awk -F': ' '/IPv6 gateway address:/ {print $2; exit}' <<<"$out" |
        tr -d "'" | xargs)"

    DNS1="$(awk -F': ' '/IPv6 primary DNS:/ {print $2; exit}' <<<"$out" |
        tr -d "'" | xargs)"

    DNS2="$(awk -F': ' '/IPv6 secondary DNS:/ {print $2; exit}' <<<"$out" |
        tr -d "'" | xargs)"

    MTU="$(awk -F': ' '/^[[:space:]]*MTU:/ {print $2; exit}' <<<"$out" |
        tr -d "'" | xargs)"

    [[ "$IPV6" == */* ]] || fail "Dynamic IPv6 address not obtained"
    [[ -n "$GATEWAY6" ]] || fail "Dynamic IPv6 gateway not obtained"

    # qmicli may return gateway as IPv6/64.
    GATEWAY6="${GATEWAY6%%/*}"

    ok "IPv6 ADDRESS   : $IPV6"
    ok "IPv6 GATEWAY    : $GATEWAY6"
    info "IPv6 DNS1      : ${DNS1:-not supplied}"
    info "IPv6 DNS2      : ${DNS2:-not supplied}"
    info "MTU            : ${MTU:-default}"
}

configure_ipv6() {
    info "Configuring $WWAN_IFACE for IPv6..."

    ip link set "$WWAN_IFACE" up 2>&1 | tee -a "$LOG_FILE" || \
        fail "Failed to bring $WWAN_IFACE UP"

    # Remove stale global IPv6 addresses only.
    ip -6 addr flush dev "$WWAN_IFACE" scope global 2>&1 | tee -a "$LOG_FILE" || true

    ip -6 addr add "$IPV6" dev "$WWAN_IFACE" 2>&1 | tee -a "$LOG_FILE" || {
        # It may already exist after a reconnect.
        ip -6 addr replace "$IPV6" dev "$WWAN_IFACE" 2>&1 | tee -a "$LOG_FILE" ||
            fail "Failed to configure IPv6 address"
    }

    if [[ "$MTU" =~ ^[0-9]+$ ]] && ((MTU >= 576 && MTU <= 9000)); then
        ip link set dev "$WWAN_IFACE" mtu "$MTU" 2>&1 | tee -a "$LOG_FILE" || \
            warn "Could not set MTU=$MTU"
    fi

    # Cellular QMI IPv6 commonly presents the address and gateway in the same /64.
    # Dynamically derive the connected /64 from the current QMI IPv6 address.
    # This keeps routing valid when the carrier/SIM assigns a different prefix.
    local IPV6_NETWORK
    IPV6_NETWORK="$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Interface(sys.argv[1]).network)' "$IPV6" 2>/dev/null)" ||         fail "Failed to derive IPv6 network from dynamic address"

    ip -6 route replace "$IPV6_NETWORK" dev "$WWAN_IFACE" metric 100 2>&1 |
        tee -a "$LOG_FILE" || fail "Failed to install IPv6 connected route"

    ok "IPv6 ROUTE      : $IPV6_NETWORK dev $WWAN_IFACE"

    # Use the dynamically supplied QMI gateway for the default route.
    # 'onlink' tells Linux to use the supplied QMI gateway directly.
    ip -6 route replace default via "$GATEWAY6" dev "$WWAN_IFACE" onlink metric 100 2>&1 |
        tee -a "$LOG_FILE" || fail "Failed to install IPv6 default route"

    ok "IPv6 ROUTE      : default via $GATEWAY6 dev $WWAN_IFACE"

    info "Verifying IPv6 route..."
    ip -6 route get 2001:4860:4860::8888 2>&1 | tee -a "$LOG_FILE" ||
        fail "IPv6 route lookup failed"
}

enable_resolved() {
    if ! command -v resolvectl >/dev/null 2>&1; then
        warn "resolvectl not installed; using /etc/resolv.conf fallback."
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            info "Starting systemd-resolved..."
            systemctl start systemd-resolved.service 2>&1 | tee -a "$LOG_FILE" || {
                warn "Could not start systemd-resolved."
                return 1
            }
        fi
    fi

    # Do NOT make DNS configuration depend on changing /etc/resolv.conf.
    # On Jetson/L4T, /etc/resolv.conf may be managed, immutable, or otherwise
    # protected, and ln -sf can fail with EPERM even when running as root.
    # resolvectl can still configure systemd-resolved directly in that case.
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        local resolv_target
        resolv_target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
        if [[ "$resolv_target" == "/run/systemd/resolve/stub-resolv.conf" ]]; then
            ok "RESOLV.CONF    : systemd-resolved stub"
        else
            info "NOTE            : /etc/resolv.conf is managed/protected; using resolvectl directly."
            info "RESOLV.CONF     : $(readlink -f /etc/resolv.conf 2>/dev/null || echo regular-file)"
        fi
    fi

    resolvectl status >/dev/null 2>&1 || {
        warn "systemd-resolved is not responding."
        return 1
    }

    return 0
}

configure_dns() {
    info "Configuring IPv6 DNS automatically..."

    if [[ -z "$DNS1" && -z "$DNS2" ]]; then
        warn "QMI did not provide IPv6 DNS servers."
        return 1
    fi

    local dns_args=()
    [[ -n "$DNS1" ]] && dns_args+=("$DNS1")
    [[ -n "$DNS2" ]] && dns_args+=("$DNS2")

    # Preferred path: configure systemd-resolved on the QMI interface.
    # This is independent of /etc/resolv.conf being replaceable.
    if enable_resolved; then
        resolvectl dns "$WWAN_IFACE" "${dns_args[@]}" 2>&1 |
            tee -a "$LOG_FILE" || {
                warn "resolvectl dns failed."
                return 1
            }

        # Route all DNS queries through the cellular QMI link.
        resolvectl domain "$WWAN_IFACE" "~." 2>&1 |
            tee -a "$LOG_FILE" || {
                warn "resolvectl domain failed."
                return 1
            }

        resolvectl default-route "$WWAN_IFACE" yes 2>&1 |
            tee -a "$LOG_FILE" || {
                warn "resolvectl default-route failed."
                return 1
            }

        resolvectl flush-caches 2>&1 | tee -a "$LOG_FILE" || true

        info "DNS SERVERS    : ${dns_args[*]}"

        # Verify systemd-resolved now sees the cellular link as a DNS route.
        resolvectl status "$WWAN_IFACE" 2>&1 | tee -a "$LOG_FILE" || true

        # If /etc/resolv.conf is not the resolved stub, try to make normal
        # libc applications use resolved. If the platform protects the file,
        # keep the direct resolvectl configuration and fall back to writing
        # QMI DNS servers into resolv.conf when possible.
        local resolv_target
        resolv_target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
        if [[ "$resolv_target" != "/run/systemd/resolve/stub-resolv.conf" &&
              -e /run/systemd/resolve/stub-resolv.conf ]]; then
            info "Attempting to link /etc/resolv.conf to systemd-resolved stub..."

            # Jetson/L4T images may mark /etc/resolv.conf immutable. In that
            # case ln -sf fails even when the script is running as root.
            if command -v lsattr >/dev/null 2>&1; then
                local attrs
                attrs="$(lsattr -d /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
                if [[ "$attrs" == *i* ]]; then
                    warn "/etc/resolv.conf is immutable; removing immutable flag..."
                    if command -v chattr >/dev/null 2>&1 && chattr -i /etc/resolv.conf 2>&1 | tee -a "$LOG_FILE"; then
                        ok "RESOLV.CONF    : immutable flag removed"
                    else
                        warn "Could not remove immutable flag."
                    fi
                fi
            fi

            # Back up the current resolver file, then replace it with the
            # systemd-resolved stub. rm+ln handles a real file or old symlink.
            if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
                cp -L /etc/resolv.conf "/etc/resolv.conf.qmi-backup" 2>/dev/null || true
            fi

            if rm -f /etc/resolv.conf 2>&1 | tee -a "$LOG_FILE" &&
               ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>&1 |
                   tee -a "$LOG_FILE"; then
                ok "RESOLV.CONF    : linked to systemd-resolved stub"
            else
                warn "Could not replace /etc/resolv.conf; keeping resolvectl configuration."
            fi
        fi

        # Verify both resolver paths. Do not fail the WAN setup merely because
        # libc is managed by another resolver, but report it clearly.
        local resolved_ok=0 libc_ok=0
        if resolvectl query google.com 2>&1 | tee -a "$LOG_FILE"; then
            resolved_ok=1
        fi
        if command -v getent >/dev/null 2>&1 &&
           getent ahostsv6 google.com 2>&1 | tee -a "$LOG_FILE" | grep -q ':'; then
            libc_ok=1
        fi

        if ((resolved_ok == 1 && libc_ok == 1)); then
            ok "DNS            : systemd-resolved + libc verified"
        elif ((resolved_ok == 1)); then
            ok "DNS            : systemd-resolved verified"
            warn "libc/getent DNS path is not using the configured resolver yet."
        else
            warn "systemd-resolved DNS query failed."
        fi

        return 0
    fi

    # Fallback when systemd-resolved is unavailable.
    if [[ -w /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "/etc/resolv.conf.qmi-backup" 2>/dev/null || true
        {
            echo "# Generated by $SCRIPT_NAME"
            [[ -n "$DNS1" ]] && echo "nameserver $DNS1"
            [[ -n "$DNS2" ]] && echo "nameserver $DNS2"
        } > /etc/resolv.conf && {
            ok "DNS            : configured using /etc/resolv.conf"
            return 0
        }
    fi

    warn "Unable to configure DNS automatically."
    return 1
}

test_dns() {
    info "Testing IPv6 Internet..."
    if ping -6 -I "$WWAN_IFACE" -c 4 -W 3 2001:4860:4860::8888 2>&1 |
        tee -a "$LOG_FILE"; then
        ok "IPv6 INTERNET  : PING OK"
    else
        fail "IPv6 INTERNET PING FAILED"
    fi

    info "Testing IPv6 DNS resolution: ipv6.google.com"

    local resolved_ok=0
    local libc_ok=0

    if command -v resolvectl >/dev/null 2>&1; then
        if resolvectl query ipv6.google.com 2>&1 | tee -a "$LOG_FILE"; then
            resolved_ok=1
        fi
    fi

    # Verify the resolver used by normal applications as well.
    if command -v getent >/dev/null 2>&1 &&
       getent ahostsv6 ipv6.google.com 2>&1 | tee -a "$LOG_FILE" | grep -q ':'; then
        libc_ok=1
    fi

    if ((resolved_ok == 1 && libc_ok == 1)); then
        ok "IPv6 DNS       : RESOLUTION OK (resolved + libc)"
        return 0
    elif ((resolved_ok == 1)); then
        warn "resolvectl DNS works, but normal application DNS (libc/getent) failed."
    fi

    warn "IPv6 Internet works, but DNS resolution failed."
    warn "Check the QMI DNS servers and systemd-resolved status."
    return 1
}

show_status() {
    echo
    echo "============================================" | tee -a "$LOG_FILE"
    echo "        QMI IPv6 WAN STATUS - JETSON" | tee -a "$LOG_FILE"
    echo "============================================" | tee -a "$LOG_FILE"
    echo "WDM PORT       : $WDM_PORT" | tee -a "$LOG_FILE"
    echo "WWAN           : $WWAN_IFACE" | tee -a "$LOG_FILE"
    echo "APN            : $APN" | tee -a "$LOG_FILE"
    echo "IPv6 ADDRESS   : $IPV6" | tee -a "$LOG_FILE"
    echo "IPv6 GATEWAY   : $GATEWAY6" | tee -a "$LOG_FILE"
    echo "IPv6 DNS1      : $DNS1" | tee -a "$LOG_FILE"
    echo "IPv6 DNS2      : $DNS2" | tee -a "$LOG_FILE"
    echo "DATA SESSION   : $(get_session_status | tail -n1)" | tee -a "$LOG_FILE"
    echo "--------------------------------------------" | tee -a "$LOG_FILE"
    ip -6 addr show dev "$WWAN_IFACE" scope global | tee -a "$LOG_FILE"
    ip -6 route show | tee -a "$LOG_FILE"

    if command -v resolvectl >/dev/null 2>&1; then
        echo "--------------------------------------------" | tee -a "$LOG_FILE"
        resolvectl status "$WWAN_IFACE" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    echo "--------------------------------------------" | tee -a "$LOG_FILE"
    echo "LOG            : $LOG_FILE" | tee -a "$LOG_FILE"
    echo "============================================" | tee -a "$LOG_FILE"
}

main() {
    require_root
    require_commands

    info "Starting standalone QMI IPv6 WAN for Jetson"
    info "WDM            : $WDM_PORT"
    info "WWAN           : $WWAN_IFACE"
    info "APN            : $APN"

    check_wdm
    check_iface
    stop_modemmanager
    set_raw_ip
    check_sim
    check_registration
    start_or_reuse_session
    read_qmi_settings
    configure_ipv6

    if ! configure_dns; then
        warn "DNS configuration was not confirmed."
    fi

    test_dns || true
    show_status
}

main "$@"
