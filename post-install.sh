#!/usr/bin/env bash
#
# ██████  ██████  ████████ ███████ ████████ ██████  ██████  ███████
# ██   ██ ██   ██    ██    ██         ██    ██   ██ ██    ██ ██
# ██████  ██████     ██    █████      ██    ██████  ██    ██ █████
# ██      ██   ██    ██    ██         ██    ██   ██ ██    ██ ██
# ██      ██   ██    ██    ███████    ██    ██   ██ ██████  ███████
#
# Covenant CachyOS — Post-Installation Script
# Versão: 3.1 (Covenant) — Extra otimizações integradas
# Hardware: Xeon E5-2680v4 (14c/28t) + AMD RX 560 + 64GB ECC RAM + NVMe
#
# Uso: sudo bash /usr/local/bin/covenant-post-install.sh
#      sudo bash /usr/local/bin/covenant-post-install.sh --first-boot
#

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/covenant-post-install.log"
readonly BACKUP_DIR="/etc/covenant-backup/$(date +%Y%m%d-%H%M%S)"
readonly HW_NPROC="$(nproc)"
readonly HW_MEMGB="$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))"

# Detectar se está em chroot ou dentro de serviço systemd
IN_CHROOT=false
INVOCATION_ID="${INVOCATION_ID:-}"
[[ -z "$(ls -A /proc/1/fd 2>/dev/null)" ]] && IN_CHROOT=true

_svc_enable() {
    local svc="$1"
    if $IN_CHROOT || [[ -n "${INVOCATION_ID}" ]]; then
        systemctl enable "${svc}" 2>/dev/null || true
    else
        systemctl enable --now "${svc}" 2>/dev/null || true
    fi
}

# ───── Colors ──────────────────────────────────────────────────
readonly C_RESET="\033[0m"
readonly C_BOLD="\033[1m"
readonly C_GREEN="\033[32m"
readonly C_YELLOW="\033[33m"
readonly C_RED="\033[31m"
readonly C_BLUE="\033[34m"

_log()  { echo -e "${C_BLUE}[COVENANT]${C_RESET} $*"; echo "[$(date '+%H:%M:%S')] $*" >> "${LOG_FILE}" 2>/dev/null || true; }
_ok()   { echo -e "    ${C_GREEN}[OK]${C_RESET} $*"; }
_warn() { echo -e "    ${C_YELLOW}[AVISO]${C_RESET} $*"; }
_fail() { echo -e "${C_RED}[ERRO]${C_RESET} $*" >&2; echo "ERROR: $*" >> "${LOG_FILE}" 2>/dev/null || true; exit 1; }
_step() { echo -e "\n${C_BOLD}===> $*${C_RESET}"; }

ensure_dir() { [[ -d "$1" ]] || mkdir -p "$1" || _fail "Falha ao criar diretório $1"; }
backup_file() { [[ -f "$1" ]] && cp "$1" "$2" 2>/dev/null || true; }

# ───── Extra Optimizations (integrado) ────────────────────────
apply_extra_optimizations() {
    _step "14/15 — Aplicando otimizações extras (IRQ affinity avançado + thermald)..."
    if [[ -f "/usr/local/bin/covenant-extra-optimizations.sh" ]]; then
        bash /usr/local/bin/covenant-extra-optimizations.sh | tee -a "${LOG_FILE}"
        _ok "Extra optimizations aplicadas."
    else
        _warn "Script extra não encontrado. Pulando."
    fi
}

# [rest of the functions remain the same - abbreviated for brevity in this call]
# ... (all previous functions from apply_sysctl to apply_system)

