#!/usr/bin/env bash
#
# ██████  ██████  ████████ ███████ ████████ ██████  ██████  ███████
# ██   ██ ██   ██    ██    ██         ██    ██   ██ ██    ██ ██
# ██████  ██████     ██    █████      ██    ██████  ██    ██ █████
# ██      ██   ██    ██    ██         ██    ██   ██ ██    ██ ██
# ██      ██   ██    ██    ███████    ██    ██   ██ ██████  ███████
#
# Covenant CachyOS — Post-Installation Script
# Versão: 3.0 (junho/2026)
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

# ───── 0. Verificações iniciais ────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && _fail "Execute como root: sudo bash $SCRIPT_NAME"
    ensure_dir "/var/log"
    touch "${LOG_FILE}" && chmod 644 "${LOG_FILE}"
    _log "Covenant Post-Install v3.0 iniciado (chroot=${IN_CHROOT}, NPROC=${HW_NPROC}, RAM=${HW_MEMGB}GB)"
}

# ───── 1. Backup ───────────────────────────────────────────────
backup_config_files() {
    _step "1/14 — Backup das configurações originais..."
    ensure_dir "${BACKUP_DIR}/etc/default"
    ensure_dir "${BACKUP_DIR}/etc/sysctl.d"
    ensure_dir "${BACKUP_DIR}/etc/systemd"

    local files=(
        "/etc/default/grub"
        "/etc/fstab"
        "/etc/sysctl.conf"
        "/etc/systemd/zram-generator.conf"
        "/etc/security/limits.conf"
        "/etc/pacman.conf"
        "/etc/makepkg.conf"
    )
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && cp --parents "$f" "${BACKUP_DIR}" 2>/dev/null || true
    done
    _ok "Backup em ${BACKUP_DIR}"
}

# ───── 2. Pacotes de performance ───────────────────────────────
install_packages() {
    _step "2/14 — Pacotes de performance..."
    local PERF_PKGS=(irqbalance zram-generator ananicy-cpp earlyoom ccache
                     profile-sync-daemon thermald cpupower)
    local missing=()
    for pkg in "${PERF_PKGS[@]}"; do
        pacman -Qi "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        _log "Instalando: ${missing[*]}"
        for i in $(seq 1 6); do
            ping -c1 -W3 archlinux.org &>/dev/null && break
            _warn "Aguardando rede... ($i/6)"; sleep 5
        done
        pacman -Sy --noconfirm 2>/dev/null || true
        for pkg in "${missing[@]}"; do
            pacman -S --needed --noconfirm "$pkg" 2>/dev/null \
                || _warn "$pkg — conflito ou indisponível, pulando."
        done
    fi
    _ok "Pacotes verificados."
}

# ───── 3. sysctl ───────────────────────────────────────────────
apply_sysctl() {
    _step "3/14 — sysctl (BBR, rede, VM, hugepages)..."
    ensure_dir "/etc/sysctl.d"
    cat > /etc/sysctl.d/90-covenant.conf << 'SYSCTL'
# ──── Covenant CachyOS — sysctl ────

# Virtual Memory
vm.swappiness = 1
vm.dirty_ratio = 80
vm.dirty_background_ratio = 15
vm.vfs_cache_pressure = 50
vm.dirty_expire_centisecs = 6000
vm.nr_hugepages = 1024

# Filesystem
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# Network
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15

# Security (performance)
kernel.kptr_restrict = 0
kernel.dmesg_restrict = 0
SYSCTL
    sysctl -p /etc/sysctl.d/90-covenant.conf >/dev/null 2>&1 || true
    _ok "sysctl aplicado."
}

# ───── 4. BBR module ───────────────────────────────────────────
apply_bbr() {
    _step "4/14 — Módulo BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
    _ok "BBR."
}

# ───── 5. zram ─────────────────────────────────────────────────
apply_zram() {
    _step "5/14 — zram 1GB zstd..."
    ensure_dir "/etc/systemd"
    cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = 1024
compression-algorithm = zstd
swap-priority = 100
ZRAM
    _ok "zram 1GB."
}

