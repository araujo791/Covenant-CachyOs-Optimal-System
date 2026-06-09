#!/bin/bash
# covenant-post-install.sh — Aplica TODAS as otimizações do Covenant CachyOS
# Hardware: Xeon E5-2680v4 (14c/28t) + AMD RX 560 + 64GB ECC RAM + NVMe
#
# Uso:
#   sudo bash post-install.sh
#
# Ou via curl:
#   curl -O https://raw.githubusercontent.com/araujo791/Covenant-CachyOs-Optimal-System/main/post-install.sh
#   sudo bash post-install.sh
#
# Antigo modo automático (removido):
#   - Calamares shellprocess (durante instalação online)
#   - covenant-first-boot.service (primeiro boot após instalação offline)
#   - Manualmente: sudo bash covenant-post-install.sh

set -euo pipefail

_log_step() { echo ""; echo "===> [PASSO] $*"; }
_log_ok()   { echo "    [OK] $*"; }
_log_warn() { echo "    [AVISO] $*" >&2; }

# Detecta se estamos em chroot (build ou Calamares target)
IN_CHROOT=false
if systemd-detect-virt --chroot 2>/dev/null; then
    IN_CHROOT=true
fi

# Função helper: enable (+ start se não estiver em chroot nem em serviço systemd)
_svc_enable() {
    local svc="$1"
    # Não usar --now se: (1) em chroot, ou (2) rodando dentro de um serviço systemd
    # (evita deadlock quando first-boot.service tenta iniciar outros serviços)
    if $IN_CHROOT || [[ -n "${INVOCATION_ID:-}" ]]; then
        systemctl enable "${svc}" 2>/dev/null || true
    else
        systemctl enable --now "${svc}" 2>/dev/null || true
    fi
}

echo ""
echo "============================================================"
echo " Covenant CachyOS — Pós-Instalação"
echo " Hardware: Xeon E5-2680v4 + RX 560 + 64GB ECC RAM"
echo " Chroot: ${IN_CHROOT}"
echo "============================================================"

# --- Instalar pacotes necessários ---
_log_step "1/23 — Pacotes de performance..."
PERF_PKGS=(irqbalance zram-generator ananicy-cpp earlyoom ccache
           profile-sync-daemon thermald cpupower)
missing=()
for pkg in "${PERF_PKGS[@]}"; do
    pacman -Qi "$pkg" &>/dev/null || missing+=("$pkg")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    pacman -Sy --needed --noconfirm "${missing[@]}" 2>/dev/null || _log_warn "Alguns pacotes indisponíveis."
fi
_log_ok "Pacotes verificados."

# --- 1. sysctl ---
_log_step "2/23 — sysctl (BBR, rede, VM, scheduler, hugepages)..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/90-covenant.conf << 'SYSCTL'
# Covenant CachyOS — sysctl complementar (prioridade 90)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.optmem_max = 65536
vm.max_map_count = 2097152
kernel.pid_max = 4194304
kernel.numa_balancing = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.vfs_cache_pressure = 50
kernel.sched_autogroup_enabled = 1
# BORE/sched-ext não usa sched_* do CFS clássico — parâmetros removidos
kernel.sched_cfs_bandwidth_slice_us = 3000

kernel.dmesg_restrict = 0
kernel.kptr_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 1
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152
kernel.io_delay_type = 0
vm.nr_hugepages = 1024
SYSCTL
$IN_CHROOT || sysctl --system > /dev/null 2>&1
_log_ok "sysctl aplicado."

# --- 2. BBR ---
_log_step "3/23 — Módulo BBR..."
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
$IN_CHROOT || modprobe tcp_bbr 2>/dev/null || true
_log_ok "BBR."

# --- 3. zram 1GB ---
_log_step "4/23 — zram 1GB zstd..."
cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = 1024
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
_log_ok "zram 1GB."