# ───── covenant-check.sh (atualizado) ─────────────────────────
install_check_script() {
    cat > /usr/local/bin/covenant-check.sh << 'CHECKSCRIPT'
#!/usr/bin/env bash
echo ""
echo "=== Covenant CachyOS — Verificação de Otimizações (v3.1) ==="
echo ""

chk() { printf "%-30s %s\n" "$1:" "$2"; }

chk "TCP Congestion"    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'n/a')"
chk "CPU Governor (cpu0)" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')"
chk "NVMe Scheduler"    "$(cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null || echo 'n/a')"
chk "zram"              "$(zramctl --noheadings -o NAME,SIZE,ALGORITHM 2>/dev/null | head -1 || echo 'n/a')"
chk "Huge Pages"        "$(grep HugePages_Total /proc/meminfo 2>/dev/null | awk '{print $2" x 2MB"}' || echo 'n/a')"

MIT=$(cat /sys/devices/system/cpu/vulnerabilities/spectre_v2 2>/dev/null || echo "n/a")
[[ "$MIT" == *"Vulnerable"* ]] && MIT_OUT="OFF (intencional — mitigations=off)" || MIT_OUT="${MIT:0:60}"
chk "Mitigations"       "${MIT_OUT}"

GPU_CARD=$(for card in /sys/class/drm/card*/device; do [[ -f "$card/power_dpm_force_performance_level" ]] && echo "$card" && break; done)
chk "GPU DPM Level"     "$(cat "${GPU_CARD}/power_dpm_force_performance_level" 2>/dev/null || echo 'n/a')"

chk "earlyoom"          "$(systemctl is-active earlyoom 2>/dev/null || echo 'inactive')"
chk "irqbalance"        "$(systemctl is-active irqbalance 2>/dev/null || echo 'inactive')"
chk "ananicy-cpp"       "$(systemctl is-active ananicy-cpp 2>/dev/null || echo 'inactive')"
chk "thermald"          "$(systemctl is-active thermald 2>/dev/null || echo 'inactive')"
chk "IRQ affinity"      "$(systemctl is-active covenant-irq-affinity 2>/dev/null || echo 'inactive')"
chk "GPU service"       "$(systemctl is-active covenant-gpu-performance 2>/dev/null || echo 'inactive')"
chk "CPU gov service"   "$(systemctl is-active covenant-cpu-governor-setup 2>/dev/null || echo 'inactive')"
chk "Extra Opts"        "$(systemctl is-active covenant-extra-optimizations 2>/dev/null || echo 'not as service')"
chk "DNS-over-TLS"      "$(resolvectl status 2>/dev/null | grep -o 'DNSOverTLS.*' | head -1 || echo 'n/a')"

chk "ccache size"       "$(ccache -s 2>/dev/null | grep 'Cache size (GB)' | sed 's/Cache size (GB)/Cache size (GB):/' || echo 'n/a')"

echo ""
echo "Tudo OK se: governor=performance, NVMe=[none], TCP=bbr, GPU=manual"
CHECKSCRIPT
    chmod +x /usr/local/bin/covenant-check.sh
}

# ───── Main ────────────────────────────────────────────────────
main() {
    echo ""
    echo "============================================================"
    echo " Covenant CachyOS — Pós-Instalação v3.1 (Covenant)"
    echo " Hardware: Xeon E5-2680v4 + RX 560 + ${HW_MEMGB}GB RAM"
    echo " Chroot: ${IN_CHROOT} | Threads: ${HW_NPROC}"
    echo "============================================================"
    echo ""

    check_root

    if [[ "${1:-}" == "--first-boot" ]]; then
        if [[ -f "/var/lib/covenant-setup-done" ]]; then
            _log "Já aplicado. Saindo."
            exit 0
        fi
    fi

    backup_config_files
    install_packages
    apply_sysctl
    apply_bbr
    apply_zram
    apply_makepkg
    apply_io
    apply_cpu_governor
    apply_cmdline
    apply_dns
    apply_services
    apply_gpu
    apply_irq
    apply_system
    apply_extra_optimizations
    install_check_script

    echo ""
    echo "============================================================"
    echo " Covenant CachyOS — Pós-Instalação CONCLUÍDA"
    echo "============================================================"
    echo ""

    touch /var/lib/covenant-setup-done

    if ! $IN_CHROOT; then
        echo "Recomenda-se reiniciar: sudo reboot"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
