#!/bin/bash
# =============================================================================
# Covenant CachyOS — cleanup-airootfs.sh
# Roda dentro do chroot do airootfs durante o build da ISO.
# Aplica limpeza de arquivos desnecessários + otimizações de sistema.
# Xeon E5-2680v4 (14c/28t) + AMD RX 560 + 64GB ECC RAM
# =============================================================================

set -euo pipefail

echo ""
echo "=========================================="
echo " Covenant CachyOS — cleanup + otimizações"
echo "=========================================="

# ---------------------------------------------------------------------------
# LIMPEZA
# ---------------------------------------------------------------------------
echo ""
echo "==> [LIMPEZA] Removendo arquivos desnecessários..."

echo "  -> Locales (mantém pt_BR, en_US, en_GB)..."
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'pt_BR' ! -name 'en_US' ! -name 'en_GB' \
    -exec rm -rf {} + 2>/dev/null || true

echo "  -> Documentação..."
rm -rf /usr/share/doc/* /usr/share/info/* /usr/share/gtk-doc 2>/dev/null || true

echo "  -> Fontes CJK..."
find /usr/share/fonts -mindepth 1 -maxdepth 1 -type d \
    \( -name "*CJK*" -o -name "*cjk*" -o -name "*Noto*CJK*" \) \
    -exec rm -rf {} + 2>/dev/null || true

echo "  -> Ícones (mantém breeze, hicolor, Adwaita)..."
find /usr/share/icons -mindepth 1 -maxdepth 1 -type d \
    ! -name 'breeze' ! -name 'breeze-dark' \
    ! -name 'hicolor' ! -name 'Adwaita' \
    -exec rm -rf {} + 2>/dev/null || true

echo "  -> Man pages..."
rm -rf /usr/share/man/* 2>/dev/null || true

echo "  -> Dados nmap..."
rm -rf /usr/share/nmap 2>/dev/null || true

echo "  -> Vozes espeak (mantém pt, en)..."
find /usr/share/espeak-ng-data -name "*.dict" \
    ! -name "pt*.dict" ! -name "en*.dict" \
    -delete 2>/dev/null || true

# Cursor theme
echo "  -> Cursor theme Adwaita..."
mkdir -p /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0 /etc/skel/.icons/default

cat > /etc/skel/.config/gtk-3.0/settings.ini << 'EOF'
[Settings]
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

cat > /etc/skel/.config/gtk-4.0/settings.ini << 'EOF'
[Settings]
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

cat > /etc/skel/.icons/default/index.theme << 'EOF'
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Adwaita
EOF

mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kcminputrc << 'EOF'
[Mouse]
cursorTheme=Adwaita
cursorSize=24
EOF

grep -q 'XCURSOR_THEME' /etc/environment 2>/dev/null \
    || printf '\nXCURSOR_THEME=Adwaita\nXCURSOR_SIZE=24\n' >> /etc/environment

echo "     Limpeza concluída."

# ---------------------------------------------------------------------------
# OTIMIZAÇÕES
# ---------------------------------------------------------------------------
echo ""
echo "==> [OTIMIZAÇÕES] Aplicando tuning de sistema..."

# --- 1. sysctl ---
echo "  -> sysctl..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/90-covenant.conf << 'EOF'
# Covenant CachyOS — sysctl (prioridade 90)
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
vm.max_map_count = 1048576
kernel.pid_max = 4194304
kernel.numa_balancing = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.vfs_cache_pressure = 50
EOF

# --- 2. BBR ---
echo "  -> BBR..."
echo 'tcp_bbr' > /etc/modules-load.d/covenant.conf

# --- 3. zram ---
echo "  -> zram..."
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = 8192
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# --- 4. I/O scheduler ---
echo "  -> I/O scheduler..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
# Covenant CachyOS — I/O tuning

# NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nr_requests}="2048"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/rq_affinity}="2"

# SSD SATA
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"

# HDD
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/nr_requests}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="2048"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/add_random}="1"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/rq_affinity}="1"
EOF

# --- 5. makepkg ---
echo "  -> makepkg..."
MAKEPKG_CONF="/etc/makepkg.conf"
if [[ -f "${MAKEPKG_CONF}" ]]; then
    sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' "${MAKEPKG_CONF}" || true
    sed -i 's/^CXXFLAGS=.*/CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"/' "${MAKEPKG_CONF}" || true
    sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=3 -C target-cpu=native"/' "${MAKEPKG_CONF}" || true
    sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' "${MAKEPKG_CONF}" || true
    sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/' "${MAKEPKG_CONF}" || true
