#!/bin/bash
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

# ─── Output helpers ──────────────────────────────────────────────────────────
msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

echo
msg_inf '        __           ___    _   _   _  '
msg_inf      '|  | | /   \/ __ | |  | __ |_) |_) / \ '
msg_inf      '|_ |_| \__ /\    |_| _|_   |   | \ \_/ '
echo
_os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
_os_ver=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
_os_id_cap=$(echo "${_os_id}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
echo "The OS release is: ${_os_id_cap} ${_os_ver}"
echo

# ─── Pre-flight checks ───────────────────────────────────────────────────────
check_os() {
    local os_id os_version

    if [[ ! -r /etc/os-release ]]; then
        msg_err "Unable to read /etc/os-release"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"

    case "${os_id}" in
        ubuntu)
            [[ "$os_version" == "24.04" || "$os_version" == "26.04" ]] && return 0
            ;;
        debian)
            [[ "$os_version" == "12" || "$os_version" == "13" ]] && return 0
            ;;
    esac

    msg_err "Unsupported OS: ${os_id} ${os_version}"
    echo -e "\nThis script supports:\n  Ubuntu 24.04 / 26.04\n  Debian 12 / 13"
    echo -e "\nPlease reinstall your server with one of the supported OS versions and try again."
    exit 1
}

check_cpu() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)

    if echo "$cpu_model" | grep -qi 'QEMU'; then
        msg_err "QEMU virtual CPU detected!"
        echo -e "\nYour VPS is running with an emulated QEMU processor."
        echo -e "Please contact your hosting provider and ask them to switch the CPU type"
        echo -e "to \e[1;33mhost-passthrough\e[0m (expose real CPU model to the VM)."
        echo -e "\nThis is required for correct operation of the Xray core."
        exit 1
    fi
}

check_os
check_cpu

# Package manager used by install/uninstall cleanup. Must be initialized before
# any path that can call uninstall_xui during a repeated/full installation.
Pak="apt-get"

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/ttrroyy/lucx-ui-pro/main"
FAKE_SITE_COUNT=50
PREINSTALL_STATE_DIR="/var/lib/lucx-ui-preinstall"
INSTALL_IN_PROGRESS_FILE="${PREINSTALL_STATE_DIR}/install-in-progress"

# ─── Default argument values ─────────────────────────────────────────────────
domain=""
reality_domain=""
UNINSTALL=""
INSTALL=""
AUTODOMAIN="n"
CFALLOW="n"
PANEL_VERSION=""
DNS_CHOICE=""
DEPLOY_QWDTT=""
DEPLOY_CSQTT=""
DEPLOY_AGH=""
DEPLOY_HY2=""
DEPLOY_TPROXY=""
webproxy_domain=""
TPROXY_SECRET=""
ADGUARD_ONLY=""
ADGUARD_UNINSTALL=""
RKN_GUARD_ONLY=""
RKN_GUARD_UNINSTALL=""
TG_WEB_PROXY_ONLY=""
TG_WEB_PROXY_UNINSTALL=""
DEPLOY_RKN=""
DEPLOY_AWG=""
BASE_DEPENDENCIES_READY="0"
CUSTOM_DOH_URL=""
CUSTOM_DOH_HOST=""
CUSTOM_DOH_IP=""

# ─── Preserve firewall state for a reversible full uninstall ────────────────
save_firewall_state() {
    local state_dir="${PREINSTALL_STATE_DIR}/firewall"
    [[ -f "${state_dir}/saved" ]] && return 0

    mkdir -p "$state_dir"
    {
        if command -v ufw >/dev/null 2>&1; then
            echo 'UFW_WAS_INSTALLED=1'
            if ufw status 2>/dev/null | grep -q '^Status: active'; then
                echo 'UFW_WAS_ACTIVE=1'
            else
                echo 'UFW_WAS_ACTIVE=0'
            fi
        else
            echo 'UFW_WAS_INSTALLED=0'
            echo 'UFW_WAS_ACTIVE=0'
        fi
        printf 'IPV4_FORWARD_WAS=%q\n' \
            "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    } > "${state_dir}/state"

    tar -cpf "${state_dir}/ufw-config.tar" \
        /etc/ufw /etc/default/ufw /etc/ipset.conf /etc/iptables/ipsets \
        2>/dev/null || true
    command -v iptables-save >/dev/null 2>&1 && \
        iptables-save > "${state_dir}/iptables.v4" 2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && \
        ip6tables-save > "${state_dir}/iptables.v6" 2>/dev/null || true
    touch "${state_dir}/saved"
}

restore_firewall_state() {
    local state_dir="${PREINSTALL_STATE_DIR}/firewall"
    local UFW_WAS_INSTALLED=0 UFW_WAS_ACTIVE=0 IPV4_FORWARD_WAS=0

    if [[ ! -f "${state_dir}/saved" || ! -f "${state_dir}/state" ]]; then
        # Older installations did not save a snapshot. Their documented
        # starting point was a clean server, so use UFW's clean inactive state.
        if command -v ufw >/dev/null 2>&1; then
            ufw --force disable >/dev/null 2>&1 || true
            ufw --force reset >/dev/null 2>&1 || true
            ufw default deny incoming >/dev/null 2>&1 || true
            ufw default allow outgoing >/dev/null 2>&1 || true
            ufw default deny routed >/dev/null 2>&1 || true
            ufw --force disable >/dev/null 2>&1 || true
        fi
        rm -f /etc/sysctl.d/99-lucx-ui-forwarding.conf
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
        msg_inf "Firewall snapshot not found; UFW reset to a clean disabled state."
        return 0
    fi

    # shellcheck disable=SC1090
    source "${state_dir}/state"
    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
        ufw --force reset >/dev/null 2>&1 || true
    fi

    if [[ "$UFW_WAS_INSTALLED" == "1" ]]; then
        [[ -f "${state_dir}/ufw-config.tar" ]] && \
            tar -xpf "${state_dir}/ufw-config.tar" -C / 2>/dev/null || true
        if [[ "$UFW_WAS_ACTIVE" == "1" ]]; then
            ufw --force enable >/dev/null 2>&1 || true
        else
            ufw --force disable >/dev/null 2>&1 || true
        fi
    else
        ufw --force disable >/dev/null 2>&1 || true
    fi

    [[ -s "${state_dir}/iptables.v4" ]] && \
        command -v iptables-restore >/dev/null 2>&1 && \
        iptables-restore < "${state_dir}/iptables.v4" 2>/dev/null || true
    [[ -s "${state_dir}/iptables.v6" ]] && \
        command -v ip6tables-restore >/dev/null 2>&1 && \
        ip6tables-restore < "${state_dir}/iptables.v6" 2>/dev/null || true

    rm -f /etc/sysctl.d/99-lucx-ui-forwarding.conf
    sysctl -w "net.ipv4.ip_forward=${IPV4_FORWARD_WAS}" >/dev/null 2>&1 || true

    msg_ok "Firewall restored to its pre-install state."
}

# Snapshot shared resources before the first mutation. The marker is written last.
# Uninstall refuses to guess ownership if this snapshot is missing.
save_preinstall_state() {
    local dir="${PREINSTALL_STATE_DIR}" path
    umask 077
    install -d -m 0700 "$dir"
    : > "$dir/existing-paths"
    for path in /etc/nginx /var/www/html /var/www/diagnostics /var/www/subpage \
                /etc/sysctl.conf /etc/default/x-ui /etc/fail2ban /etc/modules-load.d/tcp-bbr.conf \
                /etc/modules-load.d/lucx-ui-network.conf \
                /etc/sysctl.d/99-bbr-x-ui.conf \
                /etc/sysctl.d/99-zz-lucx-ui-tuning.conf \
                /etc/sysctl.d/99-awg-performance.conf /etc/modules-load.d/amneziawg.conf; do
        if [[ -e "$path" || -L "$path" ]]; then
            printf '%s\n' "$path" >> "$dir/existing-paths"
            tar -rpf "$dir/baseline.tar" -C / "${path#/}" || return 1
        fi
    done
    : > "$dir/packages"
    for path in nginx nginx-common nginx-core nginx-full certbot python3-certbot-nginx \
                ufw fail2ban ipset iptables cron sqlite3 mtr libcap2-bin; do
        dpkg-query -W -f='${Status}' "$path" 2>/dev/null | grep -qx 'install ok installed' && \
            printf '%s\n' "$path" >> "$dir/packages"
    done
    systemctl is-enabled --quiet nginx && touch "$dir/nginx-enabled" || true
    systemctl is-active --quiet nginx && touch "$dir/nginx-active" || true
    crontab -l > "$dir/root-crontab" 2>/dev/null || : > "$dir/root-crontab"
    sysctl -n net.core.default_qdisc > "$dir/qdisc" 2>/dev/null || true
    sysctl -n net.ipv4.tcp_congestion_control > "$dir/congestion-control" 2>/dev/null || true
    save_firewall_state || return 1
    touch "$dir/owned-by-lucx-ui-pro"
}

restore_preinstall_state() {
    local dir="$PREINSTALL_STATE_DIR" path package
    msg_inf "Восстанавливаю файлы и настройки, сохранённые до установки..."
    # Remove only paths that were absent before install; restore originals in place.
    for path in /etc/nginx /var/www/html /var/www/diagnostics /var/www/subpage \
                /etc/default/x-ui /etc/fail2ban \
                /etc/modules-load.d/tcp-bbr.conf /etc/modules-load.d/lucx-ui-network.conf \
                /etc/sysctl.d/99-bbr-x-ui.conf /etc/sysctl.d/99-zz-lucx-ui-tuning.conf \
                /etc/sysctl.d/99-awg-performance.conf /etc/modules-load.d/amneziawg.conf; do
        grep -Fxq "$path" "$dir/existing-paths" || rm -rf -- "$path"
    done
    # Keep certificates and certbot's renewal state, including those issued
    # during this install. Older snapshots may contain them: never roll back
    # a renewed certificate to the version from before installation.
    [[ ! -s "$dir/baseline.tar" ]] || tar -xpf "$dir/baseline.tar" -C / \
        --exclude='root/cert' --exclude='root/cert/*' \
        --exclude='etc/letsencrypt' --exclude='etc/letsencrypt/*' \
        --exclude='var/lib/letsencrypt' --exclude='var/lib/letsencrypt/*' \
        --exclude='var/log/letsencrypt' --exclude='var/log/letsencrypt/*' || {
            msg_err "Не удалось восстановить исходные файлы из снимка."
            return 1
        }
    # The installer edits nginx.conf and sysctl.conf; restore them even when
    # another process created them after the snapshot.
    if ! grep -Fxq /etc/sysctl.conf "$dir/existing-paths"; then rm -f /etc/sysctl.conf; fi
    sysctl -w "net.core.default_qdisc=$(cat "$dir/qdisc")" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.tcp_congestion_control=$(cat "$dir/congestion-control")" >/dev/null 2>&1 || true
    restore_firewall_state
    if [[ -f "$dir/nginx-enabled" ]]; then systemctl enable nginx >/dev/null 2>&1 || true
    else systemctl disable nginx >/dev/null 2>&1 || true; fi
    if [[ -f "$dir/nginx-active" ]]; then systemctl start nginx >/dev/null 2>&1 || true; fi
    # No autoremove: it could remove packages installed by the administrator.
    msg_inf "Удаляю пакеты, установленные вместе с панелью (certbot сохраняется)..."
    for package in nginx-full nginx nginx-common nginx-core fail2ban ipset iptables ufw cron sqlite3 mtr libcap2-bin netcat-openbsd; do
        if ! grep -Fxq "$package" "$dir/packages" && dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
            msg_inf "  Удаляю пакет: ${package}"
            apt-get -y purge "$package" >/dev/null 2>&1 || msg_err "Не удалось удалить пакет ${package}; проверьте его вручную."
        fi
    done
}

clean_previous_install() {
    # A repeated install already ran the owned uninstall before any questions.
    # On a fresh install no panel files may be removed here.
    if [[ -e /etc/x-ui || -e /usr/local/x-ui || -e /usr/bin/x-ui ]]; then
        msg_err "Another x-ui installation exists. Refusing to overwrite it."
        return 1
    fi
}

mark_install_in_progress() {
    mkdir -p "${PREINSTALL_STATE_DIR}"
    : > "${INSTALL_IN_PROGRESS_FILE}"
    chmod 0600 "${INSTALL_IN_PROGRESS_FILE}"
}

clear_install_in_progress() {
    rm -f "${INSTALL_IN_PROGRESS_FILE}"
}

# ─── Port / path generators ──────────────────────────────────────────────────
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

# Matches the panel's host group_id format (16 lowercase alphanumerics)
gen_group_id() {
    head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c 16
    echo
}

check_free() {
    if command -v nc >/dev/null 2>&1; then
        timeout 1 nc -w 1 -z 127.0.0.1 "$1" &>/dev/null
        return $?
    fi
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && return 0
    return 1
}

make_port() {
    while true; do
        local PORT
        PORT=$(get_port)
        if ! check_free "$PORT"; then
            echo "$PORT"
            break
        fi
    done
}

# ─── Generate ports & paths (done once at startup) ───────────────────────────
sub_port=$(make_port)
panel_port=$(make_port)
clash_port=$(make_port)
while [[ "$clash_port" == "$sub_port" || "$clash_port" == "$panel_port" ]]; do clash_port=$(make_port); done
hy2_port=""

sub_path=$(gen_random_string 10)
json_path=$(gen_random_string 10)
panel_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)

# ─── Argument parsing ────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage:
  bash lucx-ui-latest.sh -install y [options]
  bash lucx-ui-latest.sh -uninstall y
  bash lucx-ui-latest.sh -adguard y
  bash lucx-ui-latest.sh -adguard-uninstall y
  bash lucx-ui-latest.sh -rkn-guard y
  bash lucx-ui-latest.sh -rkn-guard-uninstall y
  bash lucx-ui-latest.sh -tg-web-proxy y
  bash lucx-ui-latest.sh -tg-web-proxy-uninstall y
EOF
}

require_arg_value() {
    [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != -* ]] || {
        msg_err "Option ${1} requires a value."
        usage
        exit 2
    }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -install)          require_arg_value "$@"; INSTALL="$2";            shift 2 ;;
        -ONLY_CF_IP_ALLOW) require_arg_value "$@"; CFALLOW="$2";            shift 2 ;;
        -version)          require_arg_value "$@"; PANEL_VERSION="$2";      shift 2 ;;
        -adguard)          require_arg_value "$@"; ADGUARD_ONLY="$2";       shift 2 ;;
        -adguard-uninstall) require_arg_value "$@"; ADGUARD_UNINSTALL="$2"; shift 2 ;;
        -rkn-guard)        require_arg_value "$@"; RKN_GUARD_ONLY="$2";     shift 2 ;;
        -rkn-guard-uninstall) require_arg_value "$@"; RKN_GUARD_UNINSTALL="$2"; shift 2 ;;
        -tg-web-proxy)     require_arg_value "$@"; TG_WEB_PROXY_ONLY="$2";  shift 2 ;;
        -tg-web-proxy-uninstall) require_arg_value "$@"; TG_WEB_PROXY_UNINSTALL="$2"; shift 2 ;;
        -uninstall)        require_arg_value "$@"; UNINSTALL="$2";          shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 msg_err "Unknown option: $1"; usage; exit 2 ;;
    esac
done

for _action_value in "$INSTALL" "$UNINSTALL" "$ADGUARD_ONLY" "$ADGUARD_UNINSTALL" \
                     "$RKN_GUARD_ONLY" "$RKN_GUARD_UNINSTALL" \
                     "$TG_WEB_PROXY_ONLY" "$TG_WEB_PROXY_UNINSTALL"; do
    [[ -z "$_action_value" || "$_action_value" == "y" ]] || {
        msg_err "Action options accept only the value: y"
        usage
        exit 2
    }
done
[[ "$CFALLOW" == "y" || "$CFALLOW" == "n" ]] || {
    msg_err "-ONLY_CF_IP_ALLOW accepts only y or n."
    exit 2
}

_action_count=0
for _action_value in "$INSTALL" "$UNINSTALL" "$ADGUARD_ONLY" "$ADGUARD_UNINSTALL" \
                     "$RKN_GUARD_ONLY" "$RKN_GUARD_UNINSTALL" \
                     "$TG_WEB_PROXY_ONLY" "$TG_WEB_PROXY_UNINSTALL"; do
    [[ "$_action_value" == "y" ]] && _action_count=$((_action_count + 1))
done
if (( _action_count != 1 )); then
    msg_err "Specify exactly one valid install or uninstall command."
    usage
    exit 2
fi

# ─── AmneziaWG install choice (must be the first install question) ────────────
choose_amneziawg() {
    [[ "${INSTALL}" == "y" ]] || return 0
    [[ -n "${DEPLOY_AWG}" ]] && return 0

    # In a non-interactive stdin-only invocation there is no safe way to ask.
    # Preserve the historical non-interactive behaviour: install AWG unless
    # an explicit interactive menu choice is available.
    if [[ ! -t 0 || ! -r /dev/tty ]]; then
        DEPLOY_AWG="y"
        return 0
    fi

    local ans
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Установка AmneziaWG kernel module:'
        echo '  1) Установить AmneziaWG kernel module'
        echo '  2) Не устанавливать сейчас'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Выбор [1-2]: '
        read -r ans </dev/tty || ans=""
        case "${ans// /}" in
            1) DEPLOY_AWG="y"; break ;;
            2) DEPLOY_AWG="n"; break ;;
            *) continue ;;
        esac
    done
}

# The choice is presented only after any previous full LucX installation has
# been completely removed, but still before domain/DNS/RKN questions.

