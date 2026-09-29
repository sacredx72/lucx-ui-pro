#!/usr/bin/env bash
# lucx-ui-backup.sh — backup and restore LucX-UI panel + nginx + certs
# Usage:
#   lucx-ui-backup.sh backup           — create timestamped backup
#   lucx-ui-backup.sh restore <file>   — restore from backup archive
#   lucx-ui-backup.sh list             — list available backups
set -Eeuo pipefail
umask 077

BACKUP_STORE="/var/backups/x-ui"
PACKAGES="ca-certificates curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin cron iproute2 ipset iptables rsyslog whois fail2ban nftables"

# ── paths to back up ──────────────────────────────────────────────────────────
BACKUP_PATHS=(
    /etc/nginx
    /etc/x-ui
    /etc/default/x-ui
    /etc/fail2ban
    /etc/cron.d
    /usr/local/x-ui
    /usr/bin/x-ui
    /usr/local/lib/3x-ui-pro
    /usr/local/lib/lucx-ui-pro
    /usr/local/sbin/lucx-apply-qdisc
    /usr/local/sbin/lucx-awg-sysctl-guard
    /etc/systemd/system/lucx-qdisc-sync.service
    /etc/systemd/system/lucx-qdisc-sync.path
    /etc/letsencrypt
    /var/lib/letsencrypt
    /var/log/letsencrypt
    /etc/sysctl.conf
    /root/cert
    /var/www/html
    /var/www/diagnostics
    /var/www/subpage
    /var/www/tproxy
    /root/.lucx-tg-web-proxy-info
    /var/lib/lucx-ui-preinstall
    /etc/sysctl.d/99-lucx-ui-forwarding.conf
    /etc/sysctl.d/99-bbr-x-ui.conf
    /etc/sysctl.d/99-awg-performance.conf
    /etc/sysctl.d/99-zz-lucx-ui-tuning.conf
    /etc/modules-load.d/lucx-ui-network.conf
    /etc/modules-load.d/amneziawg.conf
    /etc/modules-load.d/tcp-bbr.conf
    /etc/default/ufw
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    /etc/ufw/before.rules
    /etc/ufw/before6.rules
    /etc/ipset.conf
    /etc/iptables/ipsets
    /etc/rsyslog.d/10-iptables-scanners.conf
    /etc/logrotate.d/iptables-scanners
    /usr/local/bin/rkn-guard
    /usr/local/bin/rkn
    /usr/local/bin/antiscan-aggregate-logs.sh
    /opt/rkn-guard-manager.sh
    /opt/rkn-guard-manual.list
    /opt/AdGuardHome
    /root/.lucx-adguard-info
)
SYSTEMD_UNITS=(
    x-ui.service mtr-backend.service AdGuardHome.service fail2ban.service
    lucx-apply-qdisc.service
    lucx-qdisc-sync.service lucx-qdisc-sync.path
    lucx-awg-sysctl-guard.service lucx-awg-sysctl-guard.path
    antiscan-ipset-restore.service antiscan-move-rules.service
    antiscan-aggregate.service antiscan-aggregate.timer
    rkn-guard-list-update.service rkn-guard-list-update.timer
    rkn-guard-self-update.service rkn-guard-self-update.timer
)

# ── colours ───────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)"; }

# free space in KB on the filesystem containing $1
avail_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }

# staging must NOT live in /tmp: on Ubuntu 24.10+ /tmp is a size-limited tmpfs
# and a full uncompressed copy of the panel + web roots does not fit there
make_staging() {
    local prefix="$1"
    install -d -m 0700 "${BACKUP_STORE}"
    mktemp -d "${BACKUP_STORE}/.${prefix}-XXXXXX"
}

# Persist the module needed by the currently selected default qdisc. The
# panel owns the qdisc value; backup/restore only makes sure the kernel module
# required to honor that value is available again after reboot.
persist_current_qdisc_module() {
    local qdisc module file=/etc/modules-load.d/lucx-ui-network.conf
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    case "$qdisc" in
        fq)       module=sch_fq ;;
        fq_codel) module=sch_fq_codel ;;
        cake)     module=sch_cake ;;
        *)        module="" ;;
    esac
    [[ -n "$module" ]] || return 0
    modprobe "$module" >/dev/null 2>&1 || return 0
    mkdir -p /etc/modules-load.d
    touch "$file"
    if ! grep -Fxq "$module" "$file" 2>/dev/null; then
        printf '%s\n' "$module" >> "$file"
    fi
    chmod 0644 "$file"
}