fi

# --- 6. ananicy-cpp ---
echo "  -> ananicy-cpp..."
systemctl enable ananicy-cpp.service 2>/dev/null || systemctl enable ananicy.service 2>/dev/null || true
mkdir -p /etc/ananicy.d
cat > /etc/ananicy.d/covenant-custom.rules << 'EOF'
{ "name": "make",          "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1",           "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1plus",       "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "ld",            "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "kwin_wayland",  "type": "WM",       "nice": -5 }
{ "name": "kwin_x11",      "type": "WM",       "nice": -5 }
{ "name": "plasmashell",   "type": "LightWM",  "nice": -3 }
{ "name": "pipewire",      "type": "Audio",    "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "pipewire-pulse","type": "Audio",    "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "wireplumber",   "type": "Audio",    "nice": -11 }
EOF

# --- 7. earlyoom ---
echo "  -> earlyoom..."
mkdir -p /etc/default
cat > /etc/default/earlyoom << 'EOF'
EARLYOOM_ARGS="-m 5 -M 3 -s 5 -S 3 --avoid '(sshd|systemd|init)' --prefer '(chrome|firefox|electron)'"
EOF
systemctl enable earlyoom.service 2>/dev/null || true

# --- 8. variáveis de ambiente ---
echo "  -> Variáveis de ambiente..."
cat >> /etc/environment << 'EOF'

# Covenant CachyOS — Performance
AMD_VULKAN_ICD=RADV
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
MESA_NO_ERROR=1
RADV_PERFTEST=aco
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
_JAVA_AWT_WM_NONREPARENTING=1
EOF

# --- 9. Serviços ---
echo "  -> Serviços systemd..."
for svc in irqbalance.service power-profiles-daemon.service fstrim.timer; do
    systemctl enable "${svc}" 2>/dev/null && echo "     [+] ${svc}" || echo "     [!] ${svc} (ok)"
done

for svc in ModemManager.service bluetooth.service; do
    systemctl disable "${svc}" 2>/dev/null && echo "     [-] ${svc}" || true
done

# fstrim diário
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/covenant-daily.conf << 'EOF'
[Timer]
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=1800
EOF

# --- 10. journald ---
echo "  -> journald..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/covenant.conf << 'EOF'
[Journal]
SystemMaxUse=512M
SystemKeepFree=1G
MaxRetentionSec=1week
Compress=yes
EOF

# --- 11. DNS ---
echo "  -> DNS com cache..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/covenant.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9 8.8.8.8
FallbackDNS=1.0.0.1 149.112.112.112
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=yes
EOF
systemctl enable systemd-resolved.service 2>/dev/null || true

# --- 12. CPU governor (serviço de primeiro boot) ---
echo "  -> CPU governor..."
mkdir -p /etc/systemd/system /usr/local/bin /etc/udev/rules.d

cat > /usr/local/bin/covenant-cpu-governor-setup.sh << 'EOF'
#!/bin/bash
CPU_COUNT=$(nproc 2>/dev/null || ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l || echo 4)
mkdir -p /etc/tmpfiles.d
{
    echo "# Covenant — cpu governor: performance"
    for i in $(seq 0 $(( CPU_COUNT - 1 ))); do
        printf 'w! /sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor - - - - performance\n' "$i"
    done
} > /etc/tmpfiles.d/cpu-governor.conf
systemd-tmpfiles --create /etc/tmpfiles.d/cpu-governor.conf 2>/dev/null || true
echo "CPU governor: ${CPU_COUNT} cores → performance"
systemctl disable covenant-cpu-governor-setup.service 2>/dev/null || true
EOF
chmod +x /usr/local/bin/covenant-cpu-governor-setup.sh