download_one_geo() {
    local dest="$1" name="$2" url="$3" fallback="${4:-}" min_bytes="${5:-50000}"
    local tmp http size head
    tmp="${dest}/${name}.tmp.$$"
    rm -f "$tmp"
    http=$(curl -sSfLRo "$tmp" --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 -w '%{http_code}' "$url" || true)
    if [[ "$http" != "200" || ! -s "$tmp" ]]; then
        rm -f "$tmp"
        if [[ -n "$fallback" ]]; then
            http=$(curl -sSfLRo "$tmp" --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 -w '%{http_code}' "$fallback" || true)
        fi
    fi
    if [[ "$http" != "200" || ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "Failed to download ${name}"
        return 1
    fi
    size=$(wc -c < "$tmp"); size=${size// /}
    head=$(head -c 64 "$tmp" | tr -d '\0' || true)
    if printf '%s' "$head" | grep -qiE '<html|<!doctype|^Not Found|^404'; then
        rm -f "$tmp"
        echo "${name} looks like HTML, not a .dat"
        return 1
    fi
    if (( size < min_bytes )); then
        rm -f "$tmp"
        echo "${name} too small (${size} bytes)"
        return 1
    fi
    mv -f "$tmp" "${dest}/${name}"
    echo "  ${name}: ${size} bytes"
}
ensure_stock_geo() {
    local dest="$1" name="$2" url="$3" fallback="${4:-}" min_bytes="${5:-50000}"
    if [[ -s "${dest}/${name}" ]]; then
        echo "  ${name}: already present, leave stock file"
        return 0
    fi
    download_one_geo "$dest" "$name" "$url" "$fallback" "$min_bytes"
}
fetch_lucx_geofiles() {
    local dest="${1:-/usr/local/x-ui/bin}"
    mkdir -p "$dest"
    local GH='https://github.com'
    local RAW='https://raw.githubusercontent.com'
    local CDN='https://cdn.jsdelivr.net/gh'
    echo "Ensuring stock LucX/3x-ui geodata (no overwrite) ..."
    ensure_stock_geo "$dest" geoip.dat "$GH/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" "" 100000 || return 1
    ensure_stock_geo "$dest" geosite.dat "$GH/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" "" 100000 || return 1
    ensure_stock_geo "$dest" geoip_IR.dat "$GH/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat" "" 50000 || true
    ensure_stock_geo "$dest" geosite_IR.dat "$GH/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat" "" 50000 || true
    ensure_stock_geo "$dest" geoip_RU.dat "$GH/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat" "$RAW/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat" 50000 || true
    ensure_stock_geo "$dest" geosite_RU.dat "$GH/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" "$RAW/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" 50000 || true
    ensure_stock_geo "$dest" geoip_ROSCOM.dat "$GH/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat" "$CDN/hydraponique/roscomvpn-geoip/release/geoip.dat" 50000 || true
    ensure_stock_geo "$dest" geosite_ROSCOM.dat "$GH/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat" "$CDN/hydraponique/roscomvpn-geosite/release/geosite.dat" 50000 || true
    echo "Placing runetfreedom NEXT TO ROSCOM as geoip_RUNET.dat / geosite_RUNET.dat ..."
    download_one_geo "$dest" geoip_RUNET.dat "$RAW/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat" "$GH/runetfreedom/russia-v2ray-rules-dat/raw/release/geoip.dat" 50000 || return 1
    download_one_geo "$dest" geosite_RUNET.dat "$RAW/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat" "$GH/runetfreedom/russia-v2ray-rules-dat/raw/release/geosite.dat" 50000 || return 1
}

normalize_dns_choice() {
    local c
    c=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$c" in
        1|default|none) echo 1 ;;
        2|cloudflare|cf|doh-cloudflare) echo 2 ;;
        3|google|doh-google) echo 3 ;;
        4|quad9|q9|doh-quad9) echo 4 ;;
        5|self|selfhosted|adguard|agh) echo 5 ;;
        6|custom|own) echo 6 ;;
        *) echo "" ;;
    esac
}
has_global_ipv6() { ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; }
resolve_doh_for_hosts() {
    python3 - "$1" <<'PY'
import socket, sys, urllib.parse
raw = (sys.argv[1] or "").strip()
p = urllib.parse.urlparse(raw)
if p.scheme != "https" or not p.hostname:
    raise SystemExit(1)
host = p.hostname
try:
    infos = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
except Exception:
    raise SystemExit(1)
ip = infos[0][4][0] if infos else ""
if not ip:
    raise SystemExit(1)
print(host); print(ip); print(raw)
PY
}
choose_xray_dns() {
    local ans mapped tty doh_url resolved host ip
    DNS_CHOICE=""; CUSTOM_DOH_URL=""; CUSTOM_DOH_HOST=""; CUSTOM_DOH_IP=""
    tty="/dev/tty"; [[ -t 0 && -r /dev/tty ]] || tty=""
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Настройка DNS в X-UI:'
        echo '  1) Оставить по умолчанию'
        echo '  2) DoH Cloudflare'
        echo '  3) DoH Google'
        echo '  4) DoH Quad9'
        echo '  5) Использовать self-hosted DoH'
        echo '  6) Свой DoH'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Выбор [1-6]: '
        if [[ -n "$tty" ]]; then read -r ans <"$tty" || ans=""; else read -r ans || ans=""; fi
        mapped=$(normalize_dns_choice "$ans")
        [[ -n "$mapped" ]] || continue
        if [[ "$mapped" == "5" && "${DEPLOY_AGH:-}" != "1" ]]; then
            choose_adguard
            [[ "${DEPLOY_AGH}" == "1" ]] || continue
        fi
        if [[ "$mapped" == "6" ]]; then
            echo -en 'DoH URL: '
            if [[ -n "$tty" ]]; then read -r doh_url <"$tty" || doh_url=""; else read -r doh_url || doh_url=""; fi
            resolved=$(resolve_doh_for_hosts "$doh_url" 2>/dev/null || true)
            [[ -n "$resolved" ]] || continue
            host=$(printf '%s\n' "$resolved" | sed -n '1p')
            ip=$(printf '%s\n' "$resolved" | sed -n '2p')
            CUSTOM_DOH_URL=$(printf '%s\n' "$resolved" | sed -n '3p')
            CUSTOM_DOH_HOST="$host"; CUSTOM_DOH_IP="$ip"
        fi
        DNS_CHOICE="$mapped"; break
    done
    echo
}
apply_xray_template() {
    [[ ! -f $XUIDB ]] && { msg_err "x-ui.db not found — cannot apply Xray template."; return 1; }
    local qstrat freedom_strat enable_he=0 dns_mode="${DNS_CHOICE:-1}"
    if [[ "$dns_mode" != "1" ]]; then
        if has_global_ipv6; then qstrat='UseIP'; freedom_strat='ForceIP'; enable_he=1
        else qstrat='UseIPv4'; freedom_strat='ForceIPv4'; fi
    fi
    [[ -z "${IP4:-}" ]] && get_server_ip
    x-ui stop >/dev/null 2>&1 || true; sleep 2; pkill -x x-ui >/dev/null 2>&1 || true; sleep 1
    python3 - "$XUIDB" "$dns_mode" "$qstrat" "$freedom_strat" "$enable_he" \
        "${domain:-}" "${IP4:-}" "${CUSTOM_DOH_URL:-}" "${CUSTOM_DOH_HOST:-}" "${CUSTOM_DOH_IP:-}" <<'PY'
import json, sqlite3, sys
db, choice, qstrat, freedom_strat, enable_he, domain, ip4, custom_url, custom_host, custom_ip = sys.argv[1:11]
GH = "https://github.com"; RAW = "https://raw.githubusercontent.com"
GEODATA = {"cron": "0 4 * * 0", "assets": [
    {"url": GH + "/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat", "file": "geoip.dat"},
    {"url": GH + "/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat", "file": "geosite.dat"},
    {"url": GH + "/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat", "file": "geoip_IR.dat"},
    {"url": GH + "/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat", "file": "geosite_IR.dat"},
    {"url": GH + "/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat", "file": "geoip_RU.dat"},
    {"url": GH + "/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat", "file": "geosite_RU.dat"},
    {"url": GH + "/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat", "file": "geoip_ROSCOM.dat"},
    {"url": GH + "/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat", "file": "geosite_ROSCOM.dat"},
    {"url": RAW + "/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat", "file": "geoip_RUNET.dat"},
    {"url": RAW + "/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat", "file": "geosite_RUNET.dat"},
]}
DEFAULT = {"api": {"services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"], "tag": "api"},
    "inbounds": [{"listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"}],
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "outbounds": [{"protocol": "freedom", "tag": "direct", "settings": {"finalRules": [{"action": "block", "ip": ["geoip:private"]}, {"action": "allow"}]}},
                  {"protocol": "blackhole", "settings": {}, "tag": "blocked"}],
    "policy": {"levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
               "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}},
    "routing": {"domainStrategy": "AsIs", "rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
        {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"},
        {"outboundTag": "blocked", "protocol": ["bittorrent"], "type": "field"}]},
    "stats": {}, "geodata": GEODATA}
profiles = {"2": {"address": "https://cloudflare-dns.com/dns-query", "hosts": {"cloudflare-dns.com": "1.1.1.1", "one.one.one.one": "1.1.1.1"}},
            "3": {"address": "https://dns.google/dns-query", "hosts": {"dns.google": "8.8.8.8"}},
            "4": {"address": "https://dns.quad9.net/dns-query", "hosts": {"dns.quad9.net": "9.9.9.9"}}}
if choice == "5":
    if not domain or not ip4: raise SystemExit("self-hosted DoH needs panel domain and IP")
    profiles["5"] = {"address": "https://%s/dns-query" % domain, "hosts": {domain: ip4}}
if choice == "6":
    if not custom_url or not custom_host or not custom_ip: raise SystemExit("custom DoH missing host/ip")
    profiles["6"] = {"address": custom_url, "hosts": {custom_host: custom_ip}}
def unwrap(cfg):
    for _ in range(8):
        if not isinstance(cfg, dict): return cfg
        if "xraySetting" in cfg and not any(k in cfg for k in ("inbounds", "outbounds", "routing", "dns", "api")):
            inner = cfg["xraySetting"]
            cfg = json.loads(inner) if isinstance(inner, str) else inner if isinstance(inner, dict) else cfg
        else: return cfg
    return cfg
def set_direct_freedom_strategy(cfg, strategy, he):
    outs = cfg.get("outbounds")
    if not isinstance(outs, list): outs = []; cfg["outbounds"] = outs
    direct = None; tag_taken = False
    for ob in outs:
        if not isinstance(ob, dict): continue
        if str(ob.get("protocol", "")).lower() == "freedom" and ob.get("tag") == "direct":
            direct = ob; break
        if ob.get("tag") == "direct": tag_taken = True
    if direct is None:
        if tag_taken: raise SystemExit("tag 'direct' is taken by a non-freedom outbound")
        direct = {"protocol": "freedom", "tag": "direct", "settings": {}}; outs.append(direct)
    settings = direct.get("settings") if isinstance(direct.get("settings"), dict) else {}
    for k in ("domainStrategy", "targetStrategy"): settings.pop(k, None)
    direct["settings"] = settings; direct.pop("targetStrategy", None)
    stream = direct.get("streamSettings") if isinstance(direct.get("streamSettings"), dict) else {}
    sockopt = stream.get("sockopt") if isinstance(stream.get("sockopt"), dict) else {}
    if strategy == "AsIs": sockopt.pop("domainStrategy", None)
    else: sockopt["domainStrategy"] = strategy
    if he: sockopt["happyEyeballs"] = {"tryDelayMs": 250, "prioritizeIPv6": False, "interleave": 1, "maxConcurrentTry": 4}
    else: sockopt.pop("happyEyeballs", None)
    if sockopt: stream["sockopt"] = sockopt
    else: stream.pop("sockopt", None)
    if stream: direct["streamSettings"] = stream
    else: direct.pop("streamSettings", None)
con = sqlite3.connect(db, timeout=30); cur = con.cursor()
row = cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig' ORDER BY id DESC LIMIT 1").fetchone()
if row and row[0]:
    try:
        cfg = json.loads(row[0])
        if isinstance(cfg, str): cfg = json.loads(cfg)
    except Exception:
        cfg = json.loads(json.dumps(DEFAULT))
else:
    cfg = json.loads(json.dumps(DEFAULT))
cfg = unwrap(cfg)
if not isinstance(cfg, dict): cfg = json.loads(json.dumps(DEFAULT))
geo = cfg.get("geodata") if isinstance(cfg.get("geodata"), dict) else {}
assets = geo.get("assets") if isinstance(geo.get("assets"), list) else []
have = {a.get("file") for a in assets if isinstance(a, dict)}
for extra in GEODATA["assets"]:
    if extra["file"] not in have:
        assets.append(extra); have.add(extra["file"])
geo["assets"] = assets
cron = str(geo.get("cron") or "").strip()
geo["cron"] = cron if cron else "0 4 * * 0"
cfg["geodata"] = geo
if choice != "1":
    prof = profiles[choice]
    routing = cfg.get("routing") if isinstance(cfg.get("routing"), dict) else {}
    routing["domainStrategy"] = "IPIfNonMatch"; cfg["routing"] = routing
    set_direct_freedom_strategy(cfg, freedom_strat, enable_he == "1")
    cfg["dns"] = {"tag": "dns_inbound", "queryStrategy": qstrat, "disableCache": False, "disableFallback": True, "disableFallbackIfMatch": True,
        "useSystemHosts": False, "enableParallelQuery": False, "serveStale": False, "serveExpiredTTL": 0,
        "hosts": prof["hosts"],
        "servers": [{"address": prof["address"], "skipFallback": True, "queryStrategy": qstrat, "timeoutMs": 4000}]}
    cfg["fakedns"] = None
val = json.dumps(cfg, ensure_ascii=False, indent=2)
cur.execute("DELETE FROM settings WHERE key='xrayTemplateConfig'")
cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (val,))
con.commit()
try:
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)"); con.commit()
except Exception:
    pass
con.close()
print("ok")
PY
    rc=$?; x-ui start >/dev/null 2>&1 || true
    [[ $rc -eq 0 ]] || { msg_err "Failed to write xrayTemplateConfig (DNS/geodata)."; return 1; }
    msg_ok "Xray template saved (DNS ${dns_mode})."
}
apply_xray_dns() { apply_xray_template; }

choose_hy2_port() {
    local p tty
    tty="/dev/tty"
    [[ -t 0 && -r /dev/tty ]] || tty=""
    hy2_port=""
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Выберите порт для Hysteria2:'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Порт: '
        if [[ -n "$tty" ]]; then
            read -r p <"$tty" || p=""
        else
            read -r p || p=""
        fi
        p=$(echo "$p" | tr -d '[:space:]')
        if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            msg_err "Некорректный порт."
            continue
        fi
        case "$p" in
            80|443|46000|56000|56001|56003|7443|8443|9443|11443)
                msg_err "Порт ${p} занят."
                continue
                ;;
        esac
        if ss -Hlnu "sport = :$p" 2>/dev/null | grep -q .; then
            msg_err "Порт ${p} занят."
            continue
        fi
        hy2_port="$p"
        break
    done
    echo
}

choose_extra_inbounds() {
    local ans mapped tty tok confirm names has1 has_valid want_hy2 want_q want_c want_tproxy ok arch
    local -a toks
    DEPLOY_HY2="2"; DEPLOY_QWDTT=""; DEPLOY_CSQTT=""; DEPLOY_TPROXY=""
    hy2_port=""; webproxy_domain=""; TPROXY_SECRET=""
    arch=$(uname -m)
    tty="/dev/tty"; [[ -t 0 && -r /dev/tty ]] || tty=""
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Дополнительные инбаунды (перечислите цифры через запятую без пробелов):'
        echo '1 - Без дополнительных инбаундов'
        echo '2 - Hysteria2'
        echo '3 - qWDTT'
        echo '4 - CSQTT'
        echo '5 - Telegram WEB-proxy'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Выберите инбаунды:'
        if [[ -n "$tty" ]]; then read -r ans <"$tty" || ans=""; else read -r ans || ans=""; fi
        mapped=$(echo "$ans" | tr -d '[:space:]')
        [[ -n "$mapped" ]] || continue
        if [[ ",$mapped," == *",5,"* && "$arch" != "x86_64" ]]; then
            msg_err "Telegram WEB-proxy доступен только на x86_64 (MTProxy)."
            continue
        fi
        has1=0; has_valid=0; want_hy2=0; want_q=0; want_c=0; want_tproxy=0
        IFS=',' read -ra toks <<< "$mapped"
        for tok in "${toks[@]}"; do
            case "$tok" in
                1) has1=1 ;;
                2) has_valid=1; want_hy2=1 ;;
                3) has_valid=1; want_q=1 ;;
                4) has_valid=1; want_c=1 ;;
                5) has_valid=1; want_tproxy=1 ;;
            esac
        done
        # The confirmation menu is redrawn in full after Enter/invalid input.
        ok=""
        while true; do
            echo
            msg_inf '────────────────────────────────────────────────────────────────────────────────'
            if [[ "$has1" -eq 1 || "$has_valid" -eq 0 ]]; then
                msg_inf 'Вы не выбрали ни одного инбаунда, все верно?'
            else
                names=""
                [[ "$want_hy2" -eq 1 ]] && names+="Hysteria2, "
                [[ "$want_q" -eq 1 ]] && names+="qWDTT, "
                [[ "$want_c" -eq 1 ]] && names+="CSQTT, "
                [[ "$want_tproxy" -eq 1 ]] && names+="Telegram WEB-proxy, "
                names="${names%, }"
                msg_inf "Вы выбрали ${names}, все верно?"
            fi
            echo '1 - Да'
            echo '2 - Нет, выбрать снова'
            msg_inf '──────────────────────────────────────────────────────────────────────────────────────────'
            echo -en 'Выбор [1-2]: '
            if [[ -n "$tty" ]]; then read -r confirm <"$tty" || confirm=""; else read -r confirm || confirm=""; fi
            confirm=$(echo "$confirm" | tr -d '[:space:]')
            case "$confirm" in
                1) ok=1; break ;;
                2) ok=0; break ;;
                *) continue ;;
            esac
        done
        [[ "$ok" == "1" ]] || continue
        if [[ "$want_hy2" -eq 1 ]]; then DEPLOY_HY2="1"; else DEPLOY_HY2="2"; fi
        if [[ "$want_q" -eq 1 ]]; then DEPLOY_QWDTT="1"; else DEPLOY_QWDTT=""; fi
        if [[ "$want_c" -eq 1 ]]; then DEPLOY_CSQTT="1"; else DEPLOY_CSQTT=""; fi
        if [[ "$want_tproxy" -eq 1 ]]; then DEPLOY_TPROXY="1"; else DEPLOY_TPROXY=""; fi
        break
    done
    if [[ "$DEPLOY_HY2" == "1" ]]; then choose_hy2_port; else hy2_port=""; fi
    echo
}