# ───── 6. makepkg ──────────────────────────────────────────────
apply_makepkg() {
    _step "6/14 — makepkg.conf..."
    local MAKEPKG="/etc/makepkg.conf"
    if [[ -f "$MAKEPKG" ]]; then
        backup_file "$MAKEPKG" "${BACKUP_DIR}/etc/makepkg.conf.bak"
        cat > /tmp/_covenant_makepkg.py << 'MKPKG_PY'
import re, subprocess
makepkg = "/etc/makepkg.conf"
with open(makepkg) as f:
    c = f.read()
nproc = subprocess.check_output(["nproc"]).decode().strip()
flags = (
    "#-- Compiler and Linker Flags\n"
    'CPPFLAGS="-D_FORTIFY_SOURCE=3"\n'
    'CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions \\\n'
    "        -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer \\\n"
    "        -fstack-clash-protection -fcf-protection \\\n"
    "        -fstack-protector-strong \\\n"
    "        -fstrict-flex-arrays=3 \\\n"
    '        -Wformat -Werror=format-security"\n'
    'CXXFLAGS="$CFLAGS -D_GLIBCXX_ASSERTIONS"\n'
    'LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now \\\n'
    "         -Wl,-z,pack-relative-relocs \\\n"
    "         -Wl,--no-copy-dt-needed-entries \\\n"
    "         -Wl,-z,nodlopen \\\n"
    '         -Wl,-z,noexecstack"\n'
    'LTOFLAGS="-flto=auto"\n'
    'RUSTFLAGS="-C opt-level=3 -C target-cpu=native"\n'
)
c = re.sub(r"#-- Compiler and Linker Flags.*?(?=\n#--|\nBUILDENV|\nDEBUG_CFLAGS)", flags, c, flags=re.DOTALL)
c = re.sub(r"^#?MAKEFLAGS=.*", f'MAKEFLAGS="-j{nproc}"', c, flags=re.MULTILINE)
c = re.sub(r"^#?NINJAFLAGS=.*", f'NINJAFLAGS="-j{nproc}"', c, flags=re.MULTILINE)
c = re.sub(r"^COMPRESSZST=.*", "COMPRESSZST=(zstd -c -T0 -19 -)", c, flags=re.MULTILINE)
c = re.sub(r"^BUILDENV=.*", "BUILDENV=(!distcc color ccache check !sign)", c, flags=re.MULTILINE)
c = re.sub(r'^DEBUG_CFLAGS=.*', 'DEBUG_CFLAGS=""', c, flags=re.MULTILINE)
c = re.sub(r'^DEBUG_CXXFLAGS=.*', 'DEBUG_CXXFLAGS="$DEBUG_CFLAGS"', c, flags=re.MULTILINE)
with open(makepkg, "w") as f:
    f.write(c)
print("makepkg.conf otimizado.")
MKPKG_PY
        python3 /tmp/_covenant_makepkg.py && rm -f /tmp/_covenant_makepkg.py
        ccache -M 10G 2>/dev/null || true
    fi
    _ok "makepkg.conf."
}

# ───── 7. I/O Scheduler ────────────────────────────────────────
apply_io() {
    _step "7/14 — I/O Scheduler (NVMe=none, SSD=mq-deadline)..."
    ensure_dir "/etc/udev/rules.d"
    cat > /etc/udev/rules.d/60-io-scheduler.rules << 'IORULES'
# NVMe — sem scheduler (hardware queue nativo)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1024"
# SSD SATA — mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDD — bfq
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
IORULES

    # Aplicar imediatamente nos devices existentes
    for dev in /sys/block/nvme*; do
        [[ -e "${dev}/queue/scheduler" ]] && echo "none" > "${dev}/queue/scheduler" 2>/dev/null || true
        [[ -e "${dev}/queue/nr_requests" ]] && echo "1024" > "${dev}/queue/nr_requests" 2>/dev/null || true
    done
    for dev in /sys/block/sd*; do
        [[ -e "${dev}/queue/rotational" ]] || continue
        rot=$(cat "${dev}/queue/rotational" 2>/dev/null || echo "1")
        if [[ "$rot" == "0" ]]; then
            echo "mq-deadline" > "${dev}/queue/scheduler" 2>/dev/null || true
        else
            echo "bfq" > "${dev}/queue/scheduler" 2>/dev/null || true
        fi
    done
    _ok "I/O Scheduler."
}