cat > /etc/systemd/system/covenant-cpu-governor-setup.service << 'EOF'
[Unit]
Description=Covenant - CPU Governor Setup (primeiro boot)
After=systemd-tmpfiles-setup.service
Before=display-manager.service
ConditionPathExists=!/etc/tmpfiles.d/cpu-governor.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-cpu-governor-setup.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
systemctl enable covenant-cpu-governor-setup.service 2>/dev/null || true

cat > /etc/udev/rules.d/50-cpu-governor.rules << 'EOF'
SUBSYSTEM=="cpu", ACTION=="add", ATTR{cpufreq/scaling_governor}="performance"
EOF

# --- 13. Limites ---
echo "  -> Limites de sistema..."
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/covenant.conf << 'EOF'
*      soft  nofile   524288
*      hard  nofile   1048576
*      soft  nproc    65536
*      hard  nproc    131072
*      soft  core     0
*      hard  core     0
@audio soft  memlock  unlimited
@audio hard  memlock  unlimited
EOF

# --- 14. /tmp em RAM ---
echo "  -> /tmp em tmpfs..."
grep -q 'tmpfs.*/tmp' /etc/fstab 2>/dev/null \
    || printf '\ntmpfs\t/tmp\ttmpfs\trw,nosuid,nodev,noatime,size=8G,mode=1777\t0 0\n' >> /etc/fstab

# --- 15. pacman.conf do sistema instalado ---
echo "  -> pacman.conf..."
mkdir -p /etc
PACMAN_CONF_FILE="/etc/pacman.conf"
if [[ -f "${PACMAN_CONF_FILE}" ]]; then
    sed -i 's/^#\?ParallelDownloads\s*=.*/ParallelDownloads = 5/' "${PACMAN_CONF_FILE}" || true
    sed -i 's/^#Color$/Color/'                                     "${PACMAN_CONF_FILE}" || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'                  "${PACMAN_CONF_FILE}" || true
    sed -i 's/^SigLevel\s*=.*/SigLevel = Required DatabaseOptional/' "${PACMAN_CONF_FILE}" || true
    grep -q 'ILoveCandy' "${PACMAN_CONF_FILE}" \
        || sed -i '/^Color/a ILoveCandy' "${PACMAN_CONF_FILE}" || true
fi

# --- 16. Kernel cmdline ---
echo "  -> Kernel cmdline..."
COVENANT_CMDLINE="intel_pstate=disable cpufreq.default_governor=performance nvme_core.default_ps_state=0 nvme_core.io_timeout=4294967295 mitigations=off nowatchdog nmi_watchdog=0 skew_tick=1 transparent_hugepage=madvise amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off split_lock_detect=off iomem=relaxed quiet loglevel=3"

mkdir -p /etc/default/grub.d /etc/kernel/cmdline.d /etc/pacman.d/hooks
cat > /etc/default/grub.d/covenant-cmdline.cfg << EOF
GRUB_CMDLINE_LINUX_DEFAULT="${COVENANT_CMDLINE}"
EOF
echo "${COVENANT_CMDLINE}" > /etc/kernel/cmdline.d/covenant.conf

if command -v grub-mkconfig &>/dev/null && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
fi

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/covenant-grub-update.hook << 'EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = linux*
Target = grub

[Action]
Description = Covenant: atualizando GRUB...
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
EOF