# --- 4. I/O scheduler ---
_log_step "5/23 — I/O scheduler..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-io-scheduler.rules << 'IOSCHED'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nomerges}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/nr_requests}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="2048"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/add_random}="1"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/rq_affinity}="1"
IOSCHED
if ! $IN_CHROOT; then
    for dev in /sys/block/nvme*; do
        [[ -d "$dev" ]] || continue
        echo "none" > "${dev}/queue/scheduler" 2>/dev/null || true
        echo "2048" > "${dev}/queue/nr_requests" 2>/dev/null || true
        echo "512"  > "${dev}/queue/read_ahead_kb" 2>/dev/null || true
        echo "0"    > "${dev}/queue/wbt_lat_usec" 2>/dev/null || true
        echo "2"    > "${dev}/queue/rq_affinity" 2>/dev/null || true
    done
fi
_log_ok "I/O scheduler."

# --- 5. makepkg ---
_log_step "6/23 — makepkg.conf..."
MAKEPKG="/etc/makepkg.conf"
if [[ -f "$MAKEPKG" ]]; then
    NPROC=$(nproc 2>/dev/null || echo 28)
    sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' "$MAKEPKG" 2>/dev/null || true
    sed -i 's/^CXXFLAGS=.*/CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"/' "$MAKEPKG" 2>/dev/null || true
    sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=3 -C target-cpu=native"/' "$MAKEPKG" 2>/dev/null || true
    sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" "$MAKEPKG" 2>/dev/null || true
    sed -i "s/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/" "$MAKEPKG" 2>/dev/null || true
    grep -q 'ccache' "$MAKEPKG" 2>/dev/null || \
        sed -i 's|^BUILDENV=.*|BUILDENV=(!distcc color ccache check !sign)|' "$MAKEPKG" 2>/dev/null || true
fi
mkdir -p /etc/ccache.conf.d
cat > /etc/ccache.conf << 'CCACHE'
max_size = 10G
compression = true
compression_level = 1
CCACHE
_log_ok "makepkg + ccache."

# --- 6. ananicy-cpp ---
_log_step "7/23 — ananicy-cpp..."
_svc_enable ananicy-cpp.service
mkdir -p /etc/ananicy.d
cat > /etc/ananicy.d/covenant-custom.rules << 'ANANICY'
{ "name": "make",          "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1",           "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1plus",       "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "ld",            "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "rustc",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cargo",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "ninja",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cmake",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "ccache",        "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "gcc",           "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "g++",           "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "clang",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "clang++",       "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "pipewire",      "type": "Audio",    "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "pipewire-pulse", "type": "Audio",   "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "wireplumber",   "type": "Audio",    "nice": -11 }
{ "name": "kwin_wayland",  "type": "WM",       "nice": -15 }
{ "name": "kwin_x11",      "type": "WM",       "nice": -15 }
{ "name": "plasmashell",   "type": "LightWM",  "nice": -10 }
{ "name": "Xwayland",      "type": "LightWM",  "nice": -10 }
{ "name": "konsole",       "type": "LightWM",  "nice": -5 }
{ "name": "dolphin",       "type": "LightWM",  "nice": -5 }
ANANICY
_log_ok "ananicy-cpp."

# --- 7. earlyoom ---
_log_step "8/23 — earlyoom..."
mkdir -p /etc/default
cat > /etc/default/earlyoom << 'EARLYOOM'
EARLYOOM_ARGS="-m 5 -M 3 -s 5 -S 3 --avoid '(sshd|systemd|init)' --prefer '(chrome|firefox|electron|Web Content)' -r 60 -N /usr/bin/notify-send"
EARLYOOM
_svc_enable earlyoom.service
_log_ok "earlyoom."

# --- 8. Env vars ---
_log_step "9/23 — Variáveis de ambiente..."
sed -i '/# === Covenant CachyOS/,/^$/d' /etc/environment 2>/dev/null || true
cat >> /etc/environment << 'ENVVARS'