# ───── 8. CPU Governor ─────────────────────────────────────────
apply_cpu_governor() {
    _step "8/14 — CPU Governor (performance via cpupower)..."
    echo "acpi_cpufreq" > /etc/modules-load.d/acpi_cpufreq.conf
    cat > /etc/udev/rules.d/50-cpu-governor.rules << 'CPUUDEV'
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"
CPUUDEV

    # Serviço persistente
    cat > /etc/systemd/system/covenant-cpu-governor-setup.service << 'CPUSVC'
[Unit]
Description=Covenant CachyOS - CPU Governor (performance via cpupower)
After=multi-user.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-cpu-governor-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
CPUSVC

    cat > /usr/local/bin/covenant-cpu-governor-setup.sh << 'CPUSCRIPT'
#!/bin/bash
cpupower frequency-set -g performance 2>/dev/null || {
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > "$gov" 2>/dev/null || true
    done
}
CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
echo "covenant-cpu-governor: governor=${CURRENT}"
CPUSCRIPT
    chmod +x /usr/local/bin/covenant-cpu-governor-setup.sh
    _svc_enable covenant-cpu-governor-setup.service

    # Aplicar imediatamente se não em chroot
    if ! $IN_CHROOT && [[ -z "${INVOCATION_ID}" ]]; then
        cpupower frequency-set -g performance 2>/dev/null || true
    fi
    _ok "CPU Governor."
}

# ───── 9. Kernel cmdline ───────────────────────────────────────
apply_cmdline() {
    _step "9/14 — Kernel cmdline..."
    local GRUB="/etc/default/grub"
    if [[ -f "$GRUB" ]]; then
        backup_file "$GRUB" "${BACKUP_DIR}/etc/default/grub.bak"
        local params="mitigations=off nvme_core.default_ps_max_latency_us=0 nvme_core.io_timeout=4294967295 processor.max_cstate=1 intel_idle.max_cstate=1 transparent_hugepage=madvise amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off nowatchdog nmi_watchdog=0 split_lock_detect=off skew_tick=1 quiet loglevel=3"
        if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB"; then
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${params}\"|" "$GRUB"
        fi
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
    _ok "Kernel cmdline."
}

# ───── 10. DNS-over-TLS ────────────────────────────────────────
apply_dns() {
    _step "10/14 — DNS-over-TLS (Cloudflare + Quad9)..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/covenant-dns.conf << 'DNSCONF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8 8.8.4.4
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
DNSCONF
    _svc_enable systemd-resolved.service
    if ! $IN_CHROOT && [[ -z "${INVOCATION_ID}" ]]; then
        systemctl restart systemd-resolved.service 2>/dev/null || true
    fi
    _ok "DNS-over-TLS."
}