# --- 17. BORE scheduler ---
echo "  -> BORE scheduler..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/91-covenant-sched.conf << 'EOF'
# Covenant CachyOS — BORE scheduler
kernel.sched_latency_ns = 3000000
kernel.sched_min_granularity_ns = 500000
kernel.sched_wakeup_granularity_ns = 2000000
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 1
vm.nr_hugepages = 512
vm.hugepages_treat_as_movable = 1
EOF

grep -q 'hugetlbfs' /etc/fstab 2>/dev/null \
    || printf '\nhugetlbfs\t/dev/hugepages\thugetlbfs\tdefaults\t0 0\n' >> /etc/fstab

# --- 18. Coredump desabilitado ---
echo "  -> Coredumps..."
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/covenant.conf << 'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

# --- 19. Hardware watchdog ---
echo "  -> Hardware watchdog..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/covenant-watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdogSec=off
RebootWatchdogSec=off
KExecWatchdogSec=off
EOF
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/covenant-blacklist.conf << 'EOF'
blacklist iTCO_wdt
blacklist iTCO_vendor_support
EOF

# --- 20. AMDGPU power profile ---
echo "  -> AMDGPU power profile..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/61-amdgpu-performance.rules << 'EOF'
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{power/power_dpm_force_performance_level}="high"
EOF

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/covenant-amdgpu-perf.service << 'EOF'
[Unit]
Description=Covenant - AMDGPU Performance Profile
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for c in /sys/class/drm/card[0-9]*/device; do [[ -f "$c/power_dpm_force_performance_level" ]] && echo high > "$c/power_dpm_force_performance_level"; done'
ExecStop=/bin/bash -c 'for c in /sys/class/drm/card[0-9]*/device; do [[ -f "$c/power_dpm_force_performance_level" ]] && echo auto > "$c/power_dpm_force_performance_level"; done'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable covenant-amdgpu-perf.service 2>/dev/null || true

# --- 21. Módulos no boot ---
echo "  -> Módulos..."
mkdir -p /etc/modules-load.d
cat >> /etc/modules-load.d/covenant.conf << 'EOF'
msr
cpuid
coretemp
EOF

# --- 22. Kernel Covenant (serviço de primeiro boot) ---
echo "  -> Kernel linux-covenant (instalação direta no airootfs)..."
COVENANT_PKGS_DIR="/root/covenant-pkgs"