# === Covenant CachyOS — Performance Environment ===
AMD_VULKAN_ICD=RADV
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
mesa_glthread=true
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
_JAVA_AWT_WM_NONREPARENTING=1
VDPAU_DRIVER=radeonsi
LIBVA_DRIVER_NAME=radeonsi
ENVVARS
_log_ok "Env vars."

# --- 9. Serviços systemd ---
_log_step "10/23 — Serviços systemd..."
for svc in irqbalance.service fstrim.timer thermald.service systemd-oomd.service; do
    _svc_enable "$svc"
done
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/covenant-daily.conf << 'FSTRIM'
[Timer]
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=1800
FSTRIM
for svc in ModemManager.service bluetooth.service; do
    systemctl disable "${svc}" 2>/dev/null || true
    $IN_CHROOT || systemctl stop "${svc}" 2>/dev/null || true
done
_log_ok "Serviços."

# --- 10. journald ---
_log_step "11/23 — journald..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/covenant.conf << 'JOURNALD'
[Journal]
SystemMaxUse=512M
SystemKeepFree=1G
MaxRetentionSec=1week
Compress=yes
JOURNALD
_log_ok "journald."

# --- 11. DNS ---
_log_step "12/23 — DNS (Cloudflare + Quad9, DoT)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/covenant.conf << 'RESOLVED'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=1.0.0.1#cloudflare-dns.com 149.112.112.112#dns.quad9.net
DNSSEC=allow-downgrade
DNSOverTLS=yes
Cache=yes
CacheFromLocalhost=yes
RESOLVED
_svc_enable systemd-resolved.service
_log_ok "DNS."

# --- 12. CPU governor ---
_log_step "13/23 — CPU governor (performance)..."
mkdir -p /etc/systemd/system /usr/local/bin /etc/udev/rules.d /etc/tmpfiles.d
NPROC=$(nproc 2>/dev/null || echo 28)
{
    echo "# Covenant — cpu governor: performance"
    for i in $(seq 0 $(( NPROC - 1 ))); do
        printf 'w! /sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor - - - - performance\n' "$i"
    done
} > /etc/tmpfiles.d/cpu-governor.conf
# Carregar acpi_cpufreq antes do udev para que cpufreq/scaling_governor exista
echo "acpi_cpufreq" > /etc/modules-load.d/acpi_cpufreq.conf

# udev apenas para hotplug (CPU adicionada após boot)
cat > /etc/udev/rules.d/50-cpu-governor.rules << 'CPUUDEV'
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"
CPUUDEV
if ! $IN_CHROOT; then
    systemd-tmpfiles --create /etc/tmpfiles.d/cpu-governor.conf 2>/dev/null || true
    for i in $(seq 0 $(( NPROC - 1 ))); do
        echo "performance" > "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor" 2>/dev/null || true
    done
fi
_log_ok "CPU governor."

# --- 13. Limites ---
_log_step "14/23 — Limites..."
cat > /etc/security/limits.d/covenant.conf << 'LIMITS'
*      soft  nofile   524288
*      hard  nofile   1048576
*      soft  nproc    65536
*      hard  nproc    131072
*      soft  memlock  unlimited
*      hard  memlock  unlimited
@audio soft  rtprio   99
@audio hard  rtprio   99
@audio soft  memlock  unlimited
@audio hard  memlock  unlimited
LIMITS
_log_ok "Limites."

# --- 14. /tmp tmpfs ---
_log_step "15/23 — /tmp tmpfs 16GB..."
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/tmp.mount << 'TMPMOUNT'
[Unit]
Description=Temporary Directory /tmp (Covenant — 16GB RAM)
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,size=16G
[Install]
WantedBy=local-fs.target
TMPMOUNT
systemctl enable tmp.mount 2>/dev/null || true
_log_ok "/tmp tmpfs."