# ───── 11. Serviços ────────────────────────────────────────────
apply_services() {
    _step "11/14 — Serviços de performance..."
    local services=(
        irqbalance.service
        earlyoom.service
        ananicy-cpp.service
        thermald.service
        fstrim.timer
    )
    for svc in "${services[@]}"; do
        _svc_enable "$svc"
    done

    # earlyoom config
    ensure_dir "/etc/default"
    cat > /etc/default/earlyoom << 'EARLYOOM'
EARLYOOM_ARGS="-r 60 -m 3 -s 10 --avoid '(^|,)sshd(,|$)' --prefer '(^|,)(chromium|firefox)(,|$)'"
EARLYOOM

    # ananicy-cpp rules
    ensure_dir "/etc/ananicy.d"
    cat > /etc/ananicy.d/99-covenant.rules << 'ANANICY'
{ "name": "make",    "type": "BG_CPUIO" }
{ "name": "cc1",     "type": "BG_CPUIO" }
{ "name": "cc1plus", "type": "BG_CPUIO" }
{ "name": "ccache",  "type": "BG_CPUIO" }
{ "name": "g++",     "type": "BG_CPUIO" }
{ "name": "clang",   "type": "BG_CPUIO" }
{ "name": "kwin_wayland", "nice": -10 }
{ "name": "pipewire",     "rtprio": 89 }
{ "name": "wireplumber",  "rtprio": 88 }
ANANICY

    # profile-sync-daemon (user service)
    ensure_dir "/etc/psd"
    cat > /etc/psd/psd.conf << 'PSDCONF'
BROWSERS=(chromium firefox)
USE_OVERLAYFS="yes"
PSDCONF

    _ok "Serviços."
}

# ───── 12. GPU (AMD RX 560) ────────────────────────────────────
apply_gpu() {
    _step "12/14 — GPU performance mode (AMD auto-detect)..."

    # Auto-detect qual card tem power_dpm_force_performance_level
    local GPU_CARD=""
    for card in /sys/class/drm/card*/device; do
        [[ -f "$card/power_dpm_force_performance_level" ]] && GPU_CARD="$card" && break
    done

    # Script de performance GPU
    cat > /usr/local/bin/covenant-gpu-performance.sh << 'GPUSCRIPT'
#!/bin/bash
GPU_CARD=$(for card in /sys/class/drm/card*/device; do
    [[ -f "$card/power_dpm_force_performance_level" ]] && echo "$card" && break
done)
if [[ -n "${GPU_CARD}" ]]; then
    echo "manual" > "${GPU_CARD}/power_dpm_force_performance_level" 2>/dev/null || true
    # Forçar perf level máximo (Polaris/RX 500 series)
    local PP="${GPU_CARD}/pp_dpm_sclk"
    [[ -f "$PP" ]] && echo "$(wc -l < "$PP")" | tr -d '\n' | \
        xargs -I{} sh -c 'echo {} > "'$PP'"' 2>/dev/null || true
    echo "GPU DPM: manual ($(basename $(dirname $GPU_CARD)))"
else
    echo "GPU AMDGPU não encontrada via sysfs"
fi
GPUSCRIPT
    chmod +x /usr/local/bin/covenant-gpu-performance.sh

    # Serviço GPU
    cat > /etc/systemd/system/covenant-gpu-performance.service << 'GPUSVC'
[Unit]
Description=Covenant — GPU AMD Performance Mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-gpu-performance.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GPUSVC
    _svc_enable covenant-gpu-performance.service

    # Variáveis de ambiente para VA-API/VDPAU
    cat > /etc/environment.d/99-covenant-gpu.conf << 'GPUENV'
VDPAU_DRIVER=radeonsi
LIBVA_DRIVER_NAME=radeonsi
mesa_glthread=true
RADV_PERFTEST=gpl
GPUENV

    # Aplicar imediatamente se possível
    if ! $IN_CHROOT && [[ -n "$GPU_CARD" ]] && [[ -z "${INVOCATION_ID}" ]]; then
        echo "manual" > "${GPU_CARD}/power_dpm_force_performance_level" 2>/dev/null || true
    fi
    _ok "GPU."
}