# ── backup ────────────────────────────────────────────────────────────────────
cmd_backup() {
    require_root

    local ts name staging dest
    ts=$(date +%Y%m%d-%H%M%S)
    name="lucx-ui-backup-${ts}"

    # estimate size and verify free space before touching anything:
    # staging holds an uncompressed copy, the archive lands next to it
    local est_kb need_kb have_kb
    est_kb=$(du -skc "${BACKUP_PATHS[@]}" 2>/dev/null | awk 'END {print $1}')
    need_kb=$(( est_kb * 2 + 102400 ))   # copy + archive + 100 MB margin
    install -d -m 0700 "${BACKUP_STORE}"
    have_kb=$(avail_kb "${BACKUP_STORE}")
    (( have_kb >= need_kb )) || die "Not enough free space in ${BACKUP_STORE}: need ~$(( need_kb / 1024 )) MB, have $(( have_kb / 1024 )) MB"

    staging=$(make_staging staging)
    BACKUP_WAS_ACTIVE=0
    systemctl is-active --quiet x-ui && BACKUP_WAS_ACTIVE=1 || true
    backup_cleanup() {
        if (( BACKUP_WAS_ACTIVE )); then systemctl start x-ui 2>/dev/null || true; fi
        rm -rf -- "$BACKUP_STAGING"
        [[ ! -f "${BACKUP_DEST}.partial" ]] || rm -f -- "${BACKUP_DEST}.partial"
    }
    trap backup_cleanup EXIT

    dest="${BACKUP_STORE}/${name}.tar.gz"
    BACKUP_STAGING="$staging"
    BACKUP_DEST="$dest"

    blue "==> Stopping x-ui for consistent DB snapshot..."
    if (( BACKUP_WAS_ACTIVE )); then systemctl stop x-ui || die "Failed to stop x-ui for consistent backup"; fi

    : > "${staging}/services-state"
    local svc enabled active
    for svc in x-ui nginx mtr-backend AdGuardHome lucx-apply-qdisc lucx-qdisc-sync.path \
               lucx-awg-sysctl-guard.path antiscan-ipset-restore.service \
               antiscan-move-rules.service antiscan-aggregate.timer \
               rkn-guard-list-update.timer rkn-guard-self-update.timer; do
        enabled=0; active=0
        systemctl is-enabled --quiet "$svc" && enabled=1 || true
        systemctl is-active --quiet "$svc" && active=1 || true
        [[ "$svc" == x-ui ]] && active="$BACKUP_WAS_ACTIVE"
        printf '%s %s %s\n' "$svc" "$enabled" "$active" >> "${staging}/services-state"
    done
    ufw status 2>/dev/null | grep -q '^Status: active' && \
        printf 'active\n' > "${staging}/ufw-state" || \
        printf 'inactive\n' > "${staging}/ufw-state"

    # ── collect filesystem paths ───────────────────────────────────────────
    blue "==> Collecting files..."
    local files_root="${staging}/files"
    for path in "${BACKUP_PATHS[@]}"; do
        [[ -e "${path}" ]] || continue
        local dst="${files_root}${path}"
        mkdir -p "$(dirname "${dst}")"
        cp -a "${path}" "${dst}"
    done

    # systemd units
    mkdir -p "${files_root}/etc/systemd/system"
    for unit in "${SYSTEMD_UNITS[@]}"; do
        [[ -f "/etc/systemd/system/${unit}" ]] && \
            cp "/etc/systemd/system/${unit}" "${files_root}/etc/systemd/system/"
    done

    # ── crontab ───────────────────────────────────────────────────────────
    crontab -l 2>/dev/null > "${staging}/root-crontab" || true

    if [[ -d /etc/cron.d ]]; then
        cp -a /etc/cron.d "${staging}/cron.d"
    fi

    # ── metadata ──────────────────────────────────────────────────────────
    local xui_ver awg_installed
    xui_ver=$(x-ui version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    if modinfo amneziawg >/dev/null 2>&1 || [[ -f /etc/modules-load.d/amneziawg.conf ]] || [[ -f /etc/x-ui/.awg-module-version ]]; then
        awg_installed=1
    else
        awg_installed=0
    fi
    cat > "${staging}/meta.json" <<JSON
{
  "created":      "${ts}",
  "hostname":     "$(hostname -f 2>/dev/null || hostname)",
  "x-ui":         "${xui_ver}",
  "kernel":       "$(uname -r)",
  "awg_installed": ${awg_installed},
  "packages":     "${PACKAGES}"
}
JSON

    blue "==> Restarting x-ui..."
    if (( BACKUP_WAS_ACTIVE )); then systemctl start x-ui || die "Failed to restart x-ui"; fi

    # ── compress ──────────────────────────────────────────────────────────
    blue "==> Compressing..."
    tar -czf "${dest}.partial" -C "${staging}" .
    mv -f "${dest}.partial" "$dest"
    chmod 0600 "$dest"
    (cd "$BACKUP_STORE" && sha256sum "$(basename "$dest")" > "$(basename "$dest").sha256")

    local size
    size=$(du -sh "${dest}" | cut -f1)
    green "==> Backup saved: ${dest} (${size})"
}

# Keep the official AWG installer BBR-neutral, matching lucx-ui-pro latest.
patch_awg_installer() {
    local script=/usr/local/x-ui/bin/install-awg-module.sh
    [[ -f "$script" ]] || return 0
    python3 - "$script" <<'PY_AWG_RESTORE'
import re, sys
path=sys.argv[1]
text=open(path,encoding="utf-8",errors="surrogateescape").read()
text=re.sub(r'(?m)^\s*net\.core\.default_qdisc\s*=\s*fq\s*$\n?', '', text)
text=re.sub(r'(?m)^\s*net\.ipv4\.tcp_congestion_control\s*=\s*bbr\s*$\n?', '', text)
open(path,'w',encoding='utf-8',errors='surrogateescape').write(text)
PY_AWG_RESTORE
    chmod +x "$script" 2>/dev/null || true
}

setup_fail2ban() {
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        blue "==> XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}; skipping Fail2ban restore/setup."
        return 0
    fi

    if [[ ! -x /usr/bin/x-ui ]]; then
        blue "==> x-ui CLI not found; skipping Fail2ban restore/setup."
        return 0
    fi

    if ! grep -q '"setup-fail2ban")' /usr/bin/x-ui; then
        blue "==> This x-ui.sh predates 'x-ui setup-fail2ban'; skipping Fail2ban restore/setup."
        return 0
    fi

    blue "==> Restoring/configuring Fail2ban for the IP Limit feature..."
    if /usr/bin/x-ui setup-fail2ban; then
        green "    Fail2ban setup complete"
    else
        blue "    Fail2ban setup did not finish; continuing restore"
    fi
    return 0
}

sanitize_awg_sysctl_file() {
    local f=/etc/sysctl.d/99-awg-performance.conf
    [[ -f "$f" ]] || return 0
    sed -i -E \
        -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
        -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
        "$f" || true
    if [[ -f /etc/sysctl.d/99-bbr-x-ui.conf ]]; then
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf >/dev/null 2>&1 || true
    fi
}

patch_panel_awg_command() {
    local script
    for script in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
        [[ -f "$script" ]] || continue
        python3 - "$script" <<'PY_AWG_CMD_RESTORE'
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
PY_AWG_CMD_RESTORE
        chmod +x "$script" 2>/dev/null || true
    done
}

restore_awg_module() {
    local script=/usr/local/x-ui/bin/install-awg-module.sh
    local want_awg="${1:-0}"
    if [[ "$want_awg" != "1" ]]; then
        # A backup can be restored onto a host that currently has AWG even
        # though the backup itself did not. Make the restored state truthful.
        if [[ -x "$script" ]]; then
            blue "==> Backup has no AmneziaWG; removing any existing AWG module/tools..."
            bash "$script" --uninstall >/dev/null 2>&1 || true
        else
            rmmod amneziawg >/dev/null 2>&1 || true
            if command -v dkms >/dev/null 2>&1; then
                while read -r ver; do
                    [[ -n "$ver" ]] || continue
                    dkms remove -m amneziawg -v "$ver" --all >/dev/null 2>&1 || true
                done < <(dkms status amneziawg 2>/dev/null | grep -oP 'amneziawg[,/] ?\K[^,]+' | sort -u || true)
            fi
            rm -rf /usr/src/amneziawg-* /var/lib/dkms/amneziawg
            rm -f /usr/bin/awg /usr/bin/awg-quick /usr/local/bin/awg /usr/local/bin/awg-quick \
                  /usr/sbin/awg /usr/sbin/awg-quick /usr/local/sbin/awg /usr/local/sbin/awg-quick \
                  /etc/modules-load.d/amneziawg.conf /etc/sysctl.d/99-awg-performance.conf \
                  /etc/x-ui/.awg-module-version /etc/x-ui/.awg-reboot-needed
            update-initramfs -u -k all >/dev/null 2>&1 || update-initramfs -u >/dev/null 2>&1 || true
        fi
        return 0
    fi
    [[ -x "$script" ]] || return 0
    patch_awg_installer
    # A restored marker without the actual module would make the upstream
    # installer incorrectly skip DKMS. Remove the marker in that case.
    if ! modinfo amneziawg >/dev/null 2>&1; then
        rm -f /etc/x-ui/.awg-module-version
    fi
    echo "==> Restoring/building AmneziaWG module..."
    bash "$script" --no-kernel-upgrade >/dev/null 2>&1 || true
    patch_awg_installer
    for script in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
        [[ -f "$script" ]] || continue
        python3 - "$script" <<'PY_BBR_RESTORE_PATCH'
import sys
path=sys.argv[1]
text=open(path,encoding="utf-8",errors="surrogateescape").read()
old="""enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then"""
new="""enable_bbr() {
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
PY_BBR_RESTORE_PATCH
        chmod +x "$script" 2>/dev/null || true
    done
    if [[ -f /etc/sysctl.d/99-awg-performance.conf ]] && grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$|^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' /etc/sysctl.d/99-awg-performance.conf; then
        sed -i -E \
            -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
            -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
            /etc/sysctl.d/99-awg-performance.conf || true
    fi
}

# Validate the complete gzip/tar stream and its member names before extraction.
# The sidecar checksum detects corruption; it is not an authenticity signature.
verify_backup_archive() {
    local file="$1" checksum="${1}.sha256"
    [[ -s "$checksum" ]] || die "Missing archive checksum: $checksum"
    (cd "$(dirname "$file")" && sha256sum -c --status "$(basename "$checksum")") || die "Backup checksum mismatch"
    python3 - "$file" <<'PY_VERIFY_ARCHIVE' || die "Invalid or unsafe backup archive"
import json, pathlib, sys, tarfile
archive = pathlib.Path(sys.argv[1])
allowed = [p.lstrip('/') for p in ['/etc/nginx', '/etc/x-ui', '/etc/default/x-ui', '/etc/fail2ban', '/etc/cron.d', '/usr/local/x-ui', '/usr/bin/x-ui', '/usr/local/lib/3x-ui-pro', '/usr/local/lib/lucx-ui-pro', '/usr/local/sbin/lucx-apply-qdisc', '/usr/local/sbin/lucx-awg-sysctl-guard', '/etc/systemd/system', '/etc/letsencrypt', '/var/lib/letsencrypt', '/var/log/letsencrypt', '/etc/sysctl.conf', '/root/cert', '/var/www/html', '/var/www/diagnostics', '/var/www/subpage', '/var/www/tproxy', '/root/.lucx-tg-web-proxy-info', '/var/lib/lucx-ui-preinstall', '/etc/sysctl.d/99-lucx-ui-forwarding.conf', '/etc/sysctl.d/99-bbr-x-ui.conf', '/etc/sysctl.d/99-awg-performance.conf', '/etc/sysctl.d/99-zz-lucx-ui-tuning.conf', '/etc/modules-load.d/lucx-ui-network.conf', '/etc/modules-load.d/amneziawg.conf', '/etc/modules-load.d/tcp-bbr.conf', '/etc/default/ufw', '/etc/ufw/user.rules', '/etc/ufw/user6.rules', '/etc/ufw/before.rules', '/etc/ufw/before6.rules', '/etc/ipset.conf', '/etc/iptables/ipsets', '/etc/rsyslog.d/10-iptables-scanners.conf', '/etc/logrotate.d/iptables-scanners', '/usr/local/bin/rkn-guard', '/usr/local/bin/rkn', '/usr/local/bin/antiscan-aggregate-logs.sh', '/opt/rkn-guard-manager.sh', '/opt/rkn-guard-manual.list', '/opt/AdGuardHome', '/root/.lucx-adguard-info']]
seen, links = set(), set()
try:
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()  # reads the complete gzip stream and CRC
        assert len(members) <= 200000
        assert any(m.name.lstrip('./') == 'meta.json' for m in members)
        assert any(m.name.lstrip('./') == 'files/etc/x-ui/x-ui.db' for m in members)
        for m in members:
            name = m.name
            parts = pathlib.PurePosixPath(name).parts
            assert not name.startswith('/') and '..' not in parts and '\\' not in name
            norm = name.lstrip('./').rstrip('/')
            assert norm not in seen or norm == ''
            seen.add(norm)
            assert m.isfile() or m.isdir() or m.issym()
            assert m.size <= 16 * 1024**3
            assert norm in ('', 'files', 'meta.json', 'root-crontab', 'cron.d', 'services-state', 'ufw-state') or \
                norm.startswith('cron.d/') or \
                (norm.startswith('files/') and any(norm[6:] == p or norm[6:].startswith(p + '/') for p in allowed))
            if m.issym():
                links.add(norm)
        assert all(not any(n.startswith(link + '/') for link in links) for n in seen)
        meta = tar.extractfile(next(m for m in members if m.name.lstrip('./') == 'meta.json'))
        assert isinstance(json.load(meta), dict)
        print(sum(m.size for m in members))
except (OSError, tarfile.TarError, ValueError, AssertionError, StopIteration) as exc:
    sys.exit(f'Archive validation failed: {exc}')
PY_VERIFY_ARCHIVE
}

# ── restore ───────────────────────────────────────────────────────────────────
cmd_restore() {
    require_root

    local backup_file="${1:-}"
    [[ -n "${backup_file}" ]] || die "Usage: $0 restore <backup.tar.gz>"
    [[ -f "${backup_file}" ]]  || die "File not found: ${backup_file}"

    local unpacked_bytes
    unpacked_bytes=$(verify_backup_archive "$backup_file")

    # verify free space for the extracted copy before unpacking
    local unpacked_kb have_kb
    unpacked_kb=$(( (unpacked_bytes + 1023) / 1024 ))
    mkdir -p "${BACKUP_STORE}"
    have_kb=$(avail_kb "${BACKUP_STORE}")
    (( have_kb >= unpacked_kb * 2 + 102400 )) || \
        die "Not enough free space in ${BACKUP_STORE}: need ~$(( (unpacked_kb * 2 + 102400) / 1024 )) MB, have $(( have_kb / 1024 )) MB"

    local staging awg_installed_from_backup=0
    staging=$(make_staging restore)
    RESTORE_STAGING="$staging"
    trap 'rm -rf -- "$RESTORE_STAGING"' EXIT

    blue "==> Extracting backup: ${backup_file}"
    tar -xzf "${backup_file}" -C "${staging}"

    if [[ -f "${staging}/meta.json" ]]; then
        blue "==> Backup metadata:"
        cat "${staging}/meta.json"
        awg_installed_from_backup=$(python3 - "${staging}/meta.json" <<'PY_META_AWG'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(1 if json.load(f).get('awg_installed') else 0)
except Exception:
    print(0)
PY_META_AWG
)
    fi
    # Backward compatibility: old backups have no awg_installed field. Infer
    # installation from the persisted AWG module marker/config when present.
    if [[ "$awg_installed_from_backup" != "1" ]]; then
        [[ -e "${staging}/files/etc/modules-load.d/amneziawg.conf" || -e "${staging}/files/etc/x-ui/.awg-module-version" ]] && awg_installed_from_backup=1
    fi
    echo

    # ── install packages ──────────────────────────────────────────────────
    blue "==> Installing packages..."
    apt-get update -qq
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGES}

    # ── stop running services ─────────────────────────────────────────────
    blue "==> Stopping services..."
    for svc in nginx x-ui mtr-backend AdGuardHome lucx-apply-qdisc lucx-qdisc-sync lucx-qdisc-sync.path lucx-awg-sysctl-guard lucx-awg-sysctl-guard.path; do
        systemctl stop "${svc}" 2>/dev/null || true
    done

    # ── restore files ─────────────────────────────────────────────────────
    blue "==> Restoring files..."
    if [[ -d "${staging}/files" ]]; then
        # Save certificates from the archive separately. A restore on the
        # same VPS must not replace certificates renewed since the backup.
        mkdir -p "${staging}/saved-certs/etc" "${staging}/saved-certs/var/lib" \
                 "${staging}/saved-certs/var/log" "${staging}/saved-certs/root"
        local cert_path
        for cert_path in etc/letsencrypt var/lib/letsencrypt var/log/letsencrypt root/cert; do
            if [[ -e "${staging}/files/${cert_path}" ]]; then
                mv "${staging}/files/${cert_path}" "${staging}/saved-certs/${cert_path}"
            fi
        done
        cp -a "${staging}/files/." /
        # Fill missing entries from the archive, retaining every certificate
        # and renewal file that already exists on this server.
        cp -an "${staging}/saved-certs/." /
    fi

    # ── permissions ───────────────────────────────────────────────────────
    chown -R www-data:www-data /var/www/html        2>/dev/null || true
    chown -R www-data:www-data /var/www/diagnostics 2>/dev/null || true
    chown -R www-data:www-data /var/www/subpage     2>/dev/null || true
    [[ -f /usr/local/x-ui/x-ui ]] && chmod +x /usr/local/x-ui/x-ui
    [[ -f /usr/bin/x-ui ]]        && chmod +x /usr/bin/x-ui
    [[ -f /usr/local/bin/rkn-guard ]] && chmod +x /usr/local/bin/rkn-guard
    [[ -f /usr/local/bin/rkn ]]       && chmod +x /usr/local/bin/rkn
    [[ -f /usr/local/bin/antiscan-aggregate-logs.sh ]] && chmod +x /usr/local/bin/antiscan-aggregate-logs.sh
    [[ -f /opt/rkn-guard-manager.sh ]] && chmod +x /opt/rkn-guard-manager.sh
    [[ -f /usr/local/sbin/lucx-apply-qdisc ]] && chmod +x /usr/local/sbin/lucx-apply-qdisc
    find /usr/local/lib/3x-ui-pro -name "*.py" -exec chmod +x {} \; 2>/dev/null || true
    find /usr/local/lib/lucx-ui-pro -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

    # Reconcile Fail2ban through the panel CLI. This keeps the restored jail/filter/action
    # format aligned with the x-ui version instead of treating copied files as authoritative.
    setup_fail2ban || true
    patch_panel_awg_command
    sanitize_awg_sysctl_file

    # ── panel cert symlinks (/root/cert/<domain> → letsencrypt) ──────────
    # Backups made before /root/cert was in BACKUP_PATHS lack the symlinks
    # the panel's webCertFile points to — without them x-ui serves plain
    # HTTP and every nginx proxy_pass https:// (panel) breaks.
    # Recreate them from the restored DB ("-e" follows symlinks, so a
    # dangling link reads as missing).
    local db=/etc/x-ui/x-ui.db web_cert cert_domain
    if [[ -f "${db}" ]] && command -v sqlite3 &>/dev/null; then
        web_cert=$(sqlite3 "${db}" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || true)
        if [[ "${web_cert}" =~ ^/root/cert/([^/]+)/ ]]; then
            cert_domain="${BASH_REMATCH[1]}"
            if [[ ! -e "${web_cert}" && -d "/etc/letsencrypt/live/${cert_domain}" ]]; then
                blue "==> Recreating panel cert symlinks in /root/cert/${cert_domain}..."
                mkdir -p "/root/cert/${cert_domain}"
                chmod 755 /root/cert/* 2>/dev/null || true
                [[ -e "/root/cert/${cert_domain}/fullchain.pem" || -L "/root/cert/${cert_domain}/fullchain.pem" ]] || \
                    ln -s "/etc/letsencrypt/live/${cert_domain}/fullchain.pem" "/root/cert/${cert_domain}/fullchain.pem"
                [[ -e "/root/cert/${cert_domain}/privkey.pem" || -L "/root/cert/${cert_domain}/privkey.pem" ]] || \
                    ln -s "/etc/letsencrypt/live/${cert_domain}/privkey.pem" "/root/cert/${cert_domain}/privkey.pem"
            fi
        fi
    fi

    # Recreate Telegram WEB-proxy certificate links from its inbound settings.
    if [[ -f "${db}" ]] && command -v sqlite3 &>/dev/null; then
        while IFS= read -r cert_domain; do
            [[ -n "${cert_domain}" && -d "/etc/letsencrypt/live/${cert_domain}" ]] || continue
            mkdir -p "/root/cert/${cert_domain}"
            [[ -e "/root/cert/${cert_domain}/fullchain.pem" || -L "/root/cert/${cert_domain}/fullchain.pem" ]] || \
                ln -s "/etc/letsencrypt/live/${cert_domain}/fullchain.pem" "/root/cert/${cert_domain}/fullchain.pem"
            [[ -e "/root/cert/${cert_domain}/privkey.pem" || -L "/root/cert/${cert_domain}/privkey.pem" ]] || \
                ln -s "/etc/letsencrypt/live/${cert_domain}/privkey.pem" "/root/cert/${cert_domain}/privkey.pem"
        done < <(python3 - "${db}" <<'PY_TG_RESTORE'
import json, sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1], timeout=10)
    rows = con.execute("SELECT id, settings FROM inbounds WHERE protocol='tproxy' OR tag='inbound-tproxy'").fetchall()
    for inbound_id, raw in rows:
        value = json.loads(raw or "{}")
        value["siteSource"] = "dir"
        value["siteDir"] = "/var/www/html"
        con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(value, ensure_ascii=False), inbound_id))
        host = value.get("hostname", "")
        if host:
            print(host)
    con.commit()
    con.close()
except Exception:
    pass
PY_TG_RESTORE
)
    fi

    # ── recreate mtr-backend system user if missing ───────────────────────
    id mtr-backend &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    # grant mtr net_raw capability
    if command -v setcap &>/dev/null && command -v mtr &>/dev/null; then
        setcap cap_net_raw+ep "$(command -v mtr)" 2>/dev/null || true
    fi

    # ── AmneziaWG / AWG-specific sysctl ──────────────────────────────────
    restore_awg_module "${awg_installed_from_backup}"

    # ── network tuning / modules ─────────────────────────────────────────
    # The panel owns persistent BBR/FQ sysctl state in 99-bbr-x-ui.conf.
    # Pro owns kernel-module loading/persistence. Load restored modules before
    # applying the panel sysctl file so BBR/fq can be activated after reboot.
    if [[ -f /etc/modules-load.d/lucx-ui-network.conf ]]; then
        while IFS= read -r module; do
            [[ -n "$module" && "$module" != \#* ]] || continue
            modprobe "$module" >/dev/null 2>&1 || true
        done < /etc/modules-load.d/lucx-ui-network.conf
    fi
    # Compatibility with backups created by older Pro releases. Migrate the
    # old module filename into the current combined module file when possible.
    if [[ -f /etc/modules-load.d/tcp-bbr.conf ]]; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        if [[ ! -f /etc/modules-load.d/lucx-ui-network.conf ]]; then
            if modprobe sch_fq >/dev/null 2>&1; then
                printf '%s\n' tcp_bbr sch_fq > /etc/modules-load.d/lucx-ui-network.conf
            else
                printf '%s\n' tcp_bbr > /etc/modules-load.d/lucx-ui-network.conf
            fi
            chmod 0644 /etc/modules-load.d/lucx-ui-network.conf
        fi
    fi

    restore_unit_state() {
        local unit="$1" saved_en saved_active
        if [[ -f "${staging}/services-state" ]]; then
            read -r saved_en saved_active < <(awk -v u="$unit" '$1==u {print $2, $3; exit}' "${staging}/services-state")
            [[ "$saved_en" == 1 ]] && systemctl enable "$unit" 2>/dev/null || systemctl disable "$unit" 2>/dev/null || true
            [[ "$saved_active" == 1 ]] && systemctl start "$unit" 2>/dev/null || systemctl stop "$unit" 2>/dev/null || true
        else
            systemctl enable "$unit" 2>/dev/null || true
            systemctl start "$unit" 2>/dev/null || true
        fi
    }

    # ── systemd ───────────────────────────────────────────────────────────
    blue "==> Enabling and starting services..."
    systemctl daemon-reload

    for svc in x-ui mtr-backend AdGuardHome lucx-apply-qdisc; do
        restore_unit_state "$svc"
    done
    if [[ -f /etc/systemd/system/lucx-qdisc-sync.path ]]; then
        restore_unit_state lucx-qdisc-sync.path
    fi
    if [[ -f /etc/systemd/system/lucx-awg-sysctl-guard.path ]]; then
        restore_unit_state lucx-awg-sysctl-guard.path
    fi

    # Restore rkn-guard runtime units and LucX automatic-update timers when present.
    if [[ -x /usr/local/bin/rkn-guard ]]; then
        for unit in antiscan-ipset-restore.service antiscan-move-rules.service antiscan-aggregate.timer; do
            [[ -f "/etc/systemd/system/${unit}" ]] || continue
            restore_unit_state "$unit"
        done
        for timer in rkn-guard-list-update.timer rkn-guard-self-update.timer; do
            [[ -f "/etc/systemd/system/${timer}" ]] || continue
            restore_unit_state "$timer"
        done
    fi

    # nginx: test config before starting
    if nginx -t 2>/dev/null; then
        restore_unit_state nginx
        green "    nginx state restored"
    else
        red "    nginx config test failed — fix manually:"
        nginx -t
    fi

    # ── crontab ───────────────────────────────────────────────────────────
    blue "==> Restoring cron..."
    if [[ -s "${staging}/root-crontab" ]]; then
        crontab - < "${staging}/root-crontab"
        green "    Root crontab restored"
    fi

    if [[ -d "${staging}/cron.d" ]]; then
        cp -a "${staging}/cron.d/." /etc/cron.d/
        green "    /etc/cron.d restored"
    fi

    # ── UFW ───────────────────────────────────────────────────────────────
    blue "==> Restoring UFW..."
    if [[ -f /etc/sysctl.d/99-lucx-ui-forwarding.conf ]]; then
        sysctl -p /etc/sysctl.d/99-lucx-ui-forwarding.conf >/dev/null 2>&1 || true
    fi
    if [[ -f /etc/sysctl.d/99-zz-lucx-ui-tuning.conf ]]; then
        # Backups from older Pro releases may contain BBR/FQ keys here. If the
        # panel-owned file is absent, migrate an old BBR+fq state into it before
        # stripping those keys from the legacy Pro file.
        if [[ ! -f /etc/sysctl.d/99-bbr-x-ui.conf ]]; then
            legacy_cc=$(awk -F= '$1 ~ /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /etc/sysctl.d/99-zz-lucx-ui-tuning.conf || true)
            legacy_qdisc=$(awk -F= '$1 ~ /^[[:space:]]*net\.core\.default_qdisc[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /etc/sysctl.d/99-zz-lucx-ui-tuning.conf || true)
            if [[ "$legacy_cc" == "bbr" && "$legacy_qdisc" == "fq" ]]; then
                {
                    echo "#fq_codel:cubic"
                    echo "net.core.default_qdisc = fq"
                    echo "net.ipv4.tcp_congestion_control = bbr"
                } > /etc/sysctl.d/99-bbr-x-ui.conf
                chmod 0644 /etc/sysctl.d/99-bbr-x-ui.conf
            fi
        fi
        # Keep only non-BBR tuning so the panel remains the sole owner of those keys.
        sed -i -E \
            -e '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' \
            -e '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' \
            /etc/sysctl.d/99-zz-lucx-ui-tuning.conf || true
        sysctl -p /etc/sysctl.d/99-zz-lucx-ui-tuning.conf >/dev/null 2>&1 || true
    fi
    if [[ -f /etc/sysctl.d/99-bbr-x-ui.conf ]]; then
        # Use the panel-owned file exactly as the panel does.
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf >/dev/null 2>&1 || true
    fi
    modprobe sch_fq_codel >/dev/null 2>&1 || true
    persist_current_qdisc_module
    # The qdisc helper must see the restored panel-owned default_qdisc, not the
    # pre-restore runtime value. Re-run it after all sysctl files are applied.
    if [[ -f /etc/systemd/system/lucx-apply-qdisc.service ]]; then
        systemctl restart lucx-apply-qdisc 2>/dev/null || true
    fi
    # Restore saved UFW policy without changing its routed-traffic default.
    if [[ -f "${staging}/ufw-state" ]] && grep -qx inactive "${staging}/ufw-state"; then
        ufw --force disable 2>/dev/null || true
    else
        ufw --force enable 2>/dev/null || true
    fi
    green "    UFW state restored"

    echo
    green "==> Restore complete."
    green "    Check status with:"
    green "      systemctl status x-ui nginx"
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
    if [[ ! -d "${BACKUP_STORE}" ]]; then
        echo "No backups found (${BACKUP_STORE} does not exist)"
        return
    fi

    local archives
    mapfile -t archives < <(ls -t "${BACKUP_STORE}"/*.tar.gz 2>/dev/null)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No backups in ${BACKUP_STORE}"
        return
    fi

    blue "Backups in ${BACKUP_STORE}:"
    for f in "${archives[@]}"; do
        printf "  %-55s  %s\n" "$(basename "${f}")" "$(du -sh "${f}" | cut -f1)"
    done
}

# ── entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
    backup)  cmd_backup ;;
    restore) cmd_restore "${2:-}" ;;
    list)    cmd_list ;;
    *)
        cat <<EOF
Usage: $(basename "$0") {backup|restore <file>|list}

  backup            create timestamped backup in ${BACKUP_STORE}/
  restore <file>    restore from backup archive (installs packages first)
  list              list available backups

What is backed up:
  /etc/nginx                      nginx config
  /etc/x-ui                       panel DB + config
  /usr/local/x-ui                 panel binary + xray core
  /usr/bin/x-ui                   x-ui management CLI
  /usr/local/lib/3x-ui-pro        optional helper scripts
  /usr/local/lib/lucx-ui-pro      rkn-guard automatic-update scripts
  /usr/local/sbin/lucx-apply-qdisc  network qdisc helper
  /etc/letsencrypt                SSL certificates
  /root/cert                      panel cert symlinks
  /var/www/{html,diagnostics,subpage}  web content (shared cover in html)
  Telegram WEB-proxy domain, certificate and inbound (inside x-ui DB)
  /opt/AdGuardHome                self-hosted DoH (if installed)
  rkn-guard binary, manager, ipset/UFW state and update timers
  /var/lib/lucx-ui-preinstall     pre-install firewall snapshot
  /etc/sysctl.d/99-lucx-ui-forwarding.conf  persistent IPv4 forwarding
  relevant services and timers from /etc/systemd/system
  /etc/default/ufw + /etc/ufw/{user,before}*.rules  firewall policy/rules
  root crontab + /etc/cron.d/
EOF
        exit 1
        ;;
esac