# --- 15. pacman ---
_log_step "16/23 — pacman..."
if [[ -f /etc/pacman.conf ]]; then
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#Color$/Color/' /etc/pacman.conf 2>/dev/null || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf 2>/dev/null || true
fi
_log_ok "pacman."

# --- 16. Kernel cmdline ---
_log_step "17/23 — Kernel cmdline..."
COV_CMD="nvme_core.default_ps_max_latency_us=0 nvme_core.io_timeout=4294967295 mitigations=off nowatchdog nmi_watchdog=0 skew_tick=1 transparent_hugepage=madvise amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off split_lock_detect=off processor.max_cstate=1 intel_idle.max_cstate=1 quiet loglevel=3"
mkdir -p /etc/default/grub.d
printf '# Covenant CachyOS\nGRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$COV_CMD" > /etc/default/grub.d/covenant-cmdline.cfg
mkdir -p /etc/kernel/cmdline.d
echo "$COV_CMD" > /etc/kernel/cmdline.d/covenant.conf
if ! $IN_CHROOT; then
    if command -v grub-mkconfig &>/dev/null && [[ -f /boot/grub/grub.cfg ]]; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || _log_warn "grub-mkconfig falhou."
    fi
fi
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/covenant-grub-update.hook << 'GRUBHOOK'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = linux
Target = linux-cachyos
Target = linux-cachyos-lts
Target = grub
[Action]
Description = Covenant: regenerando GRUB após atualização de kernel...
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
GRUBHOOK
_log_ok "Kernel cmdline."

# --- 17. Módulos ---
_log_step "18/23 — Módulos kernel..."
cat > /etc/modprobe.d/covenant-blacklist.conf << 'BLACKLIST'
blacklist nouveau
blacklist snd_hda_codec_hdmi
blacklist pcspkr
blacklist iTCO_wdt
blacklist sp5100_tco
blacklist bluetooth
blacklist btusb
blacklist btrtl
blacklist btbcm
blacklist btintel
BLACKLIST
cat > /etc/modprobe.d/covenant-amdgpu.conf << 'AMDGPU'
options amdgpu gpu_recovery=1
options amdgpu deep_color=1
options amdgpu dc=1
options amdgpu dpm=1
AMDGPU
_log_ok "Módulos."

# --- 18. Coredumps ---
_log_step "19/23 — Coredumps off..."
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/covenant.conf << 'COREDUMP'
[Coredump]
Storage=none
ProcessSizeMax=0
COREDUMP
_log_ok "Coredumps."

# --- 19. profile-sync-daemon ---
_log_step "20/23 — profile-sync-daemon..."
mkdir -p /etc/skel/.config/psd
cat > /etc/skel/.config/psd/psd.conf << 'PSD'
USE_OVERLAYFS="yes"
USE_BACKUPS="yes"
PSD
mkdir -p /etc/skel/.config/systemd/user/default.target.wants
ln -sf /usr/lib/systemd/user/psd.service \
    /etc/skel/.config/systemd/user/default.target.wants/psd.service 2>/dev/null || true
# Se rodando fora de chroot como root, configura para o usuário real
if ! $IN_CHROOT; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
    if [[ -n "$REAL_USER" ]]; then
        REAL_HOME=$(eval echo "~${REAL_USER}")
        mkdir -p "${REAL_HOME}/.config/psd" "${REAL_HOME}/.config/systemd/user/default.target.wants"
        cp /etc/skel/.config/psd/psd.conf "${REAL_HOME}/.config/psd/psd.conf"
        ln -sf /usr/lib/systemd/user/psd.service \
            "${REAL_HOME}/.config/systemd/user/default.target.wants/psd.service" 2>/dev/null || true
        chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config" 2>/dev/null || true
    fi
fi
_log_ok "psd."

# --- 20. IRQ affinity ---
_log_step "21/23 — IRQ affinity..."
cat > /usr/local/bin/covenant-irq-affinity.sh << 'IRQSCRIPT'
#!/bin/bash
for irq in $(grep -E 'nvme|amdgpu' /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' '); do
    echo "3fff" > /proc/irq/${irq}/smp_affinity 2>/dev/null || true