if ls "${COVENANT_PKGS_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst &>/dev/null 2>&1; then

    # Instala via extração direta com bsdtar — sem pacman, sem keyring, sem prompts.
    # O pacman -U falha no chroot porque:
    #   1. Não tem as chaves do CachyOS para verificar dependências
    #   2. O provider 'initramfs' tem 4 opções e pede confirmação interativa
    # bsdtar extrai o conteúdo do .pkg.tar.zst diretamente para / como root faria.
    KERNEL_OK=false
    for pkg in "${COVENANT_PKGS_DIR}"/linux-covenant*.pkg.tar.zst; do
        echo "     Extraindo: $(basename "${pkg}")..."
        bsdtar -xf "${pkg}" -C / \
            --exclude='.PKGINFO' \
            --exclude='.INSTALL' \
            --exclude='.MTREE' \
            --exclude='.BUILDINFO' \
            --exclude='.CHANGELOG' \
            2>/dev/null && echo "     OK: $(basename "${pkg}")" || echo "     [!] Falha: $(basename "${pkg}")"
    done

    # Verifica se o vmlinuz foi extraído — procura por qualquer nome possível
    VMLINUZ=""
    # Nomes possíveis em kernels CachyOS/Arch:
    for candidate in \
        /boot/vmlinuz-linux-covenant \
        /boot/vmlinuz-linux-covenant-cachyos \
        /boot/vmlinuz-7.*-covenant* \
        /boot/vmlinuz-7.*covenant* \
        /boot/vmlinuz-*covenant*; do
        found=$(ls ${candidate} 2>/dev/null | head -1)
        if [[ -n "${found}" ]]; then
            VMLINUZ="${found}"
            break
        fi
    done

    # Fallback: qualquer vmlinuz novo em /boot
    if [[ -z "${VMLINUZ}" ]]; then
        VMLINUZ=$(ls -t /boot/vmlinuz* 2>/dev/null | head -1)
    fi

    if [[ -n "${VMLINUZ}" ]]; then
        echo "     vmlinuz encontrado: ${VMLINUZ}"
        KERNEL_OK=true

        # Cria symlink canônico se o nome for diferente do esperado
        if [[ "${VMLINUZ}" != "/boot/vmlinuz-linux-covenant" ]]; then
            ln -sf "${VMLINUZ}" /boot/vmlinuz-linux-covenant 2>/dev/null || true
            echo "     Symlink: /boot/vmlinuz-linux-covenant → ${VMLINUZ}"
        fi
    else
        echo "     [!] vmlinuz não encontrado em /boot após extração"
        echo "     Conteúdo de /boot:"
        ls -la /boot/ 2>/dev/null || echo "     /boot vazio"
        KERNEL_OK=false
    fi

    # Registra no banco do pacman para que o sistema saiba que está instalado
    # (evita que pacman tente reinstalar ou remova como órfão)
    PKGDB_DIR="/var/lib/pacman/local"
    mkdir -p "${PKGDB_DIR}"
    for pkg in "${COVENANT_PKGS_DIR}"/linux-covenant*.pkg.tar.zst; do
        PKGNAME=$(bsdtar -xOf "${pkg}" .PKGINFO 2>/dev/null | grep '^pkgname' | cut -d' ' -f3)
        PKGVER=$(bsdtar -xOf "${pkg}" .PKGINFO 2>/dev/null | grep '^pkgver' | cut -d' ' -f3)
        if [[ -n "${PKGNAME}" && -n "${PKGVER}" ]]; then
            ENTRY_DIR="${PKGDB_DIR}/${PKGNAME}-${PKGVER}"
            mkdir -p "${ENTRY_DIR}"
            bsdtar -xOf "${pkg}" .PKGINFO 2>/dev/null > "${ENTRY_DIR}/desc" || true
            echo "     Registrado no pacman DB: ${PKGNAME}-${PKGVER}"
        fi
    done

    if [[ "${KERNEL_OK}" == "true" ]]; then
        # Detecta a versão do kernel pelos módulos extraídos
        KVER=$(ls /lib/modules/ 2>/dev/null | grep -v 'extramodules' \
            | grep -E 'covenant|cachyos' | sort -V | tail -1)
        [[ -z "${KVER}" ]] && KVER=$(ls /lib/modules/ 2>/dev/null | sort -V | tail -1)
        echo "     Versão do kernel: ${KVER}"

        # Gera initramfs — necessário para o mkarchiso
        mkdir -p /etc/mkinitcpio.d
        cat > /etc/mkinitcpio.d/linux-covenant.preset << PRESET
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="${VMLINUZ}"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux-covenant.img"
fallback_image="/boot/initramfs-linux-covenant-fallback.img"
fallback_options="-S autodetect"
PRESET

        echo "     Gerando initramfs para ${KVER}..."
        if command -v mkinitcpio &>/dev/null; then
            # Tenta pelo preset primeiro
            mkinitcpio -p linux-covenant 2>/dev/null \
            || {
                # Fallback: pela versão do kernel
                [[ -n "${KVER}" ]] && \
                mkinitcpio -k "${KVER}" -g /boot/initramfs-linux-covenant.img 2>/dev/null
            }
        fi

        [[ -f /boot/initramfs-linux-covenant.img ]] \
            && echo "     initramfs-linux-covenant.img: $(du -h /boot/initramfs-linux-covenant.img | cut -f1)" \
            || echo "     [!] initramfs não gerado — kernel configurado no 1º boot."
    fi

    cat > /usr/local/bin/covenant-kernel-setup.sh << 'EOF'