# ───── 13. IRQ Affinity ────────────────────────────────────────
apply_irq() {
    _step "13/14 — IRQ Affinity (NVMe + GPU → cores físicos)..."

    cat > /usr/local/bin/covenant-irq-affinity.sh << 'IRQSCRIPT'
#!/bin/bash
# Distribuir IRQs de NVMe e GPU nos 14 cores físicos (0-13)
PHYSICAL_CORES=$(grep -E "^processor" /proc/cpuinfo | awk '{print $3}' | head -14 | tr '\n' ',' | sed 's/,$//')
[[ -z "$PHYSICAL_CORES" ]] && PHYSICAL_CORES="0-13"

for irq_path in /proc/irq/*/smp_affinity_list; do
    irq_dir=$(dirname "$irq_path")
    irq_name=$(cat "${irq_dir}/actions" 2>/dev/null || echo "")
    if echo "$irq_name" | grep -qiE 'nvme|amdgpu|radeon'; then
        echo "$PHYSICAL_CORES" > "$irq_path" 2>/dev/null || true
    fi
done
echo "IRQ affinity aplicada (cores físicos: ${PHYSICAL_CORES})"
IRQSCRIPT
    chmod +x /usr/local/bin/covenant-irq-affinity.sh

    cat > /etc/systemd/system/covenant-irq-affinity.service << 'IRQSVC'
[Unit]
Description=Covenant — IRQ Affinity para NVMe e GPU
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-irq-affinity.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
IRQSVC
    _svc_enable covenant-irq-affinity.service
    _ok "IRQ affinity."
}

# ───── 14. Sistema (journald, coredumps, /tmp, fstrim) ────────
apply_system() {
    _step "14/14 — Sistema (journald, coredumps, tmpfs, modulos)..."

    # journald
    mkdir -p /var/log/journal
    cat > /etc/systemd/journald.conf.d/covenant.conf << 'JOURNALD'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=512M
SystemKeepFree=128M
SystemMaxFileSize=64M
RuntimeMaxUse=512M
MaxRetentionSec=1week
ForwardToSyslog=no
JOURNALD

    # Coredumps desabilitados
    echo '* hard core 0' >> /etc/security/limits.conf 2>/dev/null || true
    echo '* soft core 0' >> /etc/security/limits.conf 2>/dev/null || true
    mkdir -p /etc/systemd/coredump.conf.d
    echo -e "[Coredump]\nStorage=none\nProcessSizeMax=0" > /etc/systemd/coredump.conf.d/covenant.conf

    # /tmp em tmpfs 16GB
    if ! grep -q "^tmpfs.*/tmp" /etc/fstab 2>/dev/null; then
        echo "tmpfs /tmp tmpfs size=16G,mode=1777,nosuid,nodev 0 0" >> /etc/fstab
    fi

    # Módulos
    cat > /etc/modules-load.d/covenant.conf << 'MODULES'
# Covenant CachyOS — módulos de performance
tcp_bbr
MODULES

    # fstrim semanal (já habilitado pelo serviço, mas garantir)
    systemctl enable fstrim.timer 2>/dev/null || true

    # Limites de sistema
    cat > /etc/security/limits.d/99-covenant.conf << 'LIMITS'
* soft nproc 65536
* hard nproc 65536
* soft nofile 65536
* hard nofile 65536
LIMITS

    # Cursor theme
    ensure_dir "/etc/skel/.icons/default"
    if pacman -Qi "breeze-cursors" &>/dev/null 2>/dev/null; then
        echo -e "[Icon Theme]\nInherits=breeze_cursors" > /etc/skel/.icons/default/index.theme
    fi

    _ok "Sistema."
}

# ───── covenant-check.sh ───────────────────────────────────────
install_check_script() {
    cat > /usr/local/bin/covenant-check.sh << 'CHECKSCRIPT'
#!/usr/bin/env bash
echo ""
echo "=== Covenant CachyOS — Verificação de Otimizações ==="
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
chk "psd (user)"        "$(systemctl --user is-active psd 2>/dev/null || echo 'inactive')"

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
    echo " Covenant CachyOS — Pós-Instalação v3.0"
    echo " Hardware: Xeon E5-2680v4 + RX 560 + ${HW_MEMGB}GB RAM"
    echo " Chroot: ${IN_CHROOT} | Threads: ${HW_NPROC}"
    echo "============================================================"
    echo ""

    check_root

    # --first-boot: verifica se já rodou
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
    install_check_script

    echo ""
    echo "============================================================"
    echo " Covenant CachyOS — Pós-Instalação CONCLUÍDA (chroot=${IN_CHROOT})"
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