done
echo "covenant-irq-affinity: IRQs distribuídas nos 14 cores físicos."
IRQSCRIPT
chmod +x /usr/local/bin/covenant-irq-affinity.sh
cat > /etc/systemd/system/covenant-irq-affinity.service << 'IRQSVC'
[Unit]
Description=Covenant — IRQ Affinity para NVMe e GPU
After=multi-user.target irqbalance.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-irq-affinity.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
IRQSVC
_svc_enable covenant-irq-affinity.service
_log_ok "IRQ affinity."

# --- 21. GPU RX 560 ---
_log_step "22/23 — GPU performance mode..."
cat > /usr/local/bin/covenant-gpu-performance.sh << 'GPUSCRIPT'
#!/bin/bash
sleep 5
GPU_PATH=$(for card in /sys/class/drm/card*/device; do
    [[ -f "$card/power_dpm_force_performance_level" ]] && echo "$card" && break
done)
if [[ -n "${GPU_PATH}" ]]; then
    echo "manual" > "${GPU_PATH}/power_dpm_force_performance_level"
    SCLK_MAX=$(cat "${GPU_PATH}/pp_dpm_sclk" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d ':')
    MCLK_MAX=$(cat "${GPU_PATH}/pp_dpm_mclk" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d ':')
    [[ -n "$SCLK_MAX" ]] && echo "$SCLK_MAX" > "${GPU_PATH}/pp_dpm_sclk"
    [[ -n "$MCLK_MAX" ]] && echo "$MCLK_MAX" > "${GPU_PATH}/pp_dpm_mclk"
    echo "covenant-gpu: RX 560 performance max (sclk=$SCLK_MAX, mclk=$MCLK_MAX)"
else
    echo "covenant-gpu: GPU path não encontrado — pulando."
fi
GPUSCRIPT
chmod +x /usr/local/bin/covenant-gpu-performance.sh
cat > /etc/systemd/system/covenant-gpu-performance.service << 'GPUSVC'
[Unit]
Description=Covenant — AMD RX 560 Performance Mode
After=display-manager.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-gpu-performance.sh
RemainAfterExit=yes
[Install]
WantedBy=graphical.target
GPUSVC
_svc_enable covenant-gpu-performance.service
_log_ok "GPU."

# --- 22. Cursor ---
_log_step "Cursor theme..."
mkdir -p /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0 \
         /etc/skel/.icons/default /etc/skel/.config
printf '[Settings]\ngtk-cursor-theme-name=Adwaita\ngtk-cursor-theme-size=24\n' > /etc/skel/.config/gtk-3.0/settings.ini
printf '[Settings]\ngtk-cursor-theme-name=Adwaita\ngtk-cursor-theme-size=24\n' > /etc/skel/.config/gtk-4.0/settings.ini
printf '[Icon Theme]\nName=Default\nComment=Default Cursor Theme\nInherits=Adwaita\n' > /etc/skel/.icons/default/index.theme
_log_ok "Cursor."

# --- CPU governor setup ---
_log_step "CPU governor — cpupower + service..."
cat > /usr/local/bin/covenant-cpu-governor-setup.sh << 'CPUSCRIPT'
#!/bin/bash
# Covenant — CPU governor setup via cpupower
# Funciona com acpi-cpufreq (E5-2680v4 não usa intel_pstate)
cpupower frequency-set -g performance 2>/dev/null || {
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > "$gov" 2>/dev/null || true
    done
}
CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
echo "covenant-cpu-governor: governor=${CURRENT}"
CPUSCRIPT
chmod +x /usr/local/bin/covenant-cpu-governor-setup.sh

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

# acpi_cpufreq deve ser carregado antes do udev
echo "acpi_cpufreq" > /etc/modules-load.d/acpi_cpufreq.conf