#!/bin/bash
PKGS_DIR="/root/covenant-pkgs"
DONE_FILE="/var/lib/covenant/kernel-setup-done"
LOG="/var/log/covenant-kernel-setup.log"
exec > >(tee -a "${LOG}") 2>&1
echo "[$(date)] covenant-kernel-setup iniciado"

if ! pacman -Qi linux-covenant &>/dev/null; then
    ls "${PKGS_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst &>/dev/null \
        || { echo "[ERRO] Pacotes não encontrados"; exit 1; }
    pacman -U --noconfirm "${PKGS_DIR}"/linux-covenant-*.pkg.tar.zst \
        || { echo "[ERRO] Falha ao instalar linux-covenant"; exit 1; }
fi

[[ -f /boot/vmlinuz-linux-covenant ]] || { echo "[ERRO] vmlinuz não encontrado"; exit 1; }

pacman -Qi linux-cachyos &>/dev/null \
    && pacman -R --noconfirm linux-cachyos linux-cachyos-headers 2>/dev/null \
    && echo "linux-cachyos removido." || true

mkinitcpio -p linux-covenant 2>/dev/null && echo "initramfs gerado." || true

if command -v grub-mkconfig &>/dev/null && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg
    sed -i 's/CachyOS Linux/Covenant-CachyOS/g' /boot/grub/grub.cfg
    grub-set-default 0
    echo "GRUB atualizado → Covenant-CachyOS"
fi

rm -rf "${PKGS_DIR}" 2>/dev/null || true
mkdir -p /var/lib/covenant && touch "${DONE_FILE}"
echo "[$(date)] Concluído."
systemctl disable covenant-kernel-setup.service 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/covenant-kernel-setup.sh

    cat > /etc/systemd/system/covenant-kernel-setup.service << 'EOF'
[Unit]
Description=Covenant - Kernel Setup (primeiro boot)
After=multi-user.target
Before=display-manager.service
ConditionPathExists=!/var/lib/covenant/kernel-setup-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-kernel-setup.sh
RemainAfterExit=no
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable covenant-kernel-setup.service 2>/dev/null || true
    echo "     covenant-kernel-setup.service habilitado."
else
    echo "     [!] Pacotes linux-covenant não encontrados em ${COVENANT_PKGS_DIR}"
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
echo ""
echo "==> [RESUMO] Otimizações aplicadas:"
echo "    ✓ Limpeza: locales, docs, fontes CJK, ícones, man pages"
echo "    ✓ sysctl: BBR, rede, VM, writeback, NUMA"
echo "    ✓ zram: 8GB zstd"
echo "    ✓ I/O: NVMe/SSD/HDD scheduler + queue + readahead"
echo "    ✓ makepkg: -march=native -O2, threads auto"
echo "    ✓ ananicy-cpp + earlyoom"
echo "    ✓ Env: RADV/Mesa/Vulkan/Qt Wayland"
echo "    ✓ Serviços: irqbalance, power-profiles, fstrim diário"
echo "    ✓ journald: 512MB, 1 semana"
echo "    ✓ DNS: 1.1.1.1 + cache"
echo "    ✓ CPU governor: performance (1º boot)"
echo "    ✓ Limites: nofile=1M, coredump=off"
echo "    ✓ /tmp: 8GB tmpfs"
echo "    ✓ pacman: ParallelDownloads=5, SigLevel restaurado"
echo "    ✓ Kernel cmdline: intel_pstate=disable, mitigations=off, nvme_core ps=0"
echo "    ✓ BORE: sched_latency=3ms, autogroup=1"
echo "    ✓ AMDGPU: power profile=high"
echo "    ✓ HW watchdog: iTCO_wdt blacklisted"
echo "    ✓ Coredumps: desabilitados"
echo "    ✓ Hugepages: 512x2MB"
echo "    ✓ Módulos: coretemp, msr, cpuid"
echo "    ✓ Kernel: linux-covenant (1º boot)"
echo ""