domain_a_ok() {
    local d="$1"
    [[ -n "$d" && -n "${IP4:-}" ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        timeout 12 python3 - "$d" "$IP4" <<'PY'
import random, socket, struct, sys
name = sys.argv[1].strip().rstrip(".").lower()
want = sys.argv[2].strip()
def encode_name(n):
    out = bytearray()
    for label in n.split("."):
        lab = label.encode("ascii")
        if not (1 <= len(lab) <= 63):
            raise ValueError("bad label")
        out.append(len(lab)); out.extend(lab)
    out.append(0)
    return bytes(out)
def skip_name(data, off):
    while True:
        if off >= len(data):
            raise ValueError("trunc")
        l = data[off]
        if l == 0:
            return off + 1
        if l & 0xC0 == 0xC0:
            return off + 2
        if l & 0xC0:
            raise ValueError("edns")
        off += 1 + l
def udp_lookup(server, timeout=1.2):
    tid = random.randint(0, 65535)
    pkt = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + encode_name(name) + struct.pack(">HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(pkt, (server, 53))
        data, _ = sock.recvfrom(4096)
    finally:
        sock.close()
    if len(data) < 12:
        raise ValueError("short")
    rtid, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    if rtid != tid:
        raise ValueError("tid")
    rcode = flags & 0xF
    if rcode not in (0, 3):
        raise ValueError("rcode")
    off = 12
    for _ in range(qd):
        off = skip_name(data, off) + 4
    ips = []
    for _ in range(an):
        off = skip_name(data, off)
        typ, clas, ttl, rdlen = struct.unpack(">HHIH", data[off:off+10])
        off += 10
        rdata = data[off:off+rdlen]; off += rdlen
        if typ == 1 and rdlen == 4:
            ips.append(socket.inet_ntoa(rdata))
    return ips, rcode
answered = False
ips = set()
for srv in ("1.1.1.1", "8.8.8.8"):
    try:
        got, rcode = udp_lookup(srv)
        answered = True
        ips.update(got)
        if want in ips:
            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
if want in ips:
    raise SystemExit(0)
if answered:
    raise SystemExit(1)
try:
    ips.update(info[4][0] for info in socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM))
except Exception:
    pass
if want in ips:
    raise SystemExit(0)
try:
    import json, urllib.request
    for url in ("https://cloudflare-dns.com/dns-query?name=%s&type=A" % name, "https://dns.google/resolve?name=%s&type=A" % name):
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
            with urllib.request.urlopen(req, timeout=2.5) as resp:
                data = json.loads(resp.read().decode())
            for ans in data.get("Answer") or []:
                if ans.get("type") == 1 and ans.get("data"):
                    ips.add(str(ans["data"]).strip())
            if want in ips:
                raise SystemExit(0)
            if int(data.get("Status", 0)) in (0, 3):
                raise SystemExit(1)
        except SystemExit:
            raise
        except Exception:
            pass
except Exception:
    pass
raise SystemExit(0 if want in ips else 1)
PY
        return $?
    fi
    local a
    a=$(timeout 3 getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
    [[ "$a" == "$IP4" ]]
}
read_tty_line() {
    local tty="/dev/tty" ans=""
    [[ -t 0 && -r /dev/tty ]] || tty=""
    # Readline (-e) keeps pasted text and terminal wrapping in sync.  The long
    # description is printed on its own line, so only the short marker wraps.
    if [[ -n "$tty" ]]; then
        IFS= read -e -r -p '> ' ans <"$tty" || ans=""
    else
        printf '> ' >&2
        IFS= read -r ans || ans=""
    fi
    # Remove CR from CRLF pastes and trim only the edges.  Embedded whitespace
    # stays intact and is rejected by domain validation instead of being joined.
    ans=${ans//$'\r'/}
    ans="${ans#"${ans%%[!$' \t']*}"}"
    ans="${ans%"${ans##*[!$' \t']}"}"
    REPLY="$ans"
}
ui() { if [[ -t 0 && -w /dev/tty ]]; then printf '%s' "$1" >/dev/tty; else printf '%s' "$1" >&2; fi; }
ui_err() { if [[ -t 0 && -w /dev/tty ]]; then msg_err "$1" >/dev/tty; else msg_err "$1" >&2; fi; }
prompt_domain_a_record() {
    local prompt="$1" d
    DOMAIN_INPUT=""
    while true; do
        ui "$prompt"
        ui $'\n'
        read_tty_line
        d=$(printf '%s' "$REPLY" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        [[ -n "$d" ]] || continue
        if [[ ! "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            ui_err "Некорректный домен: ${d}"
            continue
        fi
        if ! domain_a_ok "$d"; then
            ui_err "A-запись ${d} не указывает на ${IP4}."
            continue
        fi
        DOMAIN_INPUT="$d"
        return 0
    done
}
choose_webproxy_domain() {
    [[ "${DEPLOY_TPROXY}" == "1" ]] || return 0
    [[ -n "${IP4:-}" ]] || get_server_ip
    local d p; webproxy_domain=""
    while true; do
        printf -v p 'Домен для Telegram WEB-proxy (создайте A-запись на IP "%s"): ' "$IP4"
        prompt_domain_a_record "$p"
        d="$DOMAIN_INPUT"
        if [[ "$d" == "$domain" || "$d" == "$reality_domain" ]]; then
            ui_err "Домен WEB-proxy должен отличаться от домена панели и Reality."
            continue
        fi
        webproxy_domain="$d"; break
    done
    echo
}
install_tproxy_site() {
    [[ "${DEPLOY_TPROXY}" == "1" ]] || return 0
    local idx site_id url tries=0
    mkdir -p /var/www/html

    # Panel, Reality and Telegram WEB-proxy use the same cover directory.
    while [[ ! -s /var/www/html/index.html ]] && (( tries < 8 )); do
        tries=$((tries + 1)); idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
        site_id=$(printf "site-%02d" "$idx")
        url="${GITHUB_RAW}/assets/fake-sites/${site_id}/index.html"
        curl -fsSL "$url" -o /var/www/html/index.html || rm -f /var/www/html/index.html
    done
    if [[ ! -s /var/www/html/index.html ]]; then printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"><title></title></head><body></body></html>' > /var/www/html/index.html; fi
    [[ -s /var/www/html/index.html ]] || { msg_err "Не удалось создать /var/www/html/index.html"; return 1; }
    rm -rf /var/www/tproxy
    chown -R www-data:www-data /var/www/html 2>/dev/null || true
    chmod 644 /var/www/html/index.html
    msg_ok "WEB-proxy uses shared camouflage from /var/www/html."
}
insert_tproxy_inbound() {
    [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" ]] || return 0
    [[ ! -f $XUIDB ]] && { msg_err "x-ui.db not found — cannot add Telegram WEB-proxy inbound."; return 1; }
    local flag secret cert key _ipwho
    secret=$(openssl rand -hex 16 | tr '[:upper:]' '[:lower:]')
    [[ ${#secret} -eq 32 ]] || { msg_err "Failed to generate WEB-proxy secret."; return 1; }
    TPROXY_SECRET="$secret"
    flag="${EMOJI_FLAG:-}"
    if [[ -z "$flag" ]]; then
        _ipwho='http'; _ipwho="${_ipwho}s://ipwho.is/"
        flag=$(LC_ALL=en_US.UTF-8 curl -s --max-time 10 "$_ipwho" | jq -r '.flag.emoji' 2>/dev/null)
        [[ -z "$flag" || "$flag" == "null" ]] && flag="🌐"
    fi
    cert="/root/cert/${webproxy_domain}/fullchain.pem"
    key="/root/cert/${webproxy_domain}/privkey.pem"
    python3 - "$XUIDB" "$webproxy_domain" "$secret" "$cert" "$key" "$flag" <<'PY'
import json, sqlite3, sys
db, hostname, secret, cert, key, flag = sys.argv[1:7]
remark = ("%s web-proxy" % flag).strip()
settings = {"clients": [], "port": 11443, "hostname": hostname, "secret": secret, "siteSource": "dir", "siteDir": "/var/www/html", "siteUpstream": "", "carrierMode": "https", "certFile": cert, "keyFile": key, "externalTLS": False, "behindCover": False, "routeThroughXray": False, "outboundTag": "", "routeXrayPort": 0}
stream = {"security": "none"}
sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False}
tag = "inbound-tproxy"
con = sqlite3.connect(db, timeout=30)
cur = con.cursor()
row = cur.execute("SELECT id FROM inbounds WHERE tag=? LIMIT 1", (tag,)).fetchone()
if row:
    con.close(); print("exists"); raise SystemExit(0)
cur.execute("INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (1, 0, 0, 0, remark, 1, 0, "127.0.0.1", 11443, "tproxy", json.dumps(settings, ensure_ascii=False), json.dumps(stream, ensure_ascii=False), tag, json.dumps(sniffing, ensure_ascii=False)))
con.commit(); con.close(); print("ok")
PY
    [[ $? -eq 0 ]] || { msg_err "Failed to insert Telegram WEB-proxy inbound."; return 1; }
    umask 077
    cat > /root/.lucx-tg-web-proxy-info <<EOF
TG_WEB_PROXY_DOMAIN=${webproxy_domain}
TG_WEB_PROXY_SECRET=${secret}
EOF
    chmod 600 /root/.lucx-tg-web-proxy-info
    msg_ok "Inbound Telegram WEB-proxy created (SNI ${webproxy_domain} → 127.0.0.1:11443)."
}

get_installed_tproxy_domain() {
    local found=""
    if [[ -f "$XUIDB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        found=$(python3 - "$XUIDB" <<'PY_TG_DOMAIN'
import json, sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1], timeout=10)
    row = con.execute("SELECT settings FROM inbounds WHERE tag='inbound-tproxy' LIMIT 1").fetchone()
    con.close()
    if row:
        value = json.loads(row[0] or "{}")
        print(value.get("hostname", ""))
except Exception:
    pass
PY_TG_DOMAIN
)
    fi
    if [[ -z "$found" && -f /root/.lucx-tg-web-proxy-info ]]; then
        found=$(sed -n 's/^TG_WEB_PROXY_DOMAIN=//p' /root/.lucx-tg-web-proxy-info | head -n1)
    fi
    if [[ -z "$found" && -f /etc/nginx/stream-enabled/stream.conf ]]; then
        found=$(awk '$2 == "tproxy;" {print $1; exit}' /etc/nginx/stream-enabled/stream.conf)
    fi
    printf '%s' "$found"
}

discover_panel_domains() {
    local stream=/etc/nginx/stream-enabled/stream.conf
    [[ -f "$stream" ]] || return 0
    [[ -n "${domain:-}" ]] || domain=$(awk '$2 == "www;" {print $1; exit}' "$stream")
    [[ -n "${reality_domain:-}" ]] || reality_domain=$(awk '$2 == "xray;" && $1 != "default" {print $1; exit}' "$stream")
}

patch_tproxy_nginx() {
    local action="$1" proxy_domain="$2"
    local stream=/etc/nginx/stream-enabled/stream.conf redirect=/etc/nginx/sites-available/80.conf
    [[ -f "$stream" && -f "$redirect" ]] || { msg_err "Конфигурация nginx панели не найдена."; return 1; }
    local stream_bak redirect_bak
    stream_bak=$(mktemp); redirect_bak=$(mktemp)
    cp -a "$stream" "$stream_bak"; cp -a "$redirect" "$redirect_bak"
    if ! python3 - "$action" "$proxy_domain" "$stream" "$redirect" <<'PY_TG_NGINX'
import re, sys
from pathlib import Path
action, domain, stream_path, redirect_path = sys.argv[1:5]
stream_file, redirect_file = Path(stream_path), Path(redirect_path)
stream = stream_file.read_text()
lines = stream.splitlines()
# Remove any previous LucX tproxy map entry and one-line upstream first.
lines = [line for line in lines if not re.match(r'^\s*\S+\s+tproxy;\s*$', line)]
lines = [line for line in lines if not re.match(r'^\s*upstream\s+tproxy\s*\{[^}]*\}\s*$', line)]
if action == 'install':
    inserted = False
    for i, line in enumerate(lines):
        if re.match(r'^\s*default\s+', line):
            indent = re.match(r'^(\s*)', line).group(1)
            lines.insert(i, f'{indent}{domain}    tproxy;')
            inserted = True
            break
    if not inserted:
        raise SystemExit('SNI map default entry not found')
    for i, line in enumerate(lines):
        if re.match(r'^\s*server\s*\{\s*$', line):
            lines.insert(i, f'upstream tproxy {{ server 127.0.0.1:11443; }}')
            lines.insert(i + 1, '')
            break
    else:
        raise SystemExit('stream server block not found')
stream_file.write_text('\n'.join(lines) + '\n')

redirect = redirect_file.read_text().splitlines()
changed = False
for i, line in enumerate(redirect):
    m = re.match(r'^(\s*server_name\s+)(.*?)(;\s*)$', line)
    if not m:
        continue
    names = [x for x in m.group(2).split() if x != domain]
    if action == 'install' and domain not in names:
        names.append(domain)
    redirect[i] = m.group(1) + ' '.join(names) + m.group(3)
    changed = True
    break
if not changed:
    raise SystemExit('redirect server_name not found')
redirect_file.write_text('\n'.join(redirect) + '\n')
PY_TG_NGINX
    then
        cp -a "$stream_bak" "$stream"; cp -a "$redirect_bak" "$redirect"
        rm -f "$stream_bak" "$redirect_bak"
        msg_err "Не удалось изменить конфигурацию nginx."
        return 1
    fi
    if ! nginx -t >/dev/null 2>&1; then
        cp -a "$stream_bak" "$stream"; cp -a "$redirect_bak" "$redirect"
        rm -f "$stream_bak" "$redirect_bak"
        nginx -t
        msg_err "Проверка nginx не пройдена; исходные файлы восстановлены."
        return 1
    fi
    rm -f "$stream_bak" "$redirect_bak"
    systemctl reload nginx
}

remove_tproxy_inbound() {
    [[ -f "$XUIDB" ]] || return 0
    python3 - "$XUIDB" <<'PY_TG_DELETE'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=30)
cur = con.cursor()
ids = [r[0] for r in cur.execute("SELECT id FROM inbounds WHERE tag='inbound-tproxy'")]
def columns(table):
    try:
        return {r[1] for r in cur.execute('PRAGMA table_info("%s")' % table)}
    except Exception:
        return set()
for table in ('client_traffics', 'hosts'):
    cols = columns(table)
    if 'inbound_id' in cols:
        for inbound_id in ids:
            cur.execute('DELETE FROM "%s" WHERE inbound_id=?' % table, (inbound_id,))
for inbound_id in ids:
    cur.execute("DELETE FROM inbounds WHERE id=?", (inbound_id,))
con.commit()
try:
    cur.execute('PRAGMA wal_checkpoint(TRUNCATE)')
except Exception:
    pass
con.close()
PY_TG_DELETE
}

force_remove_tproxy_nginx() {
    local proxy_domain="$1"
    python3 - "$proxy_domain" <<'PY_TG_FORCE_NGINX'
import re, sys
from pathlib import Path

domain = sys.argv[1]
stream_path = Path("/etc/nginx/stream-enabled/stream.conf")
redirect_path = Path("/etc/nginx/sites-available/80.conf")

if stream_path.is_file():
    lines = stream_path.read_text().splitlines()
    lines = [
        line for line in lines
        if not re.match(r'^\s*' + re.escape(domain) + r'\s+tproxy;\s*$', line)
        and not re.match(r'^\s*upstream\s+tproxy\s*\{[^}]*\}\s*$', line)
    ]
    stream_path.write_text("\n".join(lines) + "\n")

if redirect_path.is_file():
    lines = redirect_path.read_text().splitlines()
    for index, line in enumerate(lines):
        match = re.match(r'^(\s*server_name\s+)(.*?)(;\s*)$', line)
        if match:
            names = [name for name in match.group(2).split() if name != domain]
            lines[index] = match.group(1) + " ".join(names) + match.group(3)
            break
    redirect_path.write_text("\n".join(lines) + "\n")
PY_TG_FORCE_NGINX
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || return 1
        systemctl reload nginx || return 1
    fi
}

ensure_tproxy_certificate() {
    local d="$1" was_active=0 rc=0
    if [[ -s "/etc/letsencrypt/live/${d}/fullchain.pem" && -s "/etc/letsencrypt/live/${d}/privkey.pem" ]]; then
        msg_inf "Using existing certificate for ${d}."
    else
        systemctl is-active --quiet nginx && was_active=1
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone --non-interactive --agree-tos             --register-unsafely-without-email -d "$d" || rc=$?
        [[ $was_active -eq 1 ]] && systemctl start nginx 2>/dev/null || true
        [[ $rc -eq 0 ]] || return "$rc"
    fi
    [[ -s "/etc/letsencrypt/live/${d}/fullchain.pem" && -s "/etc/letsencrypt/live/${d}/privkey.pem" ]] || return 1
    ensure_panel_cert_links "$d"
}

uninstall_tg_web_proxy() {
    local proxy_domain had_proxy=0 nginx_cleanup_failed=0
    proxy_domain=$(get_installed_tproxy_domain)
    if [[ -n "$proxy_domain" ]] || [[ -d /var/www/tproxy ]]; then had_proxy=1; fi
    if [[ -n "$proxy_domain" ]]; then
        if ! patch_tproxy_nginx uninstall "$proxy_domain"; then
            msg_inf "Обычная очистка nginx не удалась; выполняется резервная очистка."
            force_remove_tproxy_nginx "$proxy_domain" || nginx_cleanup_failed=1
        fi
    fi
    remove_tproxy_inbound || return 1
    rm -rf /var/www/tproxy
    rm -f /root/.lucx-tg-web-proxy-info
    # Keep the domain certificate and its /root/cert links for future use.
    if [[ $had_proxy -eq 1 ]] && systemctl is-active --quiet x-ui; then
        x-ui restart >/dev/null 2>&1 || systemctl restart x-ui
    fi
    if [[ $nginx_cleanup_failed -eq 1 ]]; then
        msg_inf "Telegram WEB-proxy удалён, но конфигурацию nginx нужно проверить вручную."
        return 1
    fi
    msg_ok "Telegram WEB-proxy удалён."
}

install_tg_web_proxy() {
    local previous_domain arch
    arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] || { msg_err "Telegram WEB-proxy доступен только на x86_64 (MTProxy)."; return 1; }
    [[ -f "$XUIDB" ]] || { msg_err "x-ui.db не найден — сначала установите панель."; return 1; }
    for cmd in nginx certbot sqlite3 python3 curl jq openssl; do
        command -v "$cmd" >/dev/null 2>&1 || { msg_err "Не найдена обязательная команда: ${cmd}"; return 1; }
    done
    previous_domain=$(get_installed_tproxy_domain)
    if [[ -n "$previous_domain" ]] || [[ -d /var/www/tproxy ]]; then
        msg_inf "Telegram WEB-proxy уже установлен — выполняется чистая переустановка."
        uninstall_tg_web_proxy || return 1
    fi
    get_server_ip
    [[ "$IP4" =~ $IP4_REGEX ]] || { msg_err "Не удалось определить IPv4 сервера."; return 1; }
    discover_panel_domains
    DEPLOY_TPROXY="1"
    choose_webproxy_domain
    ensure_tproxy_certificate "$webproxy_domain" || { msg_err "Не удалось получить сертификат для ${webproxy_domain}."; return 1; }
    install_tproxy_site || return 1
    patch_tproxy_nginx install "$webproxy_domain" || return 1
    if ! insert_tproxy_inbound; then
        patch_tproxy_nginx uninstall "$webproxy_domain" 2>/dev/null || true
        rm -rf /var/www/tproxy /root/.lucx-tg-web-proxy-info
        return 1
    fi
    install_shareonly_client_sync || {
        remove_tproxy_inbound 2>/dev/null || true
        patch_tproxy_nginx uninstall "$webproxy_domain" 2>/dev/null || true
        rm -rf /var/www/tproxy /root/.lucx-tg-web-proxy-info
        return 1
    }
    if systemctl is-active --quiet x-ui; then
        x-ui restart >/dev/null 2>&1 || systemctl restart x-ui
    else
        systemctl start x-ui
    fi
    echo
    msg_inf '────────────────────────────────────────────────────────────────────────────────'
    local H='http'; H="${H}s://"
    echo "Telegram WEB-proxy: ${H}t.me/webproxy?server=${webproxy_domain}&secret=${TPROXY_SECRET}"
    msg_inf '────────────────────────────────────────────────────────────────────────────────'
}

insert_hy2_inbound() {
    [[ "${DEPLOY_HY2}" == "1" && -n "${hy2_port}" ]] || return 0
    [[ ! -f $XUIDB ]] && { msg_err "x-ui.db not found — cannot add Hysteria2 inbound."; return 1; }
    local salamander_pass gid_col gid_hy2 flag
    salamander_pass=$(gen_random_string 16 | tr '[:upper:]' '[:lower:]')
    flag="${EMOJI_FLAG:-}"
    if [[ -z "$flag" ]]; then
        flag=$(LC_ALL=en_US.UTF-8 curl -s --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji' 2>/dev/null)
        [[ -z "$flag" || "$flag" == "null" ]] && flag="🌐"
    fi
    gid_col=""
    gid_hy2=""
    if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw "group_id"; then
        gid_col='"group_id",'
        gid_hy2="'$(gen_group_id)',"
    fi
    python3 - "$XUIDB" "$hy2_port" "$salamander_pass" "$domain" "$gid_col" "$gid_hy2" "$flag" <<'PY'
import json, sqlite3, sys
db, port, salamander, domain, gid_col, gid_hy2, flag = sys.argv[1:8]
port = int(port)
remark = ("%s hy2" % flag).strip()
cert = "/root/cert/%s/fullchain.pem" % domain
key = "/root/cert/%s/privkey.pem" % domain
settings = {"version": 2, "clients": []}
stream = {
    "network": "hysteria",
    "security": "tls",
    "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60},
    "tlsSettings": {
        "serverName": domain,
        "minVersion": "1.2",
        "maxVersion": "1.3",
        "cipherSuites": "",
        "rejectUnknownSni": False,
        "disableSystemRoot": False,
        "enableSessionResumption": False,
        "alpn": ["h3"],
        "certificates": [{
            "useFile": True,
            "certificateFile": cert,
            "keyFile": key,
            "certificate": [],
            "key": [],
            "ocspStapling": 0,
            "oneTimeLoading": False,
            "usage": "encipherment",
            "buildChain": False
        }],
        "settings": {
            "fingerprint": "firefox",
            "echConfigList": "",
            "pinnedPeerCertSha256": [],
            "verifyPeerCertByName": ""
        }
    },
    "finalmask": {
        "tcp": [],
        "udp": [{"type": "salamander", "settings": {"password": salamander}}]
    }
}
sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False}
tag = "inbound-%s" % port
con = sqlite3.connect(db, timeout=30)
cur = con.cursor()
row = cur.execute("SELECT id FROM inbounds WHERE protocol='hysteria' OR tag=? LIMIT 1", (tag,)).fetchone()
if row:
    con.close()
    print("exists")
    raise SystemExit(0)
cur.execute(
    "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (1, 0, 0, 0, remark, 1, 0, "", port, "hysteria",
     json.dumps(settings, ensure_ascii=False),
     json.dumps(stream, ensure_ascii=False),
     tag, json.dumps(sniffing, ensure_ascii=False)),
)
inbound_id = cur.lastrowid
cols = '"inbound_id",%s"sort_order","remark","address","port","security","fingerprint","alpn"' % gid_col
vals = [inbound_id]
if gid_col:
    vals.append(gid_hy2.strip("',"))
vals.extend([0, "hy2", domain, port, "same", "", "[]"])
placeholders = ",".join(["?"] * len(vals))
cur.execute("INSERT INTO hosts (%s) VALUES (%s)" % (cols, placeholders), vals)
con.commit()
con.close()
print("ok", port)
PY
    [[ $? -eq 0 ]] || { msg_err "Failed to insert Hysteria2 inbound."; return 1; }
    msg_ok "Inbound Hysteria2 created (UDP ${hy2_port})."
}

install_shareonly_client_sync() {
    [[ ! -f $XUIDB ]] && return 0
    sqlite3 "$XUIDB" <<'SQL'
UPDATE inbounds
SET settings = json_set(
  CASE WHEN json_valid(settings) THEN settings ELSE '{}' END,
  '$.clients',
  CASE WHEN json_type(json_extract(settings, '$.clients')) = 'array'
       THEN json_extract(settings, '$.clients')
       ELSE json('[]') END
)
WHERE protocol IN ('qwdtt','csqtt','tproxy');
DROP TRIGGER IF EXISTS lucx_shareonly_clients_ins;
DROP TRIGGER IF EXISTS lucx_shareonly_clients_del;
CREATE TRIGGER lucx_shareonly_clients_ins
AFTER INSERT ON client_inbounds
WHEN EXISTS (SELECT 1 FROM inbounds WHERE id = NEW.inbound_id AND protocol IN ('qwdtt','csqtt','tproxy'))
BEGIN
  UPDATE inbounds SET settings = json_insert(
    json_set(
      settings,
      '$.clients',
      CASE WHEN json_type(json_extract(settings, '$.clients')) = 'array'
           THEN json_extract(settings, '$.clients')
           ELSE json('[]') END
    ),
    '$.clients[#]',
    json_object(
      'email', COALESCE((SELECT email FROM clients WHERE id = NEW.client_id), ''),
      'enable', json('true')
    )
  )
  WHERE id = NEW.inbound_id
    AND COALESCE((SELECT email FROM clients WHERE id = NEW.client_id), '') != ''
    AND NOT EXISTS (
      SELECT 1 FROM json_each(
        CASE WHEN json_type(json_extract(inbounds.settings, '$.clients')) = 'array'
             THEN json_extract(inbounds.settings, '$.clients')
             ELSE json('[]') END
      )
      WHERE json_extract(value, '$.email') = (SELECT email FROM clients WHERE id = NEW.client_id)
    );
END;
CREATE TRIGGER lucx_shareonly_clients_del
AFTER DELETE ON client_inbounds
WHEN EXISTS (SELECT 1 FROM inbounds WHERE id = OLD.inbound_id AND protocol IN ('qwdtt','csqtt','tproxy'))
BEGIN
  UPDATE inbounds SET settings = json_set(
    settings,
    '$.clients',
    (
      SELECT json_group_array(json(value))
      FROM json_each(
        CASE WHEN json_type(json_extract(inbounds.settings, '$.clients')) = 'array'
             THEN json_extract(inbounds.settings, '$.clients')
             ELSE json('[]') END
      )
      WHERE json_extract(value, '$.email') != (SELECT email FROM clients WHERE id = OLD.client_id)
         OR (SELECT email FROM clients WHERE id = OLD.client_id) IS NULL
    )
  )
  WHERE id = OLD.inbound_id;
END;
SQL
}

insert_extra_inbound() {
    [[ "${DEPLOY_QWDTT}" == "1" || "${DEPLOY_CSQTT}" == "1" || "${DEPLOY_TPROXY}" == "1" ]] || return 0
    [[ ! -f $XUIDB ]] && { msg_err "x-ui.db not found — cannot add extra inbound."; return 1; }
    [[ -z "${IP4:-}" ]] && get_server_ip
    local proto remark port listen_addr sub_host pass web_pass
    _insert_one_extra() {
        proto="$1"; remark="$2"; port="$3"; listen_addr="$4"; sub_host="$5"
        pass=$(gen_random_string 16)
        web_pass=$(gen_random_string 24)
        python3 - "$XUIDB" "$proto" "$remark" "$port" "$listen_addr" "$sub_host" "$pass" "$web_pass" <<'PY'
import json, sqlite3, sys
db, proto, remark, port, listen_addr, sub_host, password, web_pass = sys.argv[1:9]
port = int(port)
if proto == "qwdtt":
    settings = {
        "clients": [],
        "remark": remark,
        "enabled": True,
        "listenAddr": listen_addr,
        "wgPort": 56001,
        "password": password,
        "dns": "8.8.8.8",
        "configDir": "",
        "listenRaw": "0.0.0.0:56003",
        "listenDirect": "",
        "subHost": sub_host,
        "vkHashes": "",
        "clientPort": 9000,
        "workers": 16,
        "routeThroughXray": True,
        "outboundTag": ""
    }
else:
    settings = {
        "clients": [],
        "remark": remark,
        "enabled": True,
        "listenAddr": listen_addr,
        "password": password,
        "deviceId": "",
        "webPass": web_pass,
        "subHost": sub_host,
        "vkHashes": "",
        "configDir": "",
        "routeThroughXray": True,
        "outboundTag": ""
    }
stream = {"security": "none"}
sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False}
tag = "inbound-qwdtt" if proto == "qwdtt" else "inbound-csqtt"
con = sqlite3.connect(db, timeout=30)
cur = con.cursor()
row = cur.execute("SELECT id FROM inbounds WHERE protocol=? OR tag=? LIMIT 1", (proto, tag)).fetchone()
if row:
    con.close()
    print("exists")
    raise SystemExit(0)
cur.execute(
    "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (1, 0, 0, 0, remark, 1, 0, "", port, proto,
     json.dumps(settings, ensure_ascii=False),
     json.dumps(stream, ensure_ascii=False),
     tag, json.dumps(sniffing, ensure_ascii=False)),
)
con.commit()
con.close()
print("ok", proto, port)
PY
        [[ $? -eq 0 ]] || { msg_err "Failed to insert ${remark} inbound."; return 1; }
        msg_ok "Inbound ${remark} created (port ${port})."
    }
    if [[ "${DEPLOY_QWDTT}" == "1" ]]; then
        _insert_one_extra qwdtt qWDTT 56000 '0.0.0.0:56000' "${IP4}:56000" || return 1
    fi
    if [[ "${DEPLOY_CSQTT}" == "1" ]]; then
        _insert_one_extra csqtt CSQTT 46000 '0.0.0.0:46000' "${IP4}" || return 1
    fi
    insert_tproxy_inbound || return 1
    install_shareonly_client_sync
}

choose_adguard() {
    local ans mapped tty
    DEPLOY_AGH=""
    tty="/dev/tty"
    [[ -t 0 && -r /dev/tty ]] || tty=""
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Развернуть self-hosted DNS-over-HTTPS (DoH) на домене панели?'
        echo '  1) Да'
        echo '  2) Нет'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Выбор [1-2]: '
        if [[ -n "$tty" ]]; then read -r ans <"$tty" || ans=""; else read -r ans || ans=""; fi
        mapped=$(echo "$ans" | tr -d '[:space:]')
        case "$mapped" in
            1|2) DEPLOY_AGH="$mapped"; break ;;
        esac
    done
    echo
}
install_base_dependencies() {
    [[ "${BASE_DEPENDENCIES_READY}" == "1" ]] && return 0

    if ! command -v apt-get >/dev/null 2>&1; then
        msg_err "Для установки требуется Debian/Ubuntu с пакетным менеджером apt."
        return 1
    fi

    if ! apt-get update; then
        msg_err "Не удалось обновить список пакетов APT. Проверьте репозитории и сетевое подключение."
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl ipset iptables; then
        msg_err "Не удалось установить базовые зависимости: ca-certificates, curl, ipset, iptables."
        return 1
    fi

    for dependency in curl ipset iptables; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            msg_err "Зависимость ${dependency} не найдена после установки."
            return 1
        fi
    done

    BASE_DEPENDENCIES_READY="1"
}

choose_rkn_guard() {
    local ans mapped tty
    DEPLOY_RKN=""
    tty="/dev/tty"
    [[ -t 0 && -r /dev/tty ]] || tty=""
    while true; do
        echo
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        msg_inf 'Установить ли rkn-guard с защитой от сканеров подсетей?'
        echo '  1) Да (обновлять списки)'
        echo '  2) Да (обновлять списки и программу)'
        echo '  3) Нет'
        msg_inf '────────────────────────────────────────────────────────────────────────────────'
        echo -en 'Выбор [1-3]: '
        if [[ -n "$tty" ]]; then read -r ans <"$tty" || ans=""; else read -r ans || ans=""; fi
        mapped=$(echo "$ans" | tr -d '[:space:]')
        case "$mapped" in
            1) DEPLOY_RKN="1"; break ;;
            2) DEPLOY_RKN="2"; break ;;
            3) DEPLOY_RKN="3"; break ;;
        esac
    done
    echo
}

install_rkn_guard_auto_updates() {
    local update_mode="${1:-2}"
    local update_dir="/usr/local/lib/lucx-ui-pro"
    mkdir -p "$update_dir"

    cat > "${update_dir}/rkn-guard-list-update.sh" <<'RKN_LIST_UPDATE'
#!/usr/bin/env bash
set -euo pipefail
command -v rkn-guard >/dev/null 2>&1 || exit 0
exec rkn-guard update \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list
RKN_LIST_UPDATE

    if [[ "$update_mode" == "2" ]]; then
        cat > "${update_dir}/rkn-guard-self-update.sh" <<'RKN_SELF_UPDATE'
#!/usr/bin/env bash
set -euo pipefail
command -v rkn-guard >/dev/null 2>&1 || exit 0
latest=$(curl -fsSL --connect-timeout 10 --max-time 30 \
  https://api.github.com/repos/Flecksis/rkn-guard/releases/latest \
  | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
[[ "$latest" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
current=$(rkn-guard build-info 2>/dev/null | head -n1 || true)
[[ -n "$current" ]] || current=$(rkn-guard --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
if [[ "${current#v}" == "${latest#v}" ]]; then
  exit 0
fi
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL --connect-timeout 15 --max-time 180 \
  https://raw.githubusercontent.com/Flecksis/rkn-guard/master/app%20install.sh -o "$tmp"
bash "$tmp"
curl -fsSL --connect-timeout 15 --max-time 60 \
  https://raw.githubusercontent.com/Flecksis/rkn-guard/master/install.sh \
  -o /opt/rkn-guard-manager.sh
chmod 755 /opt/rkn-guard-manager.sh
printf '%s\n' '#!/usr/bin/env bash' 'exec /opt/rkn-guard-manager.sh "$@"' > /usr/local/bin/rkn
chmod 755 /usr/local/bin/rkn
RKN_SELF_UPDATE
        chmod 755 "${update_dir}/rkn-guard-self-update.sh"
    else
        systemctl disable --now rkn-guard-self-update.timer 2>/dev/null || true
        rm -f "${update_dir}/rkn-guard-self-update.sh" \
              /etc/systemd/system/rkn-guard-self-update.service \
              /etc/systemd/system/rkn-guard-self-update.timer
    fi
    chmod 755 "${update_dir}/rkn-guard-list-update.sh"

    cat > /etc/systemd/system/rkn-guard-list-update.service <<EOF
[Unit]
Description=Update rkn-guard IP block lists
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${update_dir}/rkn-guard-list-update.sh
EOF
    cat > /etc/systemd/system/rkn-guard-list-update.timer <<'EOF'
[Unit]
Description=Periodic rkn-guard IP list update

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    if [[ "$update_mode" == "2" ]]; then
        cat > /etc/systemd/system/rkn-guard-self-update.service <<EOF
[Unit]
Description=Update rkn-guard when a new release is available
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${update_dir}/rkn-guard-self-update.sh
EOF
        cat > /etc/systemd/system/rkn-guard-self-update.timer <<'EOF'
[Unit]
Description=Periodic rkn-guard release check

[Timer]
OnBootSec=30min
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable --now rkn-guard-list-update.timer
    if [[ "$update_mode" == "2" ]]; then
        systemctl enable --now rkn-guard-self-update.timer
    fi
}

install_rkn_guard() {
    local update_mode="${1:-2}"
    local installer
    install_base_dependencies || return 1
    if command -v rkn-guard >/dev/null 2>&1; then
        msg_inf "rkn-guard уже установлен — сначала выполняется полное удаление."
        uninstall_rkn_guard || return 1
    fi
    command -v curl >/dev/null 2>&1 || {
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates
    }
    installer=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 --max-time 180 \
        https://raw.githubusercontent.com/Flecksis/rkn-guard/master/install.sh -o "$installer"; then
        rm -f "$installer"
        msg_err "Не удалось скачать установщик rkn-guard."
        return 1
    fi
    if ! bash "$installer" install; then
        rm -f "$installer"
        msg_err "Установка rkn-guard завершилась с ошибкой."
        return 1
    fi
    rm -f "$installer"
    command -v rkn-guard >/dev/null 2>&1 || { msg_err "rkn-guard не найден после установки."; return 1; }
    install_rkn_guard_auto_updates "$update_mode" || return 1
    if [[ "$update_mode" == "1" ]]; then
        msg_ok "rkn-guard установлен; автообновление списков включено, автообновление программы отключено."
    else
        msg_ok "rkn-guard установлен; автообновление списков и программы включено."
    fi
}

cleanup_rkn_guard_fallback() {
    local cmd parent set_name file tmp

    # Remove live jumps/chains even when the rkn-guard binary is missing or
    # its own uninstall command fails.
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        for parent in INPUT ufw-before-input ufw6-before-input; do
            while "$cmd" -C "$parent" -j SCANNERS-BLOCK >/dev/null 2>&1; do
                "$cmd" -D "$parent" -j SCANNERS-BLOCK >/dev/null 2>&1 || break
            done
        done
        "$cmd" -F SCANNERS-BLOCK >/dev/null 2>&1 || true
        "$cmd" -X SCANNERS-BLOCK >/dev/null 2>&1 || true
    done

    if command -v ipset >/dev/null 2>&1; then
        for set_name in SCANNERS-BLOCK-V4 SCANNERS-BLOCK-V6; do
            ipset flush "$set_name" >/dev/null 2>&1 || true
            ipset destroy "$set_name" >/dev/null 2>&1 || true
        done
    fi

    # Remove the complete managed block, including rules inside it that do not
    # repeat the SCANNERS-BLOCK name on every line.
    for file in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        [[ -f "$file" ]] || continue
        tmp="${file}.lucx-clean.$$"
        awk '
            /# SCANNERS-BLOCK chain - managed by antiscan/ { skip=1; next }
            skip && /# END SCANNERS-BLOCK/ { skip=0; next }
            !skip { print }
        ' "$file" > "$tmp" && cat "$tmp" > "$file"
        rm -f "$tmp"
    done
}

uninstall_rkn_guard() {
    # Stop only LucX-owned update timers first so they cannot start while the
    # upstream uninstaller is running. Let rkn-guard remove its own antiscan
    # units before the fallback cleanup below.
    systemctl disable --now \
        rkn-guard-list-update.timer rkn-guard-self-update.timer \
        2>/dev/null || true
    systemctl stop \
        rkn-guard-list-update.service rkn-guard-self-update.service \
        2>/dev/null || true
    rm -f /etc/systemd/system/rkn-guard-list-update.service \
          /etc/systemd/system/rkn-guard-list-update.timer \
          /etc/systemd/system/rkn-guard-self-update.service \
          /etc/systemd/system/rkn-guard-self-update.timer
    rm -f /usr/local/lib/lucx-ui-pro/rkn-guard-list-update.sh \
          /usr/local/lib/lucx-ui-pro/rkn-guard-self-update.sh

    if command -v rkn-guard >/dev/null 2>&1; then
        rkn-guard uninstall --yes --remove-logs >/dev/null 2>&1 || true
    fi

    # Idempotent fallback: remove anything left by an interrupted, older or
    # partially failed upstream uninstall without printing harmless errors.
    systemctl disable --now \
        antiscan-aggregate.timer antiscan-aggregate.service \
        antiscan-move-rules.service antiscan-ipset-restore.service \
        2>/dev/null || true
    systemctl stop \
        antiscan-aggregate.service antiscan-move-rules.service \
        antiscan-ipset-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/antiscan-aggregate.timer \
          /etc/systemd/system/antiscan-aggregate.service \
          /etc/systemd/system/antiscan-ipset-restore.service \
          /etc/systemd/system/antiscan-move-rules.service
    cleanup_rkn_guard_fallback
    rm -f /usr/local/bin/rkn-guard /usr/local/bin/rkn \
          /usr/local/bin/antiscan-aggregate-logs.sh \
          /opt/rkn-guard-manager.sh /opt/rkn-guard-manual.list \
          /etc/ipset.conf /etc/iptables/ipsets \
          /etc/rsyslog.d/10-iptables-scanners.conf \
          /etc/logrotate.d/iptables-scanners \
          /var/log/iptables-scanners-*
    # This directory also contains the Clash subscription renderer.
    # Remove it only when no other component still uses it.
    rmdir /usr/local/lib/lucx-ui-pro 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    systemctl restart rsyslog 2>/dev/null || true
    msg_ok "rkn-guard removed."
}

uninstall_adguard() {
    local quiet="${1:-}"
    local had_adguard=0
    [[ -d /opt/AdGuardHome || -f /etc/nginx/snippets/adguard.conf || -f /root/.lucx-adguard-info ]] && had_adguard=1
    systemctl stop AdGuardHome 2>/dev/null || true
    [[ -x /opt/AdGuardHome/AdGuardHome ]] && /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
    rm -rf /opt/AdGuardHome /etc/nginx/snippets/adguard.conf /root/.lucx-adguard-info
    for f in /etc/nginx/sites-available/*; do
        [[ -f "$f" ]] || continue
        sed -i '\|snippets/adguard.conf|d' "$f"
    done
    if command -v nginx >/dev/null 2>&1 && ! nginx -t &>/dev/null; then
        [[ "$quiet" == "quiet" ]] || msg_err "AdGuard Home удалён, но конфигурация nginx не прошла проверку."
        return 1
    fi
    command -v nginx >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    if [[ "$quiet" != "quiet" && $had_adguard -eq 1 ]]; then
        msg_ok "AdGuard Home removed."
    fi
}
install_adguard() {
    local AGH_DIR=/opt/AdGuardHome AGH_YAML=/opt/AdGuardHome/AdGuardHome.yaml
    local AGH_SNIPPET=/etc/nginx/snippets/adguard.conf AGH_SERVICE=AdGuardHome
    local vhost agh_path agh_web_port agh_dns_port agh_arch agh_user agh_pass agh_hash
    local new_credentials=0 agh_up=0 GH p
    GH='https://github.com'
    [[ -f $XUIDB ]] || { msg_err "x-ui.db not found — install the panel first."; return 1; }
    command -v sqlite3 >/dev/null || apt-get install -y -q sqlite3
    if [[ -z "${domain:-}" ]]; then
        local web_cert
        web_cert=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || true)
        if [[ "$web_cert" =~ /root/cert/([^/]+)/ || "$web_cert" =~ /etc/letsencrypt/live/([^/]+)/ ]]; then domain="${BASH_REMATCH[1]}"; fi
    fi
    if [[ -z "${domain:-}" ]]; then
        for f in /etc/nginx/sites-available/*; do
            [[ -f "$f" ]] || continue
            case "$(basename "$f")" in 80.conf|00-maps.conf) continue;; esac
            if grep -q 'listen 7443' "$f" 2>/dev/null; then domain=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';'); break; fi
        done
    fi
    [[ -n "${domain:-}" ]] || { msg_err "Could not determine panel domain."; return 1; }
    [[ -z "${IP4:-}" ]] && get_server_ip
    vhost="/etc/nginx/sites-available/${domain}"
    if [[ ! -f "$vhost" ]] || ! grep -q 'listen 7443' "$vhost"; then
        vhost=""
        for f in /etc/nginx/sites-available/*; do
            [[ -f "$f" ]] || continue
            grep -q 'listen 7443' "$f" 2>/dev/null && { vhost="$f"; break; }
        done
    fi
    [[ -n "$vhost" ]] || { msg_err "Panel vhost (listen 7443) not found."; return 1; }
    agh_path=""
    [[ -f "$AGH_SNIPPET" ]] && agh_path=$(grep -oP 'location /\Kadg-[a-zA-Z0-9]+' "$AGH_SNIPPET" | head -1 || true)
    [[ -n "$agh_path" ]] || agh_path="adg-$(gen_random_string 12)"
    agh_web_port=""
    [[ -f "$AGH_YAML" ]] && agh_web_port=$(grep -oP '^\s*address:\s*127\.0\.0\.1:\K\d+' "$AGH_YAML" | head -1 || true)
    if [[ -z "$agh_web_port" ]]; then
        while true; do p=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 )); ss -Hln "sport = :$p" 2>/dev/null | grep -q . || { agh_web_port="$p"; break; }; done
    fi
    while true; do p=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 )); ss -Hln "sport = :$p" 2>/dev/null | grep -q . || { agh_dns_port="$p"; break; }; done
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl tar ca-certificates apache2-utils
    case "$(uname -m)" in x86_64) agh_arch="amd64";; aarch64) agh_arch="arm64";; armv7l) agh_arch="armv7";; *) msg_err "Unsupported architecture"; return 1;; esac
    if [[ ! -x "${AGH_DIR}/AdGuardHome" ]]; then
        mkdir -p /opt
        curl -fsSL "${GH}/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" | tar -xz -C /opt
        [[ -x "${AGH_DIR}/AdGuardHome" ]] || { msg_err "AdGuard Home download failed."; return 1; }
    fi
    agh_user="admin"; agh_pass=""
    if [[ -f "$AGH_YAML" ]]; then new_credentials=0
    else
        new_credentials=1
        agh_pass=$(gen_random_string 20)
        agh_hash=$(htpasswd -nbB x "$agh_pass" | cut -d: -f2)
        [[ "$agh_hash" == \$2* ]] || { msg_err "bcrypt hash generation failed."; return 1; }
        systemctl stop "$AGH_SERVICE" 2>/dev/null || true
        mkdir -p "$AGH_DIR"
        cat > "$AGH_YAML" <<EOF
http:
  address: 127.0.0.1:${agh_web_port}
users:
  - name: ${agh_user}
    password: ${agh_hash}
auth_attempts: 5
block_auth_min: 15
theme: auto
dns:
  bind_hosts:
    - 127.0.0.1
  port: ${agh_dns_port}
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - https://dns.quad9.net/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
    - 9.9.9.9
  trusted_proxies:
    - 127.0.0.0/8
tls:
  enabled: false
  allow_unencrypted_doh: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
schema_version: 28
EOF
        chmod 600 "$AGH_YAML"
        umask 077
        cat > /root/.lucx-adguard-info <<INFO
AGH_USER=${agh_user}
AGH_PASS=${agh_pass}
AGH_PATH=${agh_path}
AGH_DOMAIN=${domain}
AGH_IP=${IP4}
INFO
        chmod 600 /root/.lucx-adguard-info
    fi
    if [[ -f /root/.lucx-adguard-info ]]; then
        grep -q '^AGH_PATH=' /root/.lucx-adguard-info 2>/dev/null || echo "AGH_PATH=${agh_path}" >> /root/.lucx-adguard-info
        grep -q '^AGH_DOMAIN=' /root/.lucx-adguard-info 2>/dev/null || echo "AGH_DOMAIN=${domain}" >> /root/.lucx-adguard-info
        grep -q '^AGH_IP=' /root/.lucx-adguard-info 2>/dev/null || echo "AGH_IP=${IP4}" >> /root/.lucx-adguard-info
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${AGH_SERVICE}\.service"; then systemctl restart "$AGH_SERVICE"
    else "${AGH_DIR}/AdGuardHome" -s install; fi
    for _ in $(seq 1 20); do curl -fso /dev/null "http://127.0.0.1:${agh_web_port}/" && { agh_up=1; break; }; sleep 0.5; done
    [[ $agh_up -eq 1 ]] || { msg_err "AdGuard Home did not start"; return 1; }
    mkdir -p /etc/nginx/snippets
    cat > "$AGH_SNIPPET" <<EOF
    location /dns-query {
        proxy_pass http://127.0.0.1:${agh_web_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        access_log off;
    }
    location /${agh_path}/ {
        proxy_pass http://127.0.0.1:${agh_web_port}/;
        proxy_redirect / /${agh_path}/;
        proxy_cookie_path / /${agh_path}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location = /${agh_path} { return 302 /${agh_path}/; }
EOF
    if ! grep -q 'snippets/adguard.conf' "$vhost"; then
        if grep -q 'include /etc/nginx/snippets/includes.conf;' "$vhost"; then
            sed -i 's|^\(\s*\)include /etc/nginx/snippets/includes.conf;|\1include /etc/nginx/snippets/adguard.conf;\n\1include /etc/nginx/snippets/includes.conf;|' "$vhost"
        else
            sed -i '$ s|^}$|    include /etc/nginx/snippets/adguard.conf;\n}|' "$vhost"
        fi
    fi
    if ! nginx -t; then
        msg_err "AdGuard Home настроен, но проверка nginx завершилась с ошибкой."
        return 1
    fi
    systemctl reload nginx || {
        msg_err "Конфигурация nginx корректна, но nginx не удалось перезагрузить."
        return 1
    }
    AGH_PATH="$agh_path"; AGH_USER="$agh_user"; AGH_PASS="$agh_pass"
    msg_ok "AdGuard Home installed."
}
print_adguard_results() {
    local agh_path agh_user agh_pass agh_domain agh_ip H
    H='https://'
    [[ -f /etc/nginx/snippets/adguard.conf ]] || return 0
    agh_domain="${domain:-}"; agh_ip="${IP4:-}"; agh_path=""; agh_user="admin"; agh_pass=""
    if [[ -f /root/.lucx-adguard-info ]]; then
        . /root/.lucx-adguard-info
        agh_path="${AGH_PATH:-$agh_path}"; agh_user="${AGH_USER:-$agh_user}"
        agh_pass="${AGH_PASS:-}"; agh_domain="${AGH_DOMAIN:-$agh_domain}"; agh_ip="${AGH_IP:-$agh_ip}"
    fi
    [[ -z "$agh_path" ]] && agh_path=$(grep -oP 'location /\Kadg-[a-zA-Z0-9]+' /etc/nginx/snippets/adguard.conf | head -1 || true)
    [[ -n "$agh_domain" ]] || return 0
    echo
    msg_inf '────────────────────────────────────────────────────────────────────────────────'
    echo -e "AdGuard Home:  ${H}${agh_domain}/${agh_path}/\n"
    echo -e "Login:         ${agh_user}\n"
    if [[ -n "$agh_pass" ]]; then echo -e "Password:      ${agh_pass}\n"
    else echo -e "Password:      (already set / bcrypt in AdGuardHome.yaml)\n"; fi
    echo -e "DoH:           ${H}${agh_domain}/dns-query\n"
    echo -e "Hosts:         ${agh_domain} ${agh_ip}\n"
    msg_inf '────────────────────────────────────────────────────────────────────────────────'
}
# ─────────────────────────────────────────────────────────────────────────────
# AMNEZIAWG FULL UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
uninstall_awg_kernel_full() {
    local script="/usr/local/x-ui/bin/install-awg-module.sh"

    # Stop our guard first so it cannot race with the official AWG uninstaller
    # while the installer/sysctl file is being removed.
    systemctl stop lucx-awg-sysctl-guard.path lucx-awg-sysctl-guard.service 2>/dev/null || true

    if [[ -x "$script" ]]; then
        msg_inf "Removing AmneziaWG kernel module and tools..."
        bash "$script" --uninstall >/dev/null 2>&1 || true
    else
        # Fallback for partially broken/removed panel installations.
        rmmod amneziawg >/dev/null 2>&1 || true
        if command -v dkms >/dev/null 2>&1; then
            while read -r ver; do
                [[ -n "$ver" ]] || continue
                dkms remove -m amneziawg -v "$ver" --all >/dev/null 2>&1 || true
            done < <(dkms status amneziawg 2>/dev/null | grep -oP 'amneziawg[,/] ?\K[^,]+' | sort -u || true)
        fi
        rm -rf /usr/src/amneziawg-* /var/lib/dkms/amneziawg
        rm -f /usr/bin/awg /usr/bin/awg-quick \
              /usr/local/bin/awg /usr/local/bin/awg-quick \
              /usr/sbin/awg /usr/sbin/awg-quick \
              /usr/local/sbin/awg /usr/local/sbin/awg-quick \
              /etc/modules-load.d/amneziawg.conf \
              /etc/sysctl.d/99-awg-performance.conf \
              /etc/x-ui/.awg-module-version /etc/x-ui/.awg-reboot-needed
        update-initramfs -u -k all >/dev/null 2>&1 || update-initramfs -u >/dev/null 2>&1 || true
    fi

    # The AWG installer owns this file, but a previous/partial install may
    # leave it behind after the official uninstaller failed.
    rm -f /etc/sysctl.d/99-awg-performance.conf
    systemctl daemon-reload 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
remove_lucx_cron_jobs() {
    local cert='0 1 * * * certbot renew --non-interactive --pre-hook "systemctl stop nginx" --deploy-hook "x-ui restart" --post-hook "systemctl start nginx" >/dev/null 2>&1'
    local cron_file
    command -v crontab >/dev/null 2>&1 || return 0
    cron_file=$(mktemp) || return 1
    crontab -l > "$cron_file" 2>/dev/null || true
    # Remove the old RUNET job at any schedule, preserving comments and other jobs.
    awk -v cert="$cert" '$0 != cert && (/^[[:space:]]*#/ || $0 !~ /\/usr\/local\/x-ui\/update-geodata\.sh([[:space:];]|$)/)' "$cron_file" > "${cron_file}.new"
    if ! crontab "${cron_file}.new"; then
        rm -f "$cron_file" "${cron_file}.new"
        return 1
    fi
    rm -f "$cron_file" "${cron_file}.new"
}

uninstall_xui() {
    local dir="$PREINSTALL_STATE_DIR" cert
    [[ -f "$dir/owned-by-lucx-ui-pro" && -f "$dir/existing-paths" ]] || {
        msg_err "Ownership snapshot missing. Cannot safely uninstall an older or foreign installation."
        return 1
    }
    msg_inf "Начинаю удаление LucX-UI..."
    msg_inf "Останавливаю службы панели..."
    systemctl stop x-ui nginx mtr-backend AdGuardHome lucx-apply-qdisc lucx-qdisc-sync.path lucx-awg-sysctl-guard.path 2>/dev/null || true
    if [[ -f "$dir/rkn-installed" ]]; then
        msg_inf "Удаляю rkn-guard..."
        uninstall_rkn_guard || msg_err "Не удалось полностью удалить rkn-guard."
    fi
    if [[ -f "$dir/adguard-installed" ]]; then
        msg_inf "Удаляю AdGuard Home..."
        uninstall_adguard || msg_err "Не удалось полностью удалить AdGuard Home."
    fi
    if [[ ! -f "$dir/awg-preexisting" ]]; then
        msg_inf "Удаляю AmneziaWG..."
        uninstall_awg_kernel_full
    fi
    msg_inf "Отключаю службы и удаляю задания cron..."
    systemctl disable x-ui mtr-backend AdGuardHome lucx-apply-qdisc lucx-qdisc-sync.path lucx-awg-sysctl-guard.path 2>/dev/null || true
    # Remove only the two jobs installed by setup_cron.
    remove_lucx_cron_jobs
    msg_inf "Удаляю файлы панели и созданные ею конфигурации..."
    systemctl stop lucx-clash-sub.service 2>/dev/null || true
    systemctl disable lucx-clash-sub.service 2>/dev/null || true
    rm -rf /etc/x-ui /usr/local/x-ui /usr/local/lib/3x-ui-pro /usr/local/lib/lucx-ui-pro \
           /opt/AdGuardHome /root/.lucx-adguard-info /root/.lucx-tg-web-proxy-info \
           /var/www/tproxy
    if [[ -f "$dir/release-archive" ]]; then
        local archive_path
        read -r archive_path < "$dir/release-archive" || true
        [[ "$archive_path" =~ ^/usr/local/x-ui-linux-(amd64|arm64|armv5|armv6|armv7|386|s390x|ppc64le|riscv64)\.tar\.gz$ ]] && \
            rm -f -- "$archive_path"
    fi
    rm -f /usr/bin/x-ui /usr/bin/x-ui-temp /etc/systemd/system/x-ui.service \
          /etc/systemd/system/mtr-backend.service /etc/systemd/system/AdGuardHome.service \
          /etc/systemd/system/lucx-clash-sub.service \
          /etc/systemd/system/lucx-apply-qdisc.service \
          /etc/systemd/system/lucx-qdisc-sync.service /etc/systemd/system/lucx-qdisc-sync.path \
          /usr/local/sbin/lucx-apply-qdisc /usr/local/sbin/lucx-awg-sysctl-guard \
          /etc/systemd/system/lucx-awg-sysctl-guard.service \
          /etc/systemd/system/lucx-awg-sysctl-guard.path \
          /etc/sysctl.d/99-lucx-ui-forwarding.conf /etc/sysctl.d/99-awg-performance.conf
    # Keep all issued certificates and renewal data for reinstall or other sites.
    # Remove only nginx files generated by this installer. Existing files are
    # then restored from the baseline archive.
    if [[ -f "$dir/domains" ]]; then
        while IFS= read -r cert; do
            [[ "$cert" =~ ^[A-Za-z0-9.-]+$ ]] || continue
            rm -f "/etc/nginx/sites-enabled/$cert" "/etc/nginx/sites-available/$cert"
        done < "$dir/domains"
    fi
    rm -f /etc/nginx/sites-enabled/80.conf /etc/nginx/sites-available/80.conf \
          /etc/nginx/sites-enabled/00-clash-maps.conf /etc/nginx/sites-available/00-clash-maps.conf \
          /etc/nginx/stream-enabled/stream.conf /etc/nginx/snippets/includes.conf \
          /etc/nginx/snippets/adguard.conf /var/www/subpage/clash.yaml.tpl
    systemctl daemon-reload 2>/dev/null || true
    msg_inf "Сертификаты сайтов и данные их продления сохраняются."
    restore_preinstall_state || return 1
    rm -rf -- "$dir"
    msg_ok "Удаление LucX-UI завершено."
}

if [[ ${UNINSTALL} == *"y"* ]]; then
    uninstall_xui || exit 1
    exit 0
fi

# A normal repeated full installation must start from the same clean state as
# an explicit "-uninstall y". Component-only maintenance commands are excluded.
is_full_install_request() {
    [[ "${ADGUARD_ONLY}" != "y" &&
       "${ADGUARD_UNINSTALL}" != "y" &&
       "${RKN_GUARD_ONLY}" != "y" &&
       "${RKN_GUARD_UNINSTALL}" != "y" &&
       "${TG_WEB_PROXY_ONLY}" != "y" &&
       "${TG_WEB_PROXY_UNINSTALL}" != "y" ]]
}

existing_lucx_install_detected() {
    [[ -e /etc/x-ui || -e /usr/local/x-ui || -e /usr/bin/x-ui ||
       -e /etc/systemd/system/x-ui.service || -e "$PREINSTALL_STATE_DIR" ]]
}

confirm_reinstall() {
    local answer
    while true; do
        echo
        msg_err "Ваша панель и все её данные будут безвозвратно удалены. Продолжить?"
        echo '  1) Да'
        echo '  2) Нет'
        if [[ -t 0 && -r /dev/tty ]]; then read -r -p 'Выбор [1-2]: ' answer </dev/tty || return 1
        else read -r -p 'Выбор [1-2]: ' answer || return 1; fi
        case "${answer// /}" in
            1) return 0 ;;
            2) return 1 ;;
            *) continue ;;
        esac
    done
}

if is_full_install_request && existing_lucx_install_detected; then
    [[ -f "$PREINSTALL_STATE_DIR/owned-by-lucx-ui-pro" ]] || {
        msg_err "Existing panel has no ownership snapshot; refusing to remove it automatically."
        exit 1
    }
    if ! confirm_reinstall; then
        msg_inf "Повторная установка отменена. Панель не изменена."
        exit 0
    fi
    uninstall_xui || exit 1
    msg_ok "Previous installation completely removed."
fi

# This is the first installation question. It is intentionally after the full
# cleanup of any previous LucX installation, and before domain/DNS/RKN questions.
choose_amneziawg

# ─────────────────────────────────────────────────────────────────────────────
# GET SERVER IP
# ─────────────────────────────────────────────────────────────────────────────
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"

get_server_ip() {
    local pub
    IP4=$(timeout 3 ip -4 route get 8.8.8.8 2>/dev/null | grep -Po -- 'src \K\S*' | head -1)
    pub=$(curl -4 -fsS --connect-timeout 3 --max-time 8 ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    if [[ $pub =~ $IP4_REGEX ]]; then
        IP4="$pub"
    fi
    IP6=""
    if timeout 1 ip -6 route show default >/dev/null 2>&1; then
        IP6=$(timeout 2 ip -6 route get 2620:fe::fe 2>/dev/null | grep -Po -- 'src \K\S*' | head -1)
        [[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -6 -fsS --connect-timeout 2 --max-time 5 ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    fi
}

# Early IP fetch for auto-domain
IP4=$(timeout 3 ip -4 route get 8.8.8.8 2>/dev/null | grep -Po -- 'src \K\S*' | head -1)
pub=$(curl -4 -fsS --connect-timeout 3 --max-time 8 ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
if [[ $pub =~ $IP4_REGEX ]]; then IP4="$pub"; fi


# ─────────────────────────────────────────────────────────────────────────────
# DOMAIN VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_domains() {
    get_server_ip
    if [[ ! $IP4 =~ $IP4_REGEX ]]; then
        msg_err "Не удалось определить IPv4 сервера."
        exit 1
    fi
    local d p
    domain=$(echo "${domain}" | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    if [[ -n "$domain" ]] && ! domain_a_ok "$domain"; then
        msg_err "A-запись ${domain} не указывает на ${IP4}."
        domain=""
    fi
    if [[ -z "$domain" ]]; then
        printf -v p 'Домен панели (создайте A-запись на IP "%s"): ' "$IP4"
        prompt_domain_a_record "$p"
        domain="$DOMAIN_INPUT"
    fi
    SubDomain=$(echo "$domain"   | sed 's/^[^ ]* \|\..*//g')
    MainDomain=$(echo "$domain"  | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] && MainDomain=${domain}
    reality_domain=$(echo "${reality_domain}" | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    if [[ -n "$reality_domain" ]] && ! domain_a_ok "$reality_domain"; then
        msg_err "A-запись ${reality_domain} не указывает на ${IP4}."
        reality_domain=""
    fi
    if [[ -z "$reality_domain" ]]; then
        while true; do
            printf -v p 'Домен для Reality (создайте A-запись на IP "%s"): ' "$IP4"
            prompt_domain_a_record "$p"
            d="$DOMAIN_INPUT"
            if [[ "$d" == "$domain" ]]; then
                ui_err "Домен панели и Reality должны отличаться."
                continue
            fi
            reality_domain="$d"
            break
        done
    fi
    RealitySubDomain=$(echo "$reality_domain" | sed 's/^[^ ]* \|\..*//g')
    RealityMainDomain=$(echo "$reality_domain" | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] && RealityMainDomain=${reality_domain}
    if [[ "$domain" == "$reality_domain" ]]; then
        msg_err "Panel domain and REALITY domain must be different! Got: ${domain}"
        exit 1
    fi
}
# First interactive questions: panel + Reality (before AdGuard / DNS / extra-inbounds).
if [[ "${ADGUARD_ONLY}" != "y" && "${ADGUARD_UNINSTALL}" != "y" && "${RKN_GUARD_ONLY}" != "y" && "${RKN_GUARD_UNINSTALL}" != "y" && "${TG_WEB_PROXY_ONLY}" != "y" && "${TG_WEB_PROXY_UNINSTALL}" != "y" ]]; then
    validate_domains
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    ufw disable 2>/dev/null || true

    if [[ ${INSTALL} == *"y"* ]]; then
        local version nginx_repair=0
        version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
        [[ "$version" == "20" || "$version" == "22" ]] && echo "System: Ubuntu $version"

        $Pak -y update
        $Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin cron iproute2

        # A previous interrupted/buggy install can leave the nginx package
        # installed while /etc/nginx (or nginx.conf) was deleted. In that case
        # apt install reports success but does not recreate the missing conffile.
        [[ -f /etc/nginx/nginx.conf ]] || nginx_repair=1
        [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] || nginx_repair=1
        if [[ "$nginx_repair" == "1" ]]; then
            msg_inf "Repairing nginx package/configuration from a partial previous install..."
            DEBIAN_FRONTEND=noninteractive $Pak -y install --reinstall nginx-common nginx-full || return 1
        fi

        install -d -m 0755 /etc/nginx /etc/nginx/sites-available /etc/nginx/sites-enabled \
            /etc/nginx/stream-enabled /etc/nginx/snippets
        if [[ ! -f /etc/nginx/nginx.conf ]]; then
            msg_err "nginx.conf is still missing after package repair."
            return 1
        fi

        systemctl daemon-reload
        systemctl reset-failed nginx 2>/dev/null || true
        systemctl enable nginx >/dev/null 2>&1 || return 1
        # Do not start nginx here. configure_nginx() must first write and test
        # the complete panel configuration, then it starts the service.
    fi

    apt-get install -yqq --no-install-recommends ca-certificates
}

# ─────────────────────────────────────────────────────────────────────────────
# SSL CERTIFICATES
# ─────────────────────────────────────────────────────────────────────────────
ensure_panel_cert_links() {
    local d="$1" name link
    mkdir -p "/root/cert/${d}"
    chmod 755 /root/cert /root/cert/* 2>/dev/null || true
    for name in fullchain.pem privkey.pem; do
        link="/root/cert/${d}/${name}"
        if [[ -L "$link" && ! -e "$link" ]]; then rm -f -- "$link"; fi
        if [[ ! -e "$link" && ! -L "$link" ]]; then
            ln -s "/etc/letsencrypt/live/${d}/${name}" "$link" || return 1
        fi
    done
}

ensure_site_certificate() {
    local d="$1"
    if [[ -s "/etc/letsencrypt/live/${d}/fullchain.pem" && -s "/etc/letsencrypt/live/${d}/privkey.pem" ]]; then
        msg_inf "Using existing certificate for ${d}."
        return 0
    fi
    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$d" || return 1
    [[ -s "/etc/letsencrypt/live/${d}/fullchain.pem" && -s "/etc/letsencrypt/live/${d}/privkey.pem" ]]
}

get_ssl_certs() {
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true

    if [[ ${AUTODOMAIN} == *"y"* ]]; then
        local resolve_ok=true extra_d=()
        [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" ]] && extra_d+=("$webproxy_domain")
        for d in "$domain" "$reality_domain" "${extra_d[@]}"; do
            if ! domain_a_ok "$d"; then
                msg_err "Auto-domain $d does not resolve to $IP4. Fix DNS and retry."
                resolve_ok=false
            fi
        done
        [[ $resolve_ok == false ]] && exit 1
    fi

    if ! ensure_site_certificate "$domain"; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    if ! ensure_site_certificate "$reality_domain"; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$reality_domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    ensure_panel_cert_links "$domain" || return 1

    if [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" ]]; then
        if ! ensure_site_certificate "$webproxy_domain"; then
            systemctl start nginx >/dev/null 2>&1
            msg_err "$webproxy_domain SSL could not be generated! Check Domain/IP." && exit 1
        fi
        ensure_panel_cert_links "$webproxy_domain" || return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE NGINX
# ─────────────────────────────────────────────────────────────────────────────
configure_nginx() {
    install -d -m 0755 /etc/nginx /etc/nginx/sites-available /etc/nginx/sites-enabled \
        /etc/nginx/stream-enabled /etc/nginx/snippets
    [[ -f /etc/nginx/nginx.conf ]] || {
        msg_err "nginx.conf not found. Package repair failed before nginx configuration."
        return 1
    }

    # nginx >= 1.25.1 deprecates "listen ... http2" in favor of "http2 on;";
    # older versions (Debian 12 / Ubuntu 24.04) don't know the new directive
    local ngx_ver http2_listen="" http2_on=""
    ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
        http2_on="http2 on;"
    else
        http2_listen=" http2"
    fi

    # SNI-based stream: reality → 8443, domain → 7443, webproxy → 11443
    local tproxy_sni="" tproxy_up=""
    if [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" ]]; then
        tproxy_sni="    ${webproxy_domain}    tproxy;"
        tproxy_up="upstream tproxy { server 127.0.0.1:11443; }"
    fi
    cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}    xray;
    ${domain}            www;
${tproxy_sni}
    default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }
${tproxy_up}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF

    grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
        || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
    grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* \
        || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
    grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* \
        || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
    sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

    # HTTP → HTTPS redirect
    local wp_http_names=""
    [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" ]] && wp_http_names=" ${webproxy_domain}"
    cat > /etc/nginx/sites-available/80.conf <<EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain}${wp_http_names};
    return 301 https://\$host\$request_uri;
}
EOF

    # Shared proxy locations for xray inbounds (included by both vhosts)
    cat > /etc/nginx/snippets/includes.conf <<EOF
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    # One-level client URL: Clash/Mihomo gets YAML, other clients get panel output.
    location ~ ^/${sub_path}/(?<clash_sub_id>[^/]+)\$ {
        if (\$hack = 1) { return 404; }
        if (\$serve_clash_yaml = 1) { rewrite ^ /__lucx_clash?sub_id=\$clash_sub_id last; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /${sub_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

    #Subscription (json)
    location /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size      16k;
        grpc_socket_keepalive on;
        grpc_read_timeout     1h;
        grpc_send_timeout     1h;
        grpc_set_header Connection        "";
        grpc_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port  \$server_port;
        grpc_set_header Host              \$host;
        grpc_set_header X-Forwarded-Host  \$host;
    }

    #Xray generic proxy (WS / gRPC by port+path)
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }

    location / { try_files \$uri \$uri/ =404; }
EOF

    # The maps belong in http context, shared by both TLS virtual hosts.
    cat > /etc/nginx/sites-available/00-clash-maps.conf <<'EOF'
map $http_user_agent $lucx_clash_ua {
    ~*(clash|mihomo|stash|surfboard) 1;
    default 0;
}
map "$lucx_clash_ua:$arg_provider" $serve_clash_yaml {
    "1:" 1;
    default 0;
}
EOF
    ln -sf /etc/nginx/sites-available/00-clash-maps.conf /etc/nginx/sites-enabled/00-clash-maps.conf

    # Main domain vhost (TLS termination at 7443, proxy_protocol)
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl${http2_listen} proxy_protocol;
    listen [::]:7443 ssl${http2_listen} proxy_protocol;
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    # This vhost listens on 7443 behind the SNI stream (public port 443). Without
    # this, nginx bakes :7443 into redirect Location headers (return/error_page),
    # so browsers get sent to an unreachable port. Keep redirects relative.
    absolute_redirect off;
    # Larger h2 preread window improves single-stream upload throughput
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${domain}\$)            { return 444; }
    if (\$scheme ~* https)                          { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    location = /__lucx_clash {
        internal;
        proxy_pass http://127.0.0.1:${clash_port}/api/clash\$is_args\$args;
        proxy_set_header Host \$host;
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Reality domain vhost (plain TLS at 9443, no proxy_protocol)
    cat > "/etc/nginx/sites-available/${reality_domain}" <<EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl${http2_listen};
    listen [::]:9443 ssl${http2_listen};
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${reality_domain}\$)            { return 444; }
    if (\$scheme ~* https)                                  { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                        { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }

    location = /__lucx_clash {
        internal;
        proxy_pass http://127.0.0.1:${clash_port}/api/clash\$is_args\$args;
        proxy_set_header Host \$host;
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Activate configs
    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
        ln -sf "/etc/nginx/sites-available/${domain}"          /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${reality_domain}"  /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/80.conf"            /etc/nginx/sites-enabled/
    else
        msg_err "${domain} nginx config not found!" && exit 1
    fi

    if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
        msg_err "nginx config check failed!" && exit 1
    fi

    systemctl start nginx
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PANEL (LucX-UI)
# ─────────────────────────────────────────────────────────────────────────────
_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)          echo 'amd64'  ;;
        i*86|x86)                  echo '386'    ;;
        armv8*|armv8|arm64|aarch64) echo 'arm64' ;;
        armv7*|armv7|arm)          echo 'armv7'  ;;
        armv6*|armv6)              echo 'armv6'  ;;
        armv5*|armv5)              echo 'armv5'  ;;
        s390x)                     echo 's390x'  ;;
        *) echo "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

# Same checksum asset and 404 compatibility rule as the upstream installer.
verify_release_checksum() {
    local url="$1" file="$2" sums="${2}.sha256" code expected actual
    code=$(curl -sL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 \
        -o "$sums" -w '%{http_code}' "${url}.sha256") || {
        rm -f "$sums" "$file"; return 1;
    }
    if [[ "$code" == "404" ]]; then
        rm -f "$sums"
        msg_inf "This older release has no checksum; verification unavailable."
        return 0
    fi
    [[ "$code" == "200" ]] || { rm -f "$sums" "$file"; return 1; }
    expected=$(awk 'NR == 1 {print $1}' "$sums")
    actual=$(sha256sum "$file" | awk '{print $1}')
    rm -f "$sums"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
        rm -f "$file"
        msg_err "Release checksum mismatch."
        return 1
    fi
    msg_ok "Release checksum verified: $actual"
}

_panel_initial_config() {
    /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
    /usr/local/x-ui/x-ui migrate
}

install_panel() {
    local tag_version dest script_ref GH RAW release_url
    GH='https://github.com'
    RAW='https://raw.githubusercontent.com'
    apt-get update && apt-get install -y -q wget curl tar tzdata
    cd /usr/local/
    if [[ -n "$PANEL_VERSION" && "$PANEL_VERSION" != "latest" ]]; then
        tag_version="${PANEL_VERSION#v}"
        tag_version="v${tag_version}"
        if ! curl -fsILo /dev/null "$GH/AlexeyLCP/lucx-ui/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz" \
           && ! curl -4 -fsILo /dev/null "$GH/AlexeyLCP/lucx-ui/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz"; then
            echo "LucX-UI release ${tag_version} not found." && exit 1
        fi
    else
        tag_version=$(curl -Ls "https://api.github.com/repos/AlexeyLCP/lucx-ui/releases/latest" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/AlexeyLCP/lucx-ui/releases/latest" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        fi
        if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
            echo "Failed to fetch LucX-UI version." && exit 1
        fi
    fi
    echo "Installing LucX-UI ${tag_version} ..."
    release_url="$GH/AlexeyLCP/lucx-ui/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz"
    printf '%s\n' "/usr/local/x-ui-linux-$(_arch).tar.gz" > "$PREINSTALL_STATE_DIR/release-archive"
    wget -O "/usr/local/x-ui-linux-$(_arch).tar.gz" "$release_url" || return 1
    [[ -s "/usr/local/x-ui-linux-$(_arch).tar.gz" ]] || return 1
    verify_release_checksum "$release_url" "/usr/local/x-ui-linux-$(_arch).tar.gz" || return 1
    script_ref="${tag_version}"
    [[ "$script_ref" == "dev-latest" ]] && script_ref="main"
    wget -O /usr/bin/x-ui-temp "$RAW/AlexeyLCP/lucx-ui/${script_ref}/x-ui.sh"
    if [[ $? -ne 0 ]]; then wget -O /usr/bin/x-ui-temp "$RAW/AlexeyLCP/lucx-ui/main/x-ui.sh"; fi
    [[ $? -ne 0 ]] && echo "Failed to download x-ui.sh" && exit 1
    [[ -d /usr/local/x-ui/ ]] && systemctl stop x-ui 2>/dev/null; rm -rf /usr/local/x-ui/
    tar zxvf x-ui-linux-$(_arch).tar.gz
    rm -f x-ui-linux-$(_arch).tar.gz
    cd x-ui
    chmod +x x-ui x-ui.sh
    if [[ $(_arch) == "armv5" || $(_arch) == "armv6" || $(_arch) == "armv7" ]]; then
        mv bin/xray-linux-$(_arch) bin/xray-linux-arm32
        chmod +x bin/xray-linux-arm32
        if [[ -f bin/mtg-linux-$(_arch) ]]; then mv bin/mtg-linux-$(_arch) bin/mtg-linux-arm; chmod +x bin/mtg-linux-arm; fi
    fi
    chmod +x bin/* 2>/dev/null || true
    fetch_lucx_geofiles /usr/local/x-ui/bin || { echo "Failed to download LucX geodata."; exit 1; }
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    _panel_initial_config
    cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
    systemctl daemon-reload
    systemctl enable x-ui
    # Do not start x-ui here. The bootstrap configuration still uses the
    # temporary panel port and the final subscription port has not yet been
    # written. Starting here can make the web server and sub server compete
    # for port 2096. The first real start is deferred until configure_xui_db().
    msg_ok "LucX-UI ${tag_version} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# FAIL2BAN / IP LIMIT
# Match upstream LucX installer: delegate setup to the freshly installed x-ui
# CLI so the panel's own jail/filter/action logic stays authoritative.
# Non-fatal by design; XUI_ENABLE_FAIL2BAN=false opts out.
# ─────────────────────────────────────────────────────────────────────────────
setup_fail2ban() {
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        msg_inf "XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}, skipping Fail2ban auto-setup."
        return 0
    fi

    if [[ ! -x /usr/bin/x-ui ]]; then
        msg_inf "x-ui CLI not found; skipping Fail2ban auto-setup."
        return 0
    fi

    # Older x-ui scripts may not provide the non-interactive setup command.
    if ! grep -q '"setup-fail2ban")' /usr/bin/x-ui; then
        msg_inf "This x-ui.sh predates 'x-ui setup-fail2ban'; skipping Fail2ban auto-setup."
        return 0
    fi

    msg_inf "Setting up Fail2ban for the IP Limit feature..."
    if /usr/bin/x-ui setup-fail2ban; then
        msg_ok "Fail2ban setup complete."
    else
        msg_inf "Fail2ban setup did not finish; IP Limit stays disabled until it is configured from x-ui. Continuing."
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# X-UI SERVICE READINESS
# ─────────────────────────────────────────────────────────────────────────────
wait_for_xui_active() {
    local timeout="${1:-15}" i
    for ((i=0; i<timeout; i++)); do
        if systemctl is-active --quiet x-ui; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restart_xui_wait() {
    x-ui restart >/dev/null 2>&1 || true
    if wait_for_xui_active 15; then
        return 0
    fi
    systemctl reset-failed x-ui 2>/dev/null || true
    systemctl restart x-ui >/dev/null 2>&1 || true
    if wait_for_xui_active 15; then
        return 0
    fi
    msg_err "LucX-UI did not become active after restart."
    systemctl status x-ui --no-pager -l 2>/dev/null || true
    journalctl -u x-ui -n 40 --no-pager 2>/dev/null || true
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE X-UI DATABASE
# ─────────────────────────────────────────────────────────────────────────────
configure_xui_db() {
    if [[ ! -f $XUIDB ]]; then
        msg_err "x-ui.db not found — panel may not be installed." && exit 1
    fi

    x-ui stop 2>/dev/null || true

    local output private_key public_key emoji_flag xray_bin
    xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm32"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm"
    output=$("$xray_bin" x25519)
    private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    public_key=$(echo "$output"  | grep "^Password"   | awk '{print $3}')
    local gid_col="" gid_reality="" gid_xhttp=""
    if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw "group_id"; then
        gid_col='"group_id",'
        gid_reality="'$(gen_group_id)',"
        gid_xhttp="'$(gen_group_id)',"
    fi
    emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji' 2>/dev/null)
    [[ -z "$emoji_flag" || "$emoji_flag" == "null" ]] && emoji_flag="🌐"
    EMOJI_FLAG="$emoji_flag"

    local HP='http'; HP="${HP}s://${domain}"
    local sub_uri="${HP}/${sub_path}/"
    local json_uri="${HP}/${json_path}?name="

    # Prepare short IDs for REALITY
    local shor
    shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) \
           $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

    sqlite3 $XUIDB <<EOF
DELETE FROM "settings" WHERE "key" IN ("webCertFile","webKeyFile");

INSERT INTO "settings" ("key","value") VALUES ("subPort",             '${sub_port}');
UPDATE "settings" SET "value" = '/${sub_path}/' WHERE "key" = 'subPath';
INSERT INTO "settings" ("key","value") VALUES ("subURI",              '${sub_uri}');
UPDATE "settings" SET "value" = '/${json_path}/' WHERE "key" = 'subJsonPath';
INSERT INTO "settings" ("key","value") VALUES ("subJsonURI",          '${json_uri}');
INSERT INTO "settings" ("key","value") VALUES ("subClashEnable",      'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnableRouting",    'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnable",           'true');
INSERT INTO "settings" ("key","value") VALUES ("webListen",           '');
INSERT INTO "settings" ("key","value") VALUES ("webDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("webCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("webKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("sessionMaxAge",       '60');
INSERT INTO "settings" ("key","value") VALUES ("pageSize",            '50');
INSERT INTO "settings" ("key","value") VALUES ("expireDiff",          '0');
INSERT INTO "settings" ("key","value") VALUES ("trafficDiff",         '0');
INSERT INTO "settings" ("key","value") VALUES ("remarkModel",         '-ieo');
INSERT INTO "settings" ("key","value") VALUES ("tgBotEnable",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotToken",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotProxy",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotAPIServer",      '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotChatId",         '');
INSERT INTO "settings" ("key","value") VALUES ("tgRunTime",           '@daily');
INSERT INTO "settings" ("key","value") VALUES ("tgBotBackup",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotLoginNotify",    'true');
INSERT INTO "settings" ("key","value") VALUES ("tgCpu",               '80');
INSERT INTO "settings" ("key","value") VALUES ("tgLang",              'en-US');
INSERT INTO "settings" ("key","value") VALUES ("timeLocation",        'Europe/Moscow');
INSERT INTO "settings" ("key","value") VALUES ("secretEnable",        'false');
INSERT INTO "settings" ("key","value") VALUES ("subDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("subCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("subKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("subUpdates",          '12');
INSERT INTO "settings" ("key","value") VALUES ("subEncrypt",          'true');
INSERT INTO "settings" ("key","value") VALUES ("subShowInfo",         'true');
INSERT INTO "settings" ("key","value") VALUES ("subJsonFragment",     '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonNoises",       '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonMux",          '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonRules",        '');
INSERT INTO "settings" ("key","value") VALUES ("datepicker",          'gregorian');

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} tcp-reality','1','0','','8443','vless',
    '{
  "clients": [],
  "decryption": "none",
  "encryption": "none",
  "fallbacks": []
}',
    '{
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": ["${reality_domain}"],
    "privateKey": "${private_key}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}","${shor[1]}","${shor[2]}","${shor[3]}",
      "${shor[4]}","${shor[5]}","${shor[6]}","${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "firefox",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {"type":"none"}
  }
}',
    'inbound-8443',
    '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} xhttp-tls','1','0','/dev/shm/uds2023.sock,0666','0','vless',
    '{
  "clients": [],
  "decryption": "none",
  "encryption": "none",
  "fallbacks": []
}',
    '{
  "network": "xhttp",
  "security": "none",
  "xhttpSettings": {
    "path": "/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}',
    'inbound-/dev/shm/uds2023.sock,0666:0|',
    '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "hosts" ("inbound_id",${gid_col}"sort_order","remark","address","port","security","fingerprint","alpn")
VALUES
    ((SELECT id FROM inbounds WHERE tag='inbound-8443'),           ${gid_reality} 0, 'tcp-reality', '${domain}', 443, 'same', '',        '[]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-/dev/shm/uds2023.sock,0666:0|'), ${gid_xhttp} 0, 'xhttp-tls', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]');
EOF

    /usr/local/x-ui/x-ui setting \
        -username  "${config_username}" \
        -password  "${config_password}" \
        -port      "${panel_port}"      \
        -webBasePath "${panel_path}"

    /usr/local/x-ui/x-ui cert \
        -webCert    "/root/cert/${domain}/fullchain.pem" \
        -webCertKey "/root/cert/${domain}/privkey.pem"

    # First real start: final panel/subscription ports and certificates are
    # already written. Wait for systemd to report an actually active service.
    x-ui start >/dev/null 2>&1 || true
    if ! wait_for_xui_active 15; then
        msg_err "X-UI did not become active after final DB/config initialization."
        systemctl status x-ui --no-pager -l 2>/dev/null || true
        journalctl -u x-ui -n 40 --no-pager 2>/dev/null || true
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CLASH / MIHOMO SUBSCRIPTION
# ─────────────────────────────────────────────────────────────────────────────
install_clash_subscription() {
    install -d -m 0755 /var/www/subpage /usr/local/lib/lucx-ui-pro
    # Based on mozaroc/3x-ui-pro assets/clash/clash.yaml (a2c430c).
    cat > /var/www/subpage/clash.yaml.tpl <<'LUCX_CLASH_TEMPLATE'
mode: rule
log-level: info
mixed-port: 10000
unified-delay: true
allow-lan: true
tcp-concurrent: true
enable-process: true
find-process-mode: always

profile:
  store-selected: true
  store-fake-ip: true

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports:
        - 80
        - 8080-8880
      override-destination: true
    TLS:
      ports:
        - 443
        - 8443

dns:
  enable: true
  prefer-h3: true
  use-hosts: true
  use-system-hosts: true
  listen: 127.0.0.1:6868
  ipv6: false
  enhanced-mode: redir-host
  default-nameserver:
    - tls://77.88.8.8#DIRECT # Yandex DNS over TLS
    - 195.208.4.1#DIRECT # НСДИ
    - system
  proxy-server-nameserver:
    - tls://77.88.8.8#DIRECT # Yandex DNS over TLS
    - 195.208.4.1#DIRECT # НСДИ
    - system
  direct-nameserver:
    - tls://77.88.8.8#DIRECT # Yandex DNS over TLS
    - 195.208.4.1#DIRECT # НСДИ
    - system
  nameserver:
    - https://cloudflare-dns.com/dns-query#PROXY

proxy-providers:
  sub:
    type: http
    proxy: DIRECT
    url: https://${DOMAIN}/${SUB_PATH}/${SUB_ID}?provider=1
    path: ./proxy_providers/${DOMAIN}_${SUB_PATH}_${SUB_ID}.yaml
    interval: 3600
    override:
      override-expr:
        - '(select(.type == "vless" and .["reality-opts"] != null) | .["client-fingerprint"]) = "chrome"'
        - '(select(.type == "vless" and .["reality-opts"] != null) | .["reality-opts"]["support-x25519mlkem768"]) = true'
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      timeout: 5000
      lazy: true
      expected-status: 204

proxy-groups:
  - name: 🌍 VPN
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Hijacking.png
    type: select
    use:
      - sub
    proxies:
      - ⚡️ Fastest
  - name: ▶️ YouTube
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/YouTube.png
    type: select
    use:
      - sub
    proxies:
      - 🌍 VPN
  - name: 💬 Discord
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Discord.png
    type: select
    use:
      - sub
    proxies:
      - 🌍 VPN
  - name: ⚡️ Fastest
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Auto.png
    type: url-test
    tolerance: 150
    url: https://cp.cloudflare.com/generate_204
    interval: 300
    use:
      - sub
  - name: ➤ Telegram
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Telegram.png
    type: select
    use:
      - sub
    proxies:
      - 🌍 VPN
  - name: ➤ WhatsApp
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Facebook.png
    type: select
    use:
      - sub
    proxies:
      - 🌍 VPN
  - name: PROXY
    type: select
    hidden: true
    use:
      - sub
    proxies:
      - 🌍 VPN

rule-providers:
  facebook-ips:
    type: http
    behavior: ipcidr
    format: mrs
    interval: 86400
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/facebook.mrs
    path: ./rule-sets/facebook-ips.mrs
  whatsapp-domains:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/whatsapp.mrs
    path: ./rule-sets/whatsapp-domains.mrs
  telegram-ips:
    type: http
    behavior: ipcidr
    format: mrs
    interval: 86400
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs
    path: ./rule-sets/telegram-ips.mrs
  telegram-domains:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/telegram.mrs
    path: ./rule-sets/telegram-domains.mrs
  discord_domains:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/discord.mrs
    path: ./rule-sets/discord_domains.mrs
  discord_voiceips:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/discord-voice-ip-list.mrs
    path: ./rule-sets/discord_voiceips.mrs
  refilter_domains:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/domain-rule.mrs
    path: ./re-filter/domain-rule.mrs
    interval: 86400
  refilter_ipsum:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/ip-rule.mrs
    path: ./re-filter/ip-rule.mrs
    interval: 86400
  youtube:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/youtube.mrs
    path: ./rule-sets/youtube.mrs
  oisd_big:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/big.mrs
    path: ./oisd/big.mrs
  torrent-trackers:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-trackers.mrs
    path: ./rule-sets/torrent-trackers.mrs
    interval: 86400
  torrent-clients:
    type: http
    behavior: classical
    format: yaml
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-clients.yaml
    path: ./rule-sets/torrent-clients.yaml
    interval: 86400
  ru-bundle:
    type: http
    behavior: domain
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rule.mrs
    path: ./ru-bundle/rule.mrs
    interval: 86400

rules:
  - OR,((DOMAIN,ipwhois.app),(DOMAIN,ipwho.is),(DOMAIN,api.ip.sb),(DOMAIN,ipapi.co),(DOMAIN,ipinfo.io),(DOMAIN,ip-api.com),(DOMAIN,cloudflare-dns.com)),🌍 VPN
  - RULE-SET,oisd_big,REJECT
  - OR,((RULE-SET,telegram-ips),(RULE-SET,telegram-domains)),➤ Telegram
  - OR,((RULE-SET,facebook-ips),(RULE-SET,whatsapp-domains)),➤ WhatsApp
  - OR,((RULE-SET,torrent-clients),(RULE-SET,torrent-trackers)),DIRECT
  - RULE-SET,youtube,▶️ YouTube
  - OR,((RULE-SET,discord_domains),(RULE-SET,discord_voiceips),(PROCESS-NAME,Discord.exe)),💬 Discord
  - RULE-SET,ru-bundle,🌍 VPN
  - RULE-SET,refilter_domains,🌍 VPN
  - RULE-SET,refilter_ipsum,🌍 VPN
  - MATCH,DIRECT
LUCX_CLASH_TEMPLATE
    python3 - "$domain" "$sub_path" <<'PY_CLASH_TEMPLATE'
from pathlib import Path
import sys
path = Path('/var/www/subpage/clash.yaml.tpl')
text = path.read_text(encoding='utf-8')
text = text.replace('${DOMAIN}', sys.argv[1]).replace('${SUB_PATH}', sys.argv[2])
path.write_text(text, encoding='utf-8')
PY_CLASH_TEMPLATE
    chmod 0644 /var/www/subpage/clash.yaml.tpl

    cat > /usr/local/lib/lucx-ui-pro/clash-sub-server.py <<'PY_CLASH_SERVER'
#!/usr/bin/env python3
"""Local YAML template renderer for a per-client Clash subscription."""
import argparse
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

TEMPLATE = Path('/var/www/subpage/clash.yaml.tpl')


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == '/health':
            return self.reply(200, b'ok', 'text/plain')
        if parsed.path != '/api/clash':
            return self.reply(404, b'not found', 'text/plain')
        sub_id = parse_qs(parsed.query).get('sub_id', [''])[0]
        if not re.fullmatch(r'[A-Za-z0-9._~-]{1,256}', sub_id):
            return self.reply(400, b'invalid subscription id', 'text/plain')
        try:
            body = TEMPLATE.read_text(encoding='utf-8').replace('${SUB_ID}', sub_id).encode('utf-8')
        except OSError:
            return self.reply(503, b'template unavailable', 'text/plain')
        self.reply(200, body, 'text/yaml; charset=utf-8')

    def reply(self, status, body, content_type):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        if status == 200 and content_type.startswith('text/yaml'):
            self.send_header('Content-Disposition', 'attachment; filename="clash.yaml"')
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
PY_CLASH_SERVER
    chmod 0755 /usr/local/lib/lucx-ui-pro/clash-sub-server.py
    cat > /etc/systemd/system/lucx-clash-sub.service <<EOF
[Unit]
Description=LucX-UI Clash subscription renderer
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/python3 /usr/local/lib/lucx-ui-pro/clash-sub-server.py --port ${clash_port}
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now lucx-clash-sub.service || return 1
    local attempt
    for attempt in 1 2 3 4 5; do
        if curl -fsS --max-time 2 "http://127.0.0.1:${clash_port}/health" >/dev/null 2>&1; then
            msg_ok "Clash/Mihomo subscription ready."
            return 0
        fi
        sleep 1
    done
    msg_err "Clash subscription renderer did not start."
    systemctl status lucx-clash-sub.service --no-pager -l 2>/dev/null || true
    return 1
}

# INSTALL FAKE SITE
# ─────────────────────────────────────────────────────────────────────────────
install_fake_site() {
    local idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
    local site_id
    site_id=$(printf "site-%02d" "$idx")
    local url="${GITHUB_RAW}/assets/fake-sites/${site_id}/index.html"

    mkdir -p /var/www/html
    if curl -fsSL "$url" -o /var/www/html/index.html; then
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        chmod 644 /var/www/html/index.html
        msg_ok "Fake cover site '${site_id}' installed."
    else
        msg_err "Failed to download fake site ${site_id} from GitHub."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# AMNEZIAWG / PANEL BBR COMPATIBILITY
#
# The official LucX AWG installer is bundled inside the panel tarball. Its
# original performance file also writes BBR + fq. That would compete with the
# panel-owned 99-bbr-x-ui.conf, so Pro patches only those two assignments out
# and leaves the AWG-specific TCP buffers/backlog in 99-awg-performance.conf.
# ─────────────────────────────────────────────────────────────────────────────
LUCX_AWG_INSTALLER=/usr/local/x-ui/bin/install-awg-module.sh
LUCX_AWG_SYSCTL=/etc/sysctl.d/99-awg-performance.conf
LUCX_AWG_GUARD=/usr/local/sbin/lucx-awg-sysctl-guard
LUCX_AWG_GUARD_SERVICE=/etc/systemd/system/lucx-awg-sysctl-guard.service
LUCX_AWG_GUARD_PATH=/etc/systemd/system/lucx-awg-sysctl-guard.path

patch_awg_installer() {
    local script="${1:-$LUCX_AWG_INSTALLER}"
    [[ -f "$script" ]] || return 1
    python3 - "$script" <<'PY_AWG_PATCH'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="surrogateescape").read()
# Remove only the two persistent BBR/qdisc assignments. AWG performance
# buffers/backlog remain intact. Repeated patching is intentionally idempotent.
new = re.sub(r'(?m)^\s*net\.core\.default_qdisc\s*=\s*fq\s*$\n?', '', text)
new = re.sub(r'(?m)^\s*net\.ipv4\.tcp_congestion_control\s*=\s*bbr\s*$\n?', '', new)
if new != text:
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
PY_AWG_PATCH
    chmod +x "$script" 2>/dev/null || true
}

sanitize_awg_sysctl_file() {
    [[ -f "$LUCX_AWG_SYSCTL" ]] || return 0

    # Remove BBR/FQ ownership from the AWG-specific file. Keep the AWG buffers.
    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
        "$LUCX_AWG_SYSCTL"

    # The panel remains the sole owner of BBR/FQ. If it has a BBR file, apply
    # that state; otherwise the AWG installer must not re-enable BBR implicitly.
    if [[ -f "$LUCX_BBR_FILE" ]]; then
        sysctl -p "$LUCX_BBR_FILE" >/dev/null 2>&1 || true
    fi
}

install_awg_sysctl_guard() {
    mkdir -p /usr/local/sbin /etc/systemd/system

    cat > "$LUCX_AWG_GUARD" <<'EOF'
#!/bin/bash
set -u
SCRIPT=/usr/local/x-ui/bin/install-awg-module.sh
SYSCTL=/etc/sysctl.d/99-awg-performance.conf

# Keep the panel's install-awg wrapper BBR-neutral even after a panel update.
for XUI in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
    [[ -f "$XUI" ]] || continue
    python3 - "$XUI" <<'PY_GUARD_XUI'
import sys
path=sys.argv[1]
text=open(path,encoding="utf-8",errors="surrogateescape").read()
start=text.find("install_awg_module() {")
if start < 0:
    raise SystemExit(0)
end=text.find("\nuninstall_awg_module()", start)
if end < 0:
    raise SystemExit(0)
block=text[start:end]
if 'lucx-awg-sysctl-guard' not in block and 'bash "$script" "$@"' in block:
    block=block.replace(
        '    bash "$script" "$@"\n',
        '    /usr/local/sbin/lucx-awg-sysctl-guard >/dev/null 2>&1 || true\n'
        '    bash "$script" "$@"\n'
        '    local rc=$?\n'
        '    /usr/local/sbin/lucx-awg-sysctl-guard >/dev/null 2>&1 || true\n'
        '    return $rc\n',1)
    text=text[:start]+block+text[end:]
    open(path,'w',encoding='utf-8',errors='surrogateescape').write(text)
PY_GUARD_XUI
    chmod +x "$XUI" 2>/dev/null || true
done

if [[ -f "$SCRIPT" ]] && grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$|^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' "$SCRIPT"; then
    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
        "$SCRIPT"
fi

if [[ -f "$SYSCTL" ]] && grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$|^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' "$SYSCTL"; then
    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
        "$SYSCTL"
    if [[ -f /etc/sysctl.d/99-bbr-x-ui.conf ]]; then
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf >/dev/null 2>&1 || true
    elif [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        restore=/etc/x-ui/.lucx-bbr-restore
        qdisc=fq_codel
        cc=cubic
        if [[ -s "$restore" ]]; then
            saved=$(tr -d '[:space:]' < "$restore" 2>/dev/null || true)
            case "$saved" in
                fq:*|fq_codel:*|cake:*|pfifo_fast:*) qdisc=${saved%%:*}; cc=${saved#*:} ;;
            esac
            [[ "$cc" == bbr || -z "$cc" ]] && cc=cubic
        fi
        sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || true
    fi
fi
EOF
    chmod 0755 "$LUCX_AWG_GUARD"

    cat > "$LUCX_AWG_GUARD_SERVICE" <<'EOF'
[Unit]
Description=Keep LucX AWG sysctl installer BBR-neutral

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lucx-awg-sysctl-guard
EOF

    cat > "$LUCX_AWG_GUARD_PATH" <<'EOF'
[Unit]
Description=Watch LucX AWG installer and performance sysctl

[Path]
PathChanged=/usr/local/x-ui/bin/install-awg-module.sh
PathChanged=/etc/sysctl.d/99-awg-performance.conf
PathChanged=/usr/bin/x-ui
PathChanged=/usr/local/x-ui/x-ui.sh
Unit=lucx-awg-sysctl-guard.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lucx-awg-sysctl-guard.path >/dev/null 2>&1 || true
    systemctl start lucx-awg-sysctl-guard.service >/dev/null 2>&1 || true
    systemctl start lucx-awg-sysctl-guard.path >/dev/null 2>&1 || true
}

patch_panel_bbr_script() {
    local script
    for script in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
        [[ -f "$script" ]] || continue
        python3 - "$script" <<'PY_BBR_PATCH'
import sys
path=sys.argv[1]
text=open(path,encoding="utf-8",errors="surrogateescape").read()
old="""enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then"""
new="""enable_bbr() {
    # Pro persists BBR/FQ modules, but load them immediately as well so the
    # panel toggle works even if the module was not auto-loaded yet.
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then"""
if old in text and 'modprobe tcp_bbr >/dev/null 2>&1 || true' not in text:
    text=text.replace(old,new,1)
needle="""        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"""
repl="""        mkdir -p /etc/x-ui
        printf '%s:%s\\n' "$(sysctl -n net.core.default_qdisc)" "$(sysctl -n net.ipv4.tcp_congestion_control)" > /etc/x-ui/.lucx-bbr-restore
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"""
if needle in text and '/etc/x-ui/.lucx-bbr-restore' not in text:
    text=text.replace(needle,repl,1)
needle2="""        sysctl -w net.ipv4.tcp_congestion_control=\"${old_settings#*:}\"
        rm /etc/sysctl.d/99-bbr-x-ui.conf"""
repl2="""        sysctl -w net.ipv4.tcp_congestion_control=\"${old_settings#*:}\"
        mkdir -p /etc/x-ui
        printf '%s\\n' \"$old_settings\" > /etc/x-ui/.lucx-bbr-restore
        rm /etc/sysctl.d/99-bbr-x-ui.conf"""
if needle2 in text and "printf '%s\\n' \"$old_settings\" > /etc/x-ui/.lucx-bbr-restore" not in text:
    text=text.replace(needle2,repl2,1)
open(path,'w',encoding='utf-8',errors='surrogateescape').write(text)
PY_BBR_PATCH
        chmod +x "$script" 2>/dev/null || true
    done
}

patch_panel_awg_command() {
    local script
    for script in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
        [[ -f "$script" ]] || continue
        python3 - "$script" <<'PY_AWG_CMD_PATCH'
import sys
path=sys.argv[1]
text=open(path,encoding="utf-8",errors="surrogateescape").read()
start=text.find("install_awg_module() {")
if start < 0:
    raise SystemExit(0)
end=text.find("\nuninstall_awg_module()", start)
if end < 0:
    raise SystemExit(0)
block=text[start:end]
if 'lucx-awg-sysctl-guard' not in block and 'bash "$script" "$@"' in block:
    block=block.replace(
        '    bash "$script" "$@"\n',
        '    /usr/local/sbin/lucx-awg-sysctl-guard >/dev/null 2>&1 || true\n'
        '    bash "$script" "$@"\n'
        '    local rc=$?\n'
        '    /usr/local/sbin/lucx-awg-sysctl-guard >/dev/null 2>&1 || true\n'
        '    return $rc\n',1)
    text=text[:start]+block+text[end:]
    open(path,'w',encoding='utf-8',errors='surrogateescape').write(text)
PY_AWG_CMD_PATCH
        chmod +x "$script" 2>/dev/null || true
    done
}

install_awg_kernel() {
    local script="$LUCX_AWG_INSTALLER"
    [[ -x "$script" ]] || {
        msg_err "AmneziaWG installer is missing: $script"
        return 1
    }

    # Critical: patch the bundled upstream installer BEFORE it can generate
    # 99-awg-performance.conf. This also protects later x-ui install-awg calls.
    if ! patch_awg_installer "$script"; then
        msg_err "Failed to make the AmneziaWG installer BBR-neutral."
        return 1
    fi

    install_awg_sysctl_guard
    sanitize_awg_sysctl_file

    msg_inf "Installing AmneziaWG kernel module/tools via bundled LucX installer..."
    if ! bash "$script"; then
        msg_err "AmneziaWG installation failed; panel installation will continue, but AWG may be unavailable."
        return 0
    fi

    # The official installer may have refreshed the performance file. Sanitize
    # it once more and then let the panel-owned BBR state win.
    patch_awg_installer "$script" || true
    sanitize_awg_sysctl_file
    install_awg_sysctl_guard
    return 0
}

maybe_reboot_for_awg() {
    [[ -f /etc/x-ui/.awg-reboot-needed ]] || return 0

    local ans=""
    if [[ -t 0 && -r /dev/tty ]]; then
        while true; do
            echo
            msg_inf "────────────────────────────────────────────────────────────────────────────────"
            msg_inf "Перезагрузка системы? (необходимо для AmneziaWG kernel)"
            echo '  1) Да'
            echo '  2) Нет'
            msg_inf "────────────────────────────────────────────────────────────────────────────────"
            echo -en 'Выбор [1-2]: '
            read -r ans </dev/tty || ans=""
            case "${ans// /}" in
                1)
                    rm -f /etc/x-ui/.awg-reboot-needed
                    echo
                    msg_inf "Перезагрузка системы..."
                    reboot || msg_err "Не удалось выполнить перезагрузку; перезагрузите сервер вручную."
                    return 0
                    ;;
                2)
                    rm -f /etc/x-ui/.awg-reboot-needed
                    msg_inf "Перезагрузка пропущена. Она необходима для загрузки нового ядра AmneziaWG."
                    return 0
                    ;;
                *) continue ;;
            esac
        done
    else
        # No controlling terminal: never reboot automatically. The marker is
        # consumed so a non-interactive install cannot unexpectedly reboot later.
        rm -f /etc/x-ui/.awg-reboot-needed
        msg_inf "Перезагрузка пропущена: нет интерактивного терминала. Она необходима для нового ядра AmneziaWG."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM TUNING (BBR module persistence + kernel params)
#
# Ownership model:
#   - LucX panel owns BBR/FQ sysctl state in 99-bbr-x-ui.conf.
#   - Pro owns only kernel-module loading/persistence and the other tuning
#     parameters.
#   - The runtime qdisc helper reads net.core.default_qdisc at execution time,
#     so it never hardcodes a qdisc chosen by the panel.
# ─────────────────────────────────────────────────────────────────────────────
LUCX_MODULES_FILE=/etc/modules-load.d/lucx-ui-network.conf
LUCX_LEGACY_MODULES_FILE=/etc/modules-load.d/tcp-bbr.conf
LUCX_TUNING_FILE=/etc/sysctl.d/99-zz-lucx-ui-tuning.conf
LUCX_BBR_FILE=/etc/sysctl.d/99-bbr-x-ui.conf

persist_network_modules() {
    local modules=() current_qdisc qdisc_module module

    mkdir -p /etc/modules-load.d

    # Always try the BBR/FQ modules because the panel may enable BBR later.
    # Persist only what the kernel actually exposes.
    if modprobe tcp_bbr 2>/dev/null; then
        modules+=(tcp_bbr)
    fi
    if modprobe sch_fq 2>/dev/null; then
        modules+=(sch_fq)
    fi

    # Also persist the module for the qdisc that is currently configured.
    # This matters when the panel later disables BBR and restores the
    # pre-BBR qdisc (commonly fq_codel, which can itself be a module).
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    case "$current_qdisc" in
        fq_codel) qdisc_module=sch_fq_codel ;;
        cake)     qdisc_module=sch_cake ;;
        fq)       qdisc_module=sch_fq ;;
        *)        qdisc_module="" ;;
    esac
    if [[ -n "$qdisc_module" ]] && modprobe "$qdisc_module" 2>/dev/null; then
        modules+=("$qdisc_module")
    fi

    # Deduplicate while preserving order.
    if [[ ${#modules[@]} -gt 0 ]]; then
        mapfile -t modules < <(printf '%s\n' "${modules[@]}" | awk 'NF && !seen[$0]++')
        printf '%s\n' "${modules[@]}" > "$LUCX_MODULES_FILE"
        chmod 0644 "$LUCX_MODULES_FILE"
    else
        rm -f "$LUCX_MODULES_FILE"
    fi

    # Remove the old Pro-specific filename so the same module is not managed
    # by two files after an upgrade. This file belongs to older Pro releases.
    rm -f "$LUCX_LEGACY_MODULES_FILE"
}

migrate_legacy_bbr_sysctl() {
    # Old Pro releases stored BBR/FQ in our late sysctl file. If that legacy
    # file says BBR was enabled and the panel has no own file yet, migrate the
    # active state to the panel-owned file first. The exact pre-BBR values were
    # not stored by old Pro versions, so use the standard upstream fallback.
    [[ -f "$LUCX_TUNING_FILE" ]] || return 0

    local legacy_cc legacy_qdisc
    legacy_cc=$(awk -F= '$1 ~ /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$LUCX_TUNING_FILE")
    legacy_qdisc=$(awk -F= '$1 ~ /^[[:space:]]*net\.core\.default_qdisc[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$LUCX_TUNING_FILE")

    if [[ ! -f "$LUCX_BBR_FILE" && "$legacy_cc" == "bbr" && "$legacy_qdisc" == "fq" ]]; then
        mkdir -p /etc/sysctl.d
        {
            echo "#fq_codel:cubic"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "$LUCX_BBR_FILE"
        chmod 0644 "$LUCX_BBR_FILE"
    fi

    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' \
        "$LUCX_TUNING_FILE"
}

seed_panel_bbr_state() {
    local current_cc current_qdisc available_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)

    # If the panel already owns a BBR config, do not overwrite it. The user
    # may have explicitly enabled/disabled BBR through the panel menu.
    if [[ -f "$LUCX_BBR_FILE" ]]; then
        return 0
    fi

    # Automatically preserve the old Pro behaviour on a fresh installation:
    # when the kernel supports BBR + fq, create the panel-owned config and
    # apply it. After this point the panel is the sole owner of these sysctls.
    if grep -qw bbr <<< "$available_cc" &&
       modprobe tcp_bbr 2>/dev/null &&
       modprobe sch_fq 2>/dev/null &&
       sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 &&
       sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        mkdir -p /etc/sysctl.d
        mkdir -p /etc/x-ui
        printf '%s:%s\n' "$current_qdisc" "$current_cc" > /etc/x-ui/.lucx-bbr-restore
        {
            echo "#${current_qdisc}:${current_cc}"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "$LUCX_BBR_FILE"
        chmod 0644 "$LUCX_BBR_FILE"
        # Re-apply through the same file the panel's own enable_bbr() uses.
        sysctl -p "$LUCX_BBR_FILE" >/dev/null 2>&1 || return 1
        msg_ok "TCP tuning: BBR + fq enabled (panel-owned config)."
        return 0
    fi

    # BBR is unavailable on this kernel. Do not create a panel BBR file and do
    # not persist BBR sysctl keys in Pro. The distro/current kernel fallback
    # remains authoritative until the user enables BBR from the panel later.
    local fallback_cc fallback_qdisc qdisc
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)

    if grep -qw cubic <<< "$available_cc"; then
        fallback_cc=cubic
    elif grep -qw "$current_cc" <<< "$available_cc"; then
        fallback_cc="$current_cc"
    else
        fallback_cc="${available_cc%% *}"
    fi
    [[ -n "$fallback_cc" ]] || fallback_cc="$current_cc"
    sysctl -w "net.ipv4.tcp_congestion_control=${fallback_cc}" >/dev/null 2>&1 || true

    modprobe sch_fq_codel 2>/dev/null || true
    fallback_qdisc=""
    for qdisc in fq_codel "$current_qdisc" pfifo_fast; do
        [[ -n "$qdisc" ]] || continue
        if sysctl -w "net.core.default_qdisc=${qdisc}" >/dev/null 2>&1; then
            fallback_qdisc="$qdisc"
            break
        fi
    done

    if [[ -n "$fallback_qdisc" ]]; then
        msg_inf "BBR is unavailable; using ${fallback_cc} + ${fallback_qdisc}."
    else
        msg_inf "BBR is unavailable; keeping the current kernel qdisc."
    fi
}

configure_runtime_qdisc() {
    local helper=/usr/local/sbin/lucx-apply-qdisc

    # net.core.default_qdisc only affects qdiscs created after the sysctl is
    # applied. VPS interfaces often already exist by then, so apply the
    # currently selected qdisc to every interface carrying a default route and
    # repeat it after network-online on each boot. The helper reads the current
    # sysctl every time instead of storing its own qdisc policy.
    mkdir -p /usr/local/sbin
    cat > "$helper" <<'EOF'
#!/bin/bash
set -u
QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
[[ -n "$QDISC" ]] || QDISC=fq_codel

get_default_ifaces() {
    ip -o route show default 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); break } }' |
        sort -u
}

ifaces=""
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    ifaces=$(get_default_ifaces)
    [[ -n "$ifaces" ]] && break
    sleep 2
done

[[ -n "$ifaces" ]] || exit 1
status=0
while IFS= read -r iface; do
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] || continue
    tc qdisc replace dev "$iface" root "$QDISC" || status=1
done <<< "$ifaces"
exit "$status"
EOF
    chmod 0755 "$helper"

    cat > /etc/systemd/system/lucx-apply-qdisc.service <<'EOF'
[Unit]
Description=Apply LucX qdisc to default-route interfaces
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lucx-apply-qdisc
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Keep the runtime qdisc in sync with panel BBR toggles. The panel changes
    # 99-bbr-x-ui.conf and the live sysctl values; this path unit immediately
    # re-runs the helper so existing interfaces follow the new qdisc too.
    cat > /etc/systemd/system/lucx-qdisc-sync.service <<'EOF'
[Unit]
Description=Sync LucX qdisc after sysctl policy changes
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lucx-apply-qdisc
EOF

    cat > /etc/systemd/system/lucx-qdisc-sync.path <<'EOF'
[Unit]
Description=Watch LucX sysctl policy for qdisc changes

[Path]
PathChanged=/etc/sysctl.d
Unit=lucx-qdisc-sync.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lucx-apply-qdisc.service >/dev/null 2>&1 || return 1
    systemctl enable lucx-qdisc-sync.path >/dev/null 2>&1 || return 1
    systemctl start lucx-qdisc-sync.path >/dev/null 2>&1 || return 1
    "$helper" || return 1
}

tune_system() {
    # Pro manages module loading/persistence; the panel owns persistent BBR/FQ
    # sysctl state. Other kernel tuning stays in our dedicated sysctl file.
    persist_network_modules
    migrate_legacy_bbr_sysctl
    seed_panel_bbr_state || return 1
    # seed_panel_bbr_state may choose a fallback qdisc (for example fq_codel)
    # when BBR is unavailable. Persist the module for that final qdisc too.
    persist_network_modules

    # Migrate values written by older versions out of /etc/sysctl.conf. Keep
    # BBR/FQ out of this file so the panel remains the sole persistent owner.
    touch /etc/sysctl.conf
    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' \
        -e '/^[[:space:]]*fs\.file-max[[:space:]]*=/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_timestamps[[:space:]]*=/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_sack[[:space:]]*=/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_window_scaling[[:space:]]*=/d' \
        /etc/sysctl.conf

    local params=(
        "fs.file-max=2097152"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
    )
    mkdir -p /etc/sysctl.d
    printf '%s\n' "${params[@]}" > "$LUCX_TUNING_FILE"
    if ! sysctl -p "$LUCX_TUNING_FILE"; then
        msg_err "Failed to apply system tuning parameters."
        return 1
    fi

    local active_cc active_qdisc
    active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    active_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    [[ -n "$active_cc" && -n "$active_qdisc" ]] || {
        msg_err "TCP tuning verification failed: kernel did not expose congestion-control/qdisc state."
        return 1
    }

    if ! configure_runtime_qdisc; then
        msg_err "Failed to apply the current qdisc to the active default-route interface."
        return 1
    fi

    local iface iface_qdisc
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        iface_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null |
            awk '$4 == "root" { print $2; exit }')
        if [[ "$iface_qdisc" != "$active_qdisc" ]]; then
            msg_err "Qdisc verification failed on ${iface}: expected ${active_qdisc}, got ${iface_qdisc:-unknown}."
            return 1
        fi
    done < <(ip -o route show default 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); break } }' |
        sort -u)

    msg_ok "TCP tuning verified: ${active_cc} + ${active_qdisc}; kernel modules persisted in ${LUCX_MODULES_FILE}."
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON JOBS
# ─────────────────────────────────────────────────────────────────────────────
setup_cron() {
    # Minimal Debian/Ubuntu images may not include the `crontab` command.
    # Install it here as a safeguard as well as in install_packages(), so this
    # function also works during upgrades and partial/repeated installations.
    if ! command -v crontab >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q cron || return 1
    fi

    systemctl enable --now cron 2>/dev/null || true
    remove_lucx_cron_jobs || return 1
    # Xray owns scheduled geodata downloads and reloads through cfg.geodata.
    # Retire the old RUNET-only updater when upgrading an existing installation.
    rm -f /usr/local/x-ui/update-geodata.sh
    (crontab -l 2>/dev/null; echo '0 1 * * * certbot renew --non-interactive --pre-hook "systemctl stop nginx" --deploy-hook "x-ui restart" --post-hook "systemctl start nginx" >/dev/null 2>&1') | crontab -
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
    ufw disable
    # Enable kernel forwarding and UFW routed traffic for all installations,
    # not only when a particular tunnel inbound was selected.
    cat > /etc/sysctl.d/99-lucx-ui-forwarding.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ufw default allow routed
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    if [[ "${DEPLOY_HY2}" == "1" && -n "${hy2_port}" ]]; then
        ufw allow ${hy2_port}/udp
    fi
    if [[ "${DEPLOY_QWDTT}" == "1" ]]; then
        ufw allow 56000/udp
        ufw allow 56001/udp
        ufw allow 56003/udp
    fi
    if [[ "${DEPLOY_CSQTT}" == "1" ]]; then
        ufw allow 46000/udp
    fi
    ufw --force enable
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW RESULTS
# ─────────────────────────────────────────────────────────────────────────────
show_results() {
    clear
    if systemctl is-active --quiet x-ui &&
       systemctl is-active --quiet nginx &&
       nginx -t >/dev/null 2>&1; then
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        HP='http'; HP="${HP}s://${domain}/${panel_path}/"
        msg_inf "X-UI Secure Panel: ${HP}\n"
        echo -e "Username:  ${config_username}\n"
        echo -e "Password:  ${config_password}\n"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        print_adguard_results
        if [[ "${DEPLOY_TPROXY}" == "1" && -n "${webproxy_domain}" && -n "${TPROXY_SECRET}" ]]; then
            H='http'; H="${H}s://"
            msg_inf "Telegram WEB-proxy:"
            echo "${H}t.me/webproxy?server=${webproxy_domain}&secret=${TPROXY_SECRET}"
            echo
        fi
        msg_inf "Please save this screen!"
        return 0
    else
        nginx -t
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_err "x-ui or nginx check failed. Try on a clean Linux install."
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    choose_adguard || return 1
    choose_xray_dns || return 1
    choose_rkn_guard || return 1
    choose_extra_inbounds || return 1
    choose_webproxy_domain || return 1

    # Install base packages only after all initial questions are answered.
    [[ ! -e /opt/AdGuardHome && ! -e /usr/local/bin/rkn-guard ]] || {
        msg_err "Existing AdGuard/rkn-guard is not owned by this installer."
        return 1
    }
    { modinfo amneziawg >/dev/null 2>&1 || [[ -e /etc/modules-load.d/amneziawg.conf ]]; } && {
        mkdir -p "$PREINSTALL_STATE_DIR"
        touch "$PREINSTALL_STATE_DIR/awg-preexisting"
    }
    save_preinstall_state || return 1
    install_base_dependencies || return 1
    mark_install_in_progress
    clean_previous_install || return 1
    install_packages || return 1
    get_server_ip || return 1
    printf '%s\n' "$domain" "$reality_domain" "${webproxy_domain:-}" | sed '/^$/d' > "$PREINSTALL_STATE_DIR/domains"
    : > "$PREINSTALL_STATE_DIR/new-certificates"
    local cert
    while IFS= read -r cert; do
        [[ -e "/etc/letsencrypt/live/$cert" ]] || printf '%s\n' "$cert" >> "$PREINSTALL_STATE_DIR/new-certificates"
    done < "$PREINSTALL_STATE_DIR/domains"
    get_ssl_certs || return 1
    if systemctl is-active --quiet x-ui; then
        x-ui restart || return 1
    else
        install_panel || return 1
    fi

    # AWG is optional on a fresh install. The guard and panel wrapper are
    # installed regardless, so a later `x-ui install-awg` remains BBR-neutral.
    install_awg_sysctl_guard
    patch_panel_awg_command
    if [[ "${DEPLOY_AWG}" == "y" ]]; then
        install_awg_kernel || return 1
    else
        msg_inf "AmneziaWG installation skipped. It can be installed later via: x-ui install-awg"
    fi
    patch_panel_bbr_script

    install_clash_subscription || return 1
    configure_nginx || return 1
    if [[ "${DEPLOY_AGH}" == "1" ]]; then
        install_adguard || return 1
        touch "$PREINSTALL_STATE_DIR/adguard-installed"
    fi
    configure_xui_db || return 1
    setup_fail2ban || return 1
    install_fake_site || return 1
    install_tproxy_site || return 1
    tune_system || return 1
    patch_panel_bbr_script
    patch_panel_awg_command
    setup_cron || return 1
    setup_firewall || return 1
    if [[ "${DEPLOY_RKN}" == "1" || "${DEPLOY_RKN}" == "2" ]]; then
        install_rkn_guard "${DEPLOY_RKN}" || return 1
        touch "$PREINSTALL_STATE_DIR/rkn-installed"
    fi

    if ! systemctl is-enabled --quiet x-ui; then
        systemctl daemon-reload && systemctl enable x-ui.service || return 1
    fi
    restart_xui_wait || return 1

    apply_xray_dns || return 1
    insert_hy2_inbound || return 1
    insert_extra_inbound || return 1
    restart_xui_wait || return 1
    # Final service state is authoritative after the readiness helper.
    if ! systemctl is-active --quiet x-ui; then
        msg_err "LucX-UI failed to stay active after final configuration."
        systemctl status x-ui --no-pager -l 2>/dev/null || true
        journalctl -u x-ui -n 40 --no-pager 2>/dev/null || true
        return 1
    fi

    show_results || return 1
    # The installation is now complete. Remove the crash-recovery marker before
    # the optional AWG reboot prompt so a manual rerun never repeats cleanup.
    clear_install_in_progress
    if [[ "${DEPLOY_AWG}" == "y" ]]; then
        maybe_reboot_for_awg
    fi
}

if ! is_full_install_request && [[ ! -f "$PREINSTALL_STATE_DIR/owned-by-lucx-ui-pro" ]]; then
    msg_err "Component maintenance requires an installation owned by this script."
    exit 1
fi

if [[ "${TG_WEB_PROXY_UNINSTALL}" == "y" ]]; then
    uninstall_tg_web_proxy
    exit $?
fi
if [[ "${TG_WEB_PROXY_ONLY}" == "y" ]]; then
    install_tg_web_proxy
    exit $?
fi
if [[ "${RKN_GUARD_UNINSTALL}" == "y" ]]; then
    uninstall_rkn_guard
    exit $?
fi
if [[ "${RKN_GUARD_ONLY}" == "y" ]]; then
    choose_rkn_guard || exit $?
    case "${DEPLOY_RKN}" in
        1|2)
            install_rkn_guard "${DEPLOY_RKN}" || exit $?
            touch "$PREINSTALL_STATE_DIR/rkn-installed"
            exit 0
            ;;
        3)
            msg_inf "Установка rkn-guard отменена."
            exit 0
            ;;
    esac
fi
if [[ "${ADGUARD_UNINSTALL}" == "y" ]]; then
    uninstall_adguard
    exit $?
fi
if [[ "${ADGUARD_ONLY}" == "y" ]]; then
    install_adguard || exit $?
    touch "$PREINSTALL_STATE_DIR/adguard-installed"
    print_adguard_results || exit $?
    exit 0
fi

if ! main; then
    msg_err "Установка остановлена из-за ошибки. Проверьте сообщения выше."
    exit 1
fi