# udev hotplug fallback
cat > /etc/udev/rules.d/50-cpu-governor.rules << 'CPUUDEV'
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"
CPUUDEV

if ! $IN_CHROOT; then
    # Usar enable sem --now para evitar deadlock dentro do first-boot.service
    systemctl enable covenant-cpu-governor-setup.service 2>/dev/null || true
    # Iniciar só se não estiver dentro de um serviço systemd
    [[ -z "${INVOCATION_ID:-}" ]] && systemctl start covenant-cpu-governor-setup.service 2>/dev/null || true
else
    systemctl enable covenant-cpu-governor-setup.service 2>/dev/null || true
fi
_log_ok "CPU governor service."

# --- 23. covenant-check.sh ---
_log_step "23/23 — covenant-check.sh..."
cat > /usr/local/bin/covenant-check.sh << 'CHECKSCRIPT'
#!/bin/bash
echo "=== Covenant CachyOS — Verificação de Otimizações ==="
echo ""
printf "%-30s %s\n" "TCP Congestion:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "%-30s %s\n" "CPU Governor (cpu0):" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')"
printf "%-30s %s\n" "NVMe Scheduler:" "$(cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null || echo 'n/a')"
printf "%-30s %s\n" "zram:" "$(zramctl --noheadings -o NAME,DISKSIZE,ALGORITHM 2>/dev/null || echo 'n/a')"
printf "%-30s %s\n" "Huge Pages:" "$(sysctl -n vm.nr_hugepages 2>/dev/null) x 2MB"
MIT=$(cat /sys/devices/system/cpu/vulnerabilities/spectre_v2 2>/dev/null || echo "n/a")
[[ "$MIT" == *"Vulnerable"* ]] && MIT_OUT="OFF (intencional — mitigations=off)" || MIT_OUT="${MIT:0:60}"
printf "%-30s %s\n" "Mitigations:" "$MIT_OUT"
GPU_CARD=$(for card in /sys/class/drm/card*/device; do [[ -f "$card/power_dpm_force_performance_level" ]] && echo "$card" && break; done)
printf "%-30s %s\n" "GPU DPM Level:" "$(cat "${GPU_CARD}/power_dpm_force_performance_level" 2>/dev/null || echo 'n/a')"
printf "%-30s %s\n" "earlyoom:" "$(systemctl is-active earlyoom 2>/dev/null)"
printf "%-30s %s\n" "irqbalance:" "$(systemctl is-active irqbalance 2>/dev/null)"
printf "%-30s %s\n" "ananicy-cpp:" "$(systemctl is-active ananicy-cpp 2>/dev/null)"
printf "%-30s %s\n" "thermald:" "$(systemctl is-active thermald 2>/dev/null)"
printf "%-30s %s\n" "IRQ affinity:" "$(systemctl is-active covenant-irq-affinity 2>/dev/null)"
printf "%-30s %s\n" "GPU service:" "$(systemctl is-active covenant-gpu-performance 2>/dev/null)"
printf "%-30s %s\n" "psd (user):" "$(systemctl --user is-active psd 2>/dev/null || echo 'run: systemctl --user start psd')"
printf "%-30s %s\n" "DNS-over-TLS:" "$(resolvectl status 2>/dev/null | grep -o 'DNSOverTLS.*' | head -1 || echo 'n/a')"
printf "%-30s %s\n" "ccache size:" "$(ccache -s 2>/dev/null | grep -i 'cache size' | head -1 || echo 'n/a')"
echo ""
echo "Tudo OK se: governor=performance, NVMe=[none], TCP=bbr, GPU=manual"
CHECKSCRIPT
chmod +x /usr/local/bin/covenant-check.sh
_log_ok "covenant-check.sh."

echo ""
echo "============================================================"
echo " Covenant CachyOS — Pós-Instalação CONCLUÍDA (chroot=$IN_CHROOT)"
echo "============================================================"
