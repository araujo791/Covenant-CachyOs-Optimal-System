#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.


# Deleta o pacote corrompido
sudo rm -f /var/cache/pacman/pkg/libnotify-0.8.8-1-x86_64.pkg.tar.zst

# Re-inicia keyring do zero
sudo rm -rf /etc/pacman.d/gnupg
sudo pacman-key --init
sudo pacman-key --populate archlinux cachyos

# Re-sync
sudo pacman -Syy

# Build
sudo rm -rf ~/Covenant-CachyOs/cachyos-live-iso/build /tmp/cachyos-iso-build-*


set -euo pipefail

# ---------------------------------------------------------------------------
# Funções de log
# ---------------------------------------------------------------------------
_log_step() { echo ""; echo "===> [PASSO] $*"; }
_log_ok()   { echo "    [OK] $*"; }
_log_warn() { echo "    [AVISO] $*" >&2; }
_log_fail() { echo ""; echo "    [ERRO] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Diretório base = pasta onde este script está localizado
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/cachyos-live-iso"
REPO_URL="https://github.com/CachyOS/CachyOS-Live-ISO.git"

# ---------------------------------------------------------------------------
# Parâmetros gerais
# ---------------------------------------------------------------------------
build_list_iso="desktop"
clean_first=true
verbose=false
build_in_ram=false
remove_build_dir=false

REQUIRED_PKGS=(archiso mkinitcpio-archiso git squashfs-tools grub)

# ---------------------------------------------------------------------------
# Pacotes desnecessários para este hardware
# Xeon E5-2680v4 + AMD RX 560 + Ethernet r8169 (sem WiFi/NVIDIA)
# ---------------------------------------------------------------------------
HW_REMOVE_PKGS=(
    amd-ucode
    linux-cachyos-nvidia-open
    linux-cachyos-lts-nvidia-open
    linux-cachyos-zfs
    linux-cachyos-lts
    linux-cachyos-lts-zfs
    nvidia-utils
    lib32-nvidia-utils
    b43-fwcutter
    iw iwd wpa_supplicant wireless_tools wireless-regdb
    mobile-broadband-provider-info modemmanager
    rp-pppoe usb_modeswitch usbmuxd wvdial xl2tpd linux-atm
    vpnc openvpn
    steam lutris heroic-games-launcher-bin
    lib32-gamemode mangohud lib32-mangohud
    goverlay gamescope
    wine-staging winetricks protontricks
    vkd3d lib32-vkd3d dxvk-mingw-git
    discord protonup-qt bottles
    lib32-vulkan-radeon lib32-mesa lib32-vulkan-icd-loader
    lib32-libva-mesa-driver lib32-mesa-vdpau rocm-opencl-runtime
    irssi lftp lynx mc occt
)

# ---------------------------------------------------------------------------
# Pacotes de performance a garantir
# (power-profiles-daemon removido: conflita com governor performance fixo)
# (preload removido: existe apenas no AUR — mkarchiso só instala de repos
#  oficiais. Para usar, instale via AUR no sistema já instalado.
#  Alternativas oficiais já incluídas: systemd-oomd + readahead do kernel.)
# ---------------------------------------------------------------------------
PERFORMANCE_PKGS=(
    vulkan-radeon
    vulkan-icd-loader
    gamemode
    irqbalance
    zram-generator
    f2fs-tools
    ananicy-cpp
    earlyoom
    ccache
    profile-sync-daemon
    thermald
    cpupower
)

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------
usage() {
    echo ""
    echo "Uso: ${0##*/} [opções]"
    echo "    -c    Não limpar diretório de trabalho"
    echo "    -r    Build em RAM (recomendado — 64GB disponíveis)"
    echo "    -w    Remover diretório de build após gerar a ISO"
    echo "    -p    Perfil [padrão: ${build_list_iso}]"
    echo "    -v    Verbose"
    echo "    -h    Ajuda"
    echo ""
    exit "$1"
}

opts='p:cvhrw'
while getopts "${opts}" arg; do
    case "${arg}" in
        c) clean_first=false ;;
        p) build_list_iso="$OPTARG" ;;
        r) build_in_ram=true ;;
        w) remove_build_dir=true ;;
        v) verbose=true ;;
        h) usage 0 ;;
        ?) echo "Argumento inválido: '${arg}'"; usage 1 ;;
        *) echo "Argumento inválido: '${arg}'"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

# ---------------------------------------------------------------------------
# Verbose mode
# ---------------------------------------------------------------------------
if [[ "$verbose" == "true" ]]; then
    set -x
fi

# ---------------------------------------------------------------------------
# Cleanup trap — limpa resíduos ao sair (erro ou sucesso)
# ---------------------------------------------------------------------------
_TMPFS_MOUNTED=""
cleanup() {
    local exit_code=$?
    set +e
    if [[ -n "${_TMPFS_MOUNTED}" && -d "${_TMPFS_MOUNTED}" ]]; then
        umount "${_TMPFS_MOUNTED}" 2>/dev/null || true
        rmdir "${_TMPFS_MOUNTED}" 2>/dev/null || true
    fi
    if [[ "$remove_build_dir" == "true" && -n "${work_dir:-}" && -d "${work_dir}" ]]; then
        _log_step "Removendo diretório de build: ${work_dir}"
        rm -rf "${work_dir}"
        _log_ok "Diretório de build removido."
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "==> Build falhou com código $exit_code."
    fi
    exit $exit_code
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
_log_step "Verificando privilégios..."
[[ $EUID -eq 0 ]] || _log_fail "Execute com: sudo bash ${0##*/}"
_log_ok "Executando como root."

# ---------------------------------------------------------------------------
# Dependências do host
# ---------------------------------------------------------------------------
_log_step "Verificando dependências do host..."
missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if pacman -Qi "$pkg" &>/dev/null; then
        _log_ok "$pkg — OK"
    else
        _log_warn "$pkg — ausente"
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    _log_step "Instalando dependências ausentes: ${missing[*]}"
    pacman -Sy --noconfirm || _log_fail "Falha ao sincronizar pacman."
    pacman -S --needed --noconfirm "${missing[@]}" \
        || _log_fail "Falha ao instalar: ${missing[*]}"
    for pkg in "${missing[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            _log_ok "$pkg — instalado"
        else
            _log_fail "Não foi possível instalar: $pkg"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Clonar ou atualizar repositório
# ---------------------------------------------------------------------------
_log_step "Verificando repositório CachyOS-Live-ISO..."
if [[ -d "${REPO_DIR}/.git" ]]; then
    _log_ok "Repositório existe. Atualizando..."
    git -C "${REPO_DIR}" pull --ff-only \
        || _log_warn "Alterações locais — continuando com versão atual."
    _log_ok "Repositório atualizado."
else
    [[ -d "${REPO_DIR}" ]] && rm -rf "${REPO_DIR}"
    _log_step "Clonando ${REPO_URL}..."
    git clone "${REPO_URL}" "${REPO_DIR}" \
        || _log_fail "Falha ao clonar. Verifique a conexão."
    _log_ok "Repositório clonado."
fi

# Variáveis de paths
ARCHISO="${REPO_DIR}/archiso"
PACKAGES="${ARCHISO}/packages.x86_64"
PACKAGES_DESKTOP="${ARCHISO}/packages_desktop.x86_64"
PROFILEDEF="${ARCHISO}/profiledef.sh"
UTIL_ISO="${REPO_DIR}/util-iso.sh"

# ---------------------------------------------------------------------------
# Ler iso_name do profiledef.sh
# ---------------------------------------------------------------------------
_log_step "Lendo configurações do profiledef.sh..."
[[ -r "${PROFILEDEF}" ]] || _log_fail "profiledef.sh não encontrado."
ISO_NAME_RAW=$(grep '^iso_name=' "${PROFILEDEF}" | head -1 | cut -d'=' -f2- | tr -d '"'"'")
ISO_NAME_SAFE="${ISO_NAME_RAW// /_}"
_log_ok "iso_name : '${ISO_NAME_RAW}'"
_log_ok "Prefixo  : '${ISO_NAME_SAFE}-'"

# ---------------------------------------------------------------------------
# iso_name override — preserva nome customizado definido no profiledef.sh
# O build respeita qualquer iso_name que o usuário tenha editado no profiledef.
# Para forçar um nome diferente sem editar o profiledef, defina antes de rodar:
#   export ISO_NAME_OVERRIDE="Covenant-CachyOS"
# ---------------------------------------------------------------------------
if [[ -n "${ISO_NAME_OVERRIDE:-}" ]]; then
    _log_step "Aplicando iso_name override: '${ISO_NAME_OVERRIDE}'..."
    sed -i "s/^iso_name=.*/iso_name=\"${ISO_NAME_OVERRIDE}\"/" "${PROFILEDEF}"
    ISO_NAME_RAW="${ISO_NAME_OVERRIDE}"
    ISO_NAME_SAFE="${ISO_NAME_RAW// /_}"
    _log_ok "iso_name definido para: '${ISO_NAME_RAW}'"
fi

# ---------------------------------------------------------------------------
# Remover bios.syslinux do profiledef — boot UEFI only
# Xeon E5-2680v4 suporta UEFI nativo. BIOS/Legacy desnecessário.
# Sem isso, mkarchiso tenta copiar isolinux.bin → xorriso falha.
# ---------------------------------------------------------------------------
_log_step "Configurando boot UEFI-only (removendo bios.syslinux)..."

if grep -q 'bios.syslinux' "${PROFILEDEF}" 2>/dev/null; then
    sed -i "s/bootmodes=.*/bootmodes=('uefi.grub')/" "${PROFILEDEF}"
    _log_ok "profiledef.sh: bootmodes alterado para UEFI-only."
else
    _log_ok "profiledef.sh: bios.syslinux já ausente."
fi

# Remove diretório syslinux do perfil (não será usado)
if [[ -d "${ARCHISO}/syslinux" ]]; then
    rm -rf "${ARCHISO}/syslinux"
    _log_ok "Diretório syslinux/ removido do perfil."
fi

# ---------------------------------------------------------------------------
# Aplicar packages customizados
# NOTA: util-iso.sh copia packages_desktop → packages antes do
# mkarchiso, por isso copiamos para AMBOS os arquivos.
# ---------------------------------------------------------------------------
_log_step "Aplicando packages.x86_64 customizado..."

if [[ -f "${SCRIPT_DIR}/packages.x86_64" ]]; then
    cp "${SCRIPT_DIR}/packages.x86_64" "${PACKAGES}"
    cp "${SCRIPT_DIR}/packages.x86_64" "${PACKAGES_DESKTOP}"
    total_p=$(grep -cve '^#\|^$' "${PACKAGES}")
    _log_ok "Aplicado em packages.x86_64 e packages_desktop.x86_64 (${total_p} pacotes)."
else
    _log_warn "packages.x86_64 não encontrado em ${SCRIPT_DIR}/ — usando original do repo."
fi

# ---------------------------------------------------------------------------
# Otimizar packages para o hardware
# ---------------------------------------------------------------------------
_log_step "Otimizando packages para hardware alvo..."

removed=()
for pkg in "${HW_REMOVE_PKGS[@]}"; do
    if grep -q "^${pkg}$" "${PACKAGES}" 2>/dev/null; then
        sed -i "/^${pkg}$/d" "${PACKAGES}"
        sed -i "/^${pkg}$/d" "${PACKAGES_DESKTOP}"
        removed+=("$pkg")
    fi
done
if [[ ${#removed[@]} -gt 0 ]]; then
    _log_ok "Removidos:"
    for p in "${removed[@]}"; do echo "      - $p"; done
else
    _log_ok "Nenhum pacote desnecessário encontrado."
fi

added=()
for pkg in "${PERFORMANCE_PKGS[@]}"; do
    if ! grep -q "^${pkg}$" "${PACKAGES}" 2>/dev/null; then
        echo "${pkg}" >> "${PACKAGES}"
        echo "${pkg}" >> "${PACKAGES_DESKTOP}"
        added+=("$pkg")
    fi
done
if [[ ${#added[@]} -gt 0 ]]; then
    _log_ok "Adicionados (performance):"
    for p in "${added[@]}"; do echo "      + $p"; done
else
    _log_ok "Pacotes de performance já presentes."
fi

# ---------------------------------------------------------------------------
# Pacotes OBRIGATÓRIOS para o boot da ISO funcionar
# (mkarchiso copia syslinux/grub/kernel de DENTRO do airootfs, não do host!)
# Garante presença independente de packages.x86_64 customizado ou remoções.
# ---------------------------------------------------------------------------
ISO_BOOT_REQUIRED=(
    grub
    efibootmgr
    mkinitcpio
    mkinitcpio-archiso
    linux-cachyos
    intel-ucode
)

for pkg in "${ISO_BOOT_REQUIRED[@]}"; do
    if ! grep -q "^${pkg}$" "${PACKAGES}" 2>/dev/null; then
        echo "${pkg}" >> "${PACKAGES}"
        echo "${pkg}" >> "${PACKAGES_DESKTOP}"
        _log_warn "Boot obrigatório adicionado: ${pkg}"
    fi
done

total=$(grep -cve '^#\|^$' "${PACKAGES}")
_log_ok "Total de pacotes: ${total}"


# ---------------------------------------------------------------------------
# Limpeza do airootfs — remove ~1.2GB desnecessários antes do squashfs
# Vilões identificados: fonts 559MB, locale 431MB, doc 227MB, icons 150MB
# ---------------------------------------------------------------------------
_log_step "Criando script de limpeza do airootfs..."

CLEANUP_SCRIPT="${ARCHISO}/airootfs/root/cleanup-airootfs.sh"
mkdir -p "${ARCHISO}/airootfs/root"

cat > "${CLEANUP_SCRIPT}" << 'CLEANUP'
#!/bin/bash
set -euo pipefail

# Covenant CachyOS — limpeza + otimizações do airootfs
echo "==> [LIMPEZA] Removendo arquivos desnecessários..."

# 1. Locales — mantém só pt_BR, en_US, en_GB (~430MB → ~5MB)
echo "  -> Limpando locales..."
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'pt_BR' ! -name 'en_US' ! -name 'en_GB' \
    -exec rm -rf {} + 2>/dev/null || true

# 2. Documentação — remove completamente (~227MB)
echo "  -> Removendo documentação..."
rm -rf /usr/share/doc/* 2>/dev/null || true
rm -rf /usr/share/info/* 2>/dev/null || true
rm -rf /usr/share/gtk-doc 2>/dev/null || true

# 3. Fontes CJK pesadas (~559MB → ~80MB)
echo "  -> Limpando fontes CJK..."
find /usr/share/fonts -mindepth 1 -maxdepth 1 -type d \
    \( -name "*CJK*" -o -name "*cjk*" -o -name "*Noto*CJK*" \) \
    -exec rm -rf {} + 2>/dev/null || true

# 4. Ícones — mantém só breeze e hicolor (~150MB → ~30MB)
echo "  -> Limpando ícones..."
find /usr/share/icons -mindepth 1 -maxdepth 1 -type d \
    ! -name 'breeze' ! -name 'breeze-dark' \
    ! -name 'hicolor' ! -name 'Adwaita' \
    -exec rm -rf {} + 2>/dev/null || true

# 5. Man pages
echo "  -> Removendo man pages..."
rm -rf /usr/share/man/* 2>/dev/null || true

# 6. Dados nmap
echo "  -> Removendo dados nmap..."
rm -rf /usr/share/nmap 2>/dev/null || true

# 7. Vozes espeak — mantém só pt e en
echo "  -> Limpando vozes espeak..."
find /usr/share/espeak-ng-data -name "*.dict" \
    ! -name "pt*.dict" ! -name "en*.dict" \
    -delete 2>/dev/null || true

# 8. Cache de pacotes dentro do airootfs
echo "  -> Limpando cache de pacotes..."
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
rm -rf /var/lib/pacman/sync/* 2>/dev/null || true

# 9. Logs desnecessários
echo "  -> Limpando logs..."
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true

# 10. Arquivos .pacnew / .pacsave
echo "  -> Removendo .pacnew/.pacsave..."
find /etc -name "*.pacnew" -o -name "*.pacsave" -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Cursor theme — sobrescreve após instalação dos pacotes
# cachyos-kde-settings instala esses arquivos, sobrescrevemos com Adwaita
# ---------------------------------------------------------------------------
echo "  -> Configurando cursor theme Adwaita..."

mkdir -p /etc/skel/.config/gtk-3.0
mkdir -p /etc/skel/.config/gtk-4.0
mkdir -p /etc/skel/.icons/default

cat > /etc/skel/.config/gtk-3.0/settings.ini << GTKEOF
[Settings]
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
GTKEOF

cat > /etc/skel/.config/gtk-4.0/settings.ini << GTK4EOF
[Settings]
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
GTK4EOF

cat > /etc/skel/.icons/default/index.theme << ICONEOF
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Adwaita
ICONEOF

cat > /etc/skel/.config/kcminputrc << KDEEOF
[Mouse]
cursorTheme=Adwaita
cursorSize=24
KDEEOF

# ===========================================================================
# BLOCO DE OTIMIZAÇÕES DE SISTEMA
# Xeon E5-2680v4 (14c/28t) + AMD RX 560 + 64GB ECC RAM
# ===========================================================================

echo ""
echo "==> [OTIMIZAÇÕES] Aplicando tuning de sistema..."

# ---------------------------------------------------------------------------
# 1. sysctl — prioridade 90 para não brigar com CachyOS (que usa 99)
#    Aplica só o que o CachyOS não define por padrão
# ---------------------------------------------------------------------------
echo "  -> Configurando sysctl..."
mkdir -p /etc/sysctl.d

cat > /etc/sysctl.d/90-covenant.conf << 'SYSCTL'
# =============================================================
# Covenant CachyOS — sysctl complementar (prioridade 90)
# NÃO sobrescreve vm.swappiness/dirty do CachyOS (zram-tuned)
# Xeon E5-2680v4 + 64GB ECC RAM
# =============================================================

# --- Rede: BBR + fq ---
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

# --- VM: apenas o que CachyOS não toca ---
vm.max_map_count = 2097152
kernel.pid_max = 4194304
kernel.numa_balancing = 1

# --- I/O writeback para desktop ---
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.vfs_cache_pressure = 50

# --- Scheduler: latência para desktop ---
kernel.sched_autogroup_enabled = 1
# BORE/sched-ext não usa sched_* do CFS clássico — parâmetros removidos
kernel.sched_cfs_bandwidth_slice_us = 3000


# --- Segurança mínima mantida ---
kernel.dmesg_restrict = 0
kernel.kptr_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 1

# --- Misc ---
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152
kernel.io_delay_type = 0
SYSCTL

echo "     sysctl 90-covenant.conf criado."

# ---------------------------------------------------------------------------
# 2. BBR — módulo carregado no boot via modules-load.d
# ---------------------------------------------------------------------------
echo "  -> Configurando módulo BBR..."
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
echo "     tcp_bbr adicionado a modules-load.d."

# ---------------------------------------------------------------------------
# 3. zram — 1GB conforme preferência do usuário
# ---------------------------------------------------------------------------
echo "  -> Configurando zram..."

cat > /etc/systemd/zram-generator.conf << 'ZRAM'
# Covenant CachyOS — zram (1GB por escolha do usuário)
[zram0]
zram-size = 1024
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

echo "     zram: 1GB zstd configurado."

# ---------------------------------------------------------------------------
# 4. I/O — NVMe, SSD, HDD: scheduler + queue depth + readahead + writeback
# ---------------------------------------------------------------------------
echo "  -> Configurando I/O (NVMe / SSD / HDD)..."
mkdir -p /etc/udev/rules.d

cat > /etc/udev/rules.d/60-io-scheduler.rules << 'IOSCHEDULER'
# =============================================================================
# Covenant CachyOS — I/O tuning completo
# =============================================================================

# --- NVMe ---
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nomerges}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/rq_affinity}="2"

# --- SSD SATA (rotational=0) ---
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/wbt_lat_usec}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"

# --- HDD (rotational=1) ---
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/nr_requests}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="2048"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/add_random}="1"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/rq_affinity}="1"
IOSCHEDULER

echo "     I/O: NVMe/SSD/HDD scheduler + queue depth + readahead configurados."

# ---------------------------------------------------------------------------
# 5. makepkg.conf — -march=native, paralelismo total, ccache
# ---------------------------------------------------------------------------
echo "  -> Configurando makepkg.conf..."

MAKEPKG_CONF="/etc/makepkg.conf"
if [[ -f "${MAKEPKG_CONF}" ]]; then
    NPROC=$(nproc 2>/dev/null || echo 4)
    sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i 's/^CXXFLAGS=.*/CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=3 -C target-cpu=native"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i "s/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/" "${MAKEPKG_CONF}" 2>/dev/null || true
    # ccache: ativa para compilações repetidas
    if ! grep -q 'ccache' "${MAKEPKG_CONF}" 2>/dev/null; then
        sed -i 's|^BUILDENV=.*|BUILDENV=(!distcc color ccache check !sign)|' "${MAKEPKG_CONF}" 2>/dev/null || true
    fi
    echo "     makepkg: -march=native -O2, ${NPROC} threads, ccache ativo."
else
    echo "     makepkg.conf não encontrado — pulando."
fi

# ccache: config global
mkdir -p /etc/ccache.conf.d
cat > /etc/ccache.conf << 'CCACHE'
max_size = 10G
compression = true
compression_level = 1
CCACHE

echo "     ccache: 10GB max, compressão ativada."

# ---------------------------------------------------------------------------
# 6. ananicy-cpp — regras de prioridade expandidas
# ---------------------------------------------------------------------------
echo "  -> Configurando ananicy-cpp..."

systemctl enable ananicy-cpp.service 2>/dev/null \
    || systemctl enable ananicy.service 2>/dev/null \
    || echo "     ananicy: será habilitado no primeiro boot."

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

echo "     ananicy-cpp: regras expandidas criadas."

# ---------------------------------------------------------------------------
# 7. earlyoom
# ---------------------------------------------------------------------------
echo "  -> Configurando earlyoom..."

mkdir -p /etc/default
cat > /etc/default/earlyoom << 'EARLYOOM'
EARLYOOM_ARGS="-m 5 -M 3 -s 5 -S 3 --avoid '(sshd|systemd|init)' --prefer '(chrome|firefox|electron|Web Content)' -r 60 -N /usr/bin/notify-send"
EARLYOOM

systemctl enable earlyoom.service 2>/dev/null \
    && echo "     earlyoom habilitado." \
    || echo "     earlyoom: será habilitado no primeiro boot."

# ---------------------------------------------------------------------------
# 8. Variáveis de ambiente — AMD/Vulkan/Mesa/Qt
#    (MESA_NO_ERROR removido: pode causar crashes em apps OpenGL)
#    (RADV_PERFTEST=aco removido: ACO é padrão desde Mesa 20.2)
#    (XCURSOR unificado aqui — não duplicado)
# ---------------------------------------------------------------------------
echo "  -> Configurando variáveis de ambiente..."

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

echo "     Variáveis de ambiente configuradas."

# ---------------------------------------------------------------------------
# 9. Serviços systemd
# ---------------------------------------------------------------------------
echo "  -> Configurando serviços systemd..."

ENABLE_SERVICES=(
    irqbalance.service
    fstrim.timer
    earlyoom.service
    thermald.service
    systemd-oomd.service
)

for svc in "${ENABLE_SERVICES[@]}"; do
    if systemctl enable "${svc}" 2>/dev/null; then
        echo "     [+] ${svc}"
    else
        echo "     [!] ${svc} — não encontrado (ok)"
    fi
done

# fstrim: muda cadência de semanal para diária
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/covenant-daily.conf << 'FSTRIMOVERRIDE'
[Timer]
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=1800
FSTRIMOVERRIDE

echo "     fstrim.timer: cadência alterada para diária."

DISABLE_SERVICES=(
    ModemManager.service
    bluetooth.service
)

for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable "${svc}" 2>/dev/null || true
done

echo "     Serviços desnecessários desabilitados."

# ---------------------------------------------------------------------------
# 10. journald — limita uso de disco
# ---------------------------------------------------------------------------
echo "  -> Configurando journald..."
mkdir -p /etc/systemd/journald.conf.d

cat > /etc/systemd/journald.conf.d/covenant.conf << 'JOURNALD'
[Journal]
SystemMaxUse=512M
SystemKeepFree=1G
MaxRetentionSec=1week
Compress=yes
JOURNALD

# ---------------------------------------------------------------------------
# 11. DNS com cache local + DoT
# ---------------------------------------------------------------------------
echo "  -> Configurando DNS..."
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

systemctl enable systemd-resolved.service 2>/dev/null || true
echo "     DNS: Cloudflare + Quad9 com DNS-over-TLS."

# ---------------------------------------------------------------------------
# 12. CPU governor — serviço de primeiro boot
#     Detecta CPUs reais no sistema instalado (não da máquina de build)
# ---------------------------------------------------------------------------
echo "  -> Configurando CPU governor (serviço de primeiro boot)..."

mkdir -p /etc/systemd/system /usr/local/bin /etc/udev/rules.d

cat > /usr/local/bin/covenant-cpu-governor-setup.sh << 'CPUSCRIPT'
#!/bin/bash
# Covenant — CPU governor setup via cpupower
# Funciona com acpi-cpufreq (E5-2680v4 não usa intel_pstate)
set -euo pipefail

cpupower frequency-set -g performance 2>/dev/null || {
    # fallback: escrever direto no sysfs
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

systemctl enable covenant-cpu-governor-setup.service 2>/dev/null \
    && echo "     covenant-cpu-governor-setup.service habilitado." \
    || echo "     [!] será habilitado no primeiro boot."

# Carregar acpi_cpufreq antes do udev para que cpufreq/scaling_governor exista
echo "acpi_cpufreq" > /etc/modules-load.d/acpi_cpufreq.conf

# udev apenas para hotplug (CPU adicionada após boot)
cat > /etc/udev/rules.d/50-cpu-governor.rules << 'CPUUDEV'
SUBSYSTEM=="cpu", ACTION=="add", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="performance"
CPUUDEV

echo "     CPU governor: performance (acpi_cpufreq + udev hotplug)."

# ---------------------------------------------------------------------------
# 13. Limites de sistema
# ---------------------------------------------------------------------------
echo "  -> Configurando limites de sistema..."

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

# ---------------------------------------------------------------------------
# 14. /tmp em RAM — via tmp.mount (sobrevive à instalação, ao contrário do fstab)
# ---------------------------------------------------------------------------
echo "  -> Configurando /tmp em tmpfs via tmp.mount..."

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/tmp.mount << 'TMPMOUNT'
[Unit]
Description=Temporary Directory /tmp (Covenant — 16GB RAM)
Documentation=man:tmp(5)
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
echo "     /tmp: tmpfs 16GB via systemd tmp.mount."

# ---------------------------------------------------------------------------
# 15. pacman.conf — downloads paralelos agressivos
# ---------------------------------------------------------------------------
echo "  -> Otimizando pacman..."

PACMAN_CONF_FILE="/etc/pacman.conf"
if [[ -f "${PACMAN_CONF_FILE}" ]]; then
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "${PACMAN_CONF_FILE}" 2>/dev/null || true
    sed -i 's/^#Color$/Color/' "${PACMAN_CONF_FILE}" 2>/dev/null || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "${PACMAN_CONF_FILE}" 2>/dev/null || true
    echo "     pacman: downloads paralelos=10, Color, VerbosePkgLists."
fi

# ---------------------------------------------------------------------------
# 16. Kernel cmdline — parâmetros de performance
#
#     Abordagem dupla:
#       a) /etc/default/grub.d/covenant-cmdline.cfg  → GRUB (grub-mkconfig)
#       b) /etc/kernel/cmdline.d/covenant.conf        → systemd-boot / UKI
#
#     Parâmetros:
#       (intel_pstate não necessário: E5-2680v4 usa acpi-cpufreq por padrão)
#       (governor definido via covenant-cpu-governor-setup.service com cpupower)
#       nvme_core.default_ps_max_latency_us=0 → sem power saving no NVMe (default_ps_state removido em kernels recentes)
#       intel_idle.max_cstate=1              → complementa processor.max_cstate=1
#       nvme_core.io_timeout=4294967295      → timeout máximo p/ cargas pesadas
#       mitigations=off           → +10-20% performance (desktop sem acesso público)
#       nowatchdog nmi_watchdog=0 → libera IRQ, reduz jitter
#       skew_tick=1               → desincroniza ticks em multi-core/NUMA
#       transparent_hugepage=madvise → THP só sob demanda
#       amdgpu.ppfeaturemask=0xffffffff → OverDrive habilitado na RX 560
#       pcie_aspm=off             → sem power management no PCIe (elimina stutters)
#       split_lock_detect=off     → evita SIGBUS em workloads legados
#       quiet loglevel=3          → boot limpo
#       processor.max_cstate=1    → impede deep C-states no Xeon (latência)
#
#     NOTA DE SEGURANÇA: mitigations=off desabilita proteções contra Spectre,
#     Meltdown, etc. Aceitável APENAS em desktop isolado sem acesso público.
# ---------------------------------------------------------------------------
echo "  -> Configurando kernel cmdline de performance..."

COVENANT_CMDLINE="nvme_core.default_ps_max_latency_us=0 nvme_core.io_timeout=4294967295 mitigations=off nowatchdog nmi_watchdog=0 skew_tick=1 transparent_hugepage=madvise amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off split_lock_detect=off processor.max_cstate=1 intel_idle.max_cstate=1 quiet loglevel=3"

# --- a) GRUB ---
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/covenant-cmdline.cfg << GRUBCMD
# Covenant CachyOS — parâmetros de performance
GRUB_CMDLINE_LINUX_DEFAULT="${COVENANT_CMDLINE}"
GRUBCMD

# NÃO roda grub-mkconfig no chroot — será executado pelo Calamares na instalação
echo "     GRUB: /etc/default/grub.d/covenant-cmdline.cfg instalado."

# --- b) systemd-boot / UKI ---
mkdir -p /etc/kernel/cmdline.d
echo "${COVENANT_CMDLINE}" > /etc/kernel/cmdline.d/covenant.conf
echo "     systemd-boot/UKI: /etc/kernel/cmdline.d/covenant.conf instalado."

# Hook pacman: regenera GRUB após update de kernel (targets específicos)
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

echo "     Hook pacman: grub-mkconfig automático (targets específicos)."

# ---------------------------------------------------------------------------
# 17. Módulos de kernel — blacklist desnecessários, tuning AMDGPU
# ---------------------------------------------------------------------------
echo "  -> Configurando módulos de kernel..."

cat > /etc/modprobe.d/covenant-blacklist.conf << 'BLACKLIST'
# Covenant — módulos desnecessários para este hardware
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
# Covenant — AMDGPU tuning para RX 560
options amdgpu gpu_recovery=1
options amdgpu deep_color=1
options amdgpu dc=1
options amdgpu dpm=1
AMDGPU

echo "     Módulos: blacklist + AMDGPU tuning configurados."

# ---------------------------------------------------------------------------
# 18. Coredump — desabilita para economia de espaço e segurança
# ---------------------------------------------------------------------------
echo "  -> Configurando coredump..."
mkdir -p /etc/systemd/coredump.conf.d

cat > /etc/systemd/coredump.conf.d/covenant.conf << 'COREDUMP'
[Coredump]
Storage=none
ProcessSizeMax=0
COREDUMP

echo "     Coredumps desabilitados."

# ---------------------------------------------------------------------------
# 19. profile-sync-daemon — perfis de browser em RAM
# ---------------------------------------------------------------------------
echo "  -> Configurando profile-sync-daemon..."

mkdir -p /etc/skel/.config/psd
cat > /etc/skel/.config/psd/psd.conf << 'PSD'
USE_OVERLAYFS="yes"
USE_BACKUPS="yes"
PSD

echo "     profile-sync-daemon: overlayfs habilitado para browsers."

# ---------------------------------------------------------------------------
# 20. IRQ affinity — distribui interrupções de GPU e NVMe nos cores certos
# ---------------------------------------------------------------------------
echo "  -> Configurando IRQ affinity (serviço de primeiro boot)..."

cat > /usr/local/bin/covenant-irq-affinity.sh << 'IRQSCRIPT'
#!/bin/bash
# Distribui interrupções de GPU e NVMe pelos cores de performance
# Xeon E5-2680v4: cores 0-13 físicos, 14-27 HT

# Desabilita irqbalance para NVMe e GPU (gerenciamos manualmente)
for irq in $(grep -E 'nvme|amdgpu' /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' '); do
    # Distribui nos primeiros 14 cores físicos
    echo "3fff" > /proc/irq/${irq}/smp_affinity 2>/dev/null || true
done

echo "covenant-irq-affinity: IRQs de NVMe/GPU distribuídas."
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

systemctl enable covenant-irq-affinity.service 2>/dev/null || true
echo "     IRQ affinity: distribuição NVMe/GPU configurada."

# ---------------------------------------------------------------------------
# 21. Huge Pages estáticas — acelera compiladores, VMs, apps com muita alocação
# ---------------------------------------------------------------------------
echo "  -> Configurando Huge Pages..."

cat >> /etc/sysctl.d/90-covenant.conf << 'HUGEPAGES'

# --- Huge Pages (2MB cada) ---
vm.nr_hugepages = 1024
HUGEPAGES

echo "     Huge Pages: 1024 x 2MB = 2GB reservados."

# ---------------------------------------------------------------------------
# 22. GPU RX 560 — serviço de overclock automático (performance level máximo)
# ---------------------------------------------------------------------------
echo "  -> Configurando GPU performance mode..."

cat > /usr/local/bin/covenant-gpu-performance.sh << 'GPUSCRIPT'
#!/bin/bash
# Covenant — AMD RX 560: força performance level máximo
sleep 5  # espera GPU estar pronta

GPU_PATH=$(for card in /sys/class/drm/card*/device; do
    [[ -f "$card/power_dpm_force_performance_level" ]] && echo "$card" && break
done)
if [[ -n "${GPU_PATH}" ]]; then
    echo "manual" > "${GPU_PATH}/power_dpm_force_performance_level"
    # Força clock máximo (último índice disponível)
    SCLK_MAX=$(cat "${GPU_PATH}/pp_dpm_sclk" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d ':')
    MCLK_MAX=$(cat "${GPU_PATH}/pp_dpm_mclk" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d ':')
    [[ -n "$SCLK_MAX" ]] && echo "$SCLK_MAX" > "${GPU_PATH}/pp_dpm_sclk"
    [[ -n "$MCLK_MAX" ]] && echo "$MCLK_MAX" > "${GPU_PATH}/pp_dpm_mclk"
    echo "covenant-gpu: RX 560 em performance máxima (sclk=$SCLK_MAX, mclk=$MCLK_MAX)"
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

systemctl enable covenant-gpu-performance.service 2>/dev/null || true
echo "     GPU: performance mode automático configurado."

# ---------------------------------------------------------------------------
# 23. profile-sync-daemon — habilitar por padrão para o usuário
# ---------------------------------------------------------------------------
echo "  -> Configurando profile-sync-daemon auto-start..."

mkdir -p /etc/skel/.config/systemd/user/default.target.wants
ln -sf /usr/lib/systemd/user/psd.service \
    /etc/skel/.config/systemd/user/default.target.wants/psd.service 2>/dev/null || true

echo "     psd: auto-start via user systemd (browsers em RAM)."

# ---------------------------------------------------------------------------
# 24. Script de verificação pós-instalação
# ---------------------------------------------------------------------------
echo "  -> Criando script de verificação..."

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
printf "%-30s %s\n" "psd (user):" "$(systemctl --user is-active psd 2>/dev/null || echo 'run: systemctl --user start psd')"
printf "%-30s %s\n" "DNS-over-TLS:" "$(resolvectl status 2>/dev/null | grep -o 'DNSOverTLS.*' | head -1 || echo 'n/a')"
printf "%-30s %s\n" "ccache size:" "$(ccache -s 2>/dev/null | grep 'cache size' || echo 'n/a')"
echo ""
echo "Tudo OK se: governor=performance, NVMe=[none], TCP=bbr, GPU=manual"
CHECKSCRIPT

chmod +x /usr/local/bin/covenant-check.sh
echo "     covenant-check.sh instalado — rode 'covenant-check.sh' pós-install."

# ===========================================================================
# FIM DAS OTIMIZAÇÕES
# ===========================================================================

echo ""
echo "==> [LIMPEZA] Concluída."
echo "    $(du -sh /usr/share 2>/dev/null | cut -f1) — /usr/share após limpeza"
echo ""
echo "==> [OTIMIZAÇÕES] Resumo aplicado:"
echo "    - sysctl: BBR, VM, rede, NUMA, scheduler latency, I/O writeback, hugepages"
echo "    - zram: 1GB zstd"
echo "    - I/O: NVMe(none+2048+rq_affinity), SSD(mq-deadline), HDD(bfq+readahead)"
echo "    - makepkg: -march=native -O2, threads auto, ccache 10GB"
echo "    - ananicy-cpp: regras compilação/WM/audio/terminal"
echo "    - earlyoom: kill em <3% RAM livre + notificação desktop"
echo "    - Env vars: RADV/Vulkan/VA-API/Qt Wayland"
echo "    - Serviços: irqbalance, fstrim(diário), earlyoom, thermald, oomd"
echo "    - journald: 512MB máx, 1 semana"
echo "    - DNS: Cloudflare/Quad9 com DNS-over-TLS"
echo "    - CPU governor: performance (primeiro boot + udev)"
echo "    - Limites: nofile=1M, nproc=131K, memlock=unlimited, audio rtprio=99"
echo "    - /tmp: tmpfs 16GB via systemd (sobrevive Calamares)"
echo "    - pacman: downloads paralelos=10"
echo "    - Kernel: mitigations=off, max_cstate=1, THP=madvise, AMDGPU overdrive, pcie_aspm=off"
echo "    - Módulos: blacklist nouveau/bluetooth/pcspkr, AMDGPU tuning"
echo "    - Coredumps: desabilitados"
echo "    - profile-sync-daemon: browser em RAM (overlayfs)"
echo "    - IRQ affinity: NVMe/GPU distribuídas nos cores físicos"
echo "    - ccache: compilação cacheada (10GB)"
echo "    - Huge Pages: 2GB (1024 x 2MB)"
echo "    - GPU: RX 560 performance mode automático (clock max)"
echo "    - psd: profile-sync-daemon auto-start para browsers"
echo "    - covenant-check.sh: script de verificação pós-install"
CLEANUP

chmod +x "${CLEANUP_SCRIPT}"
_log_ok "Script de limpeza + otimizações criado."

# Registra no customize_airootfs.sh (executado pelo mkarchiso no chroot)
CUSTOMIZE="${ARCHISO}/airootfs/root/customize_airootfs.sh"
if [[ -f "${CUSTOMIZE}" ]]; then
    if ! grep -q 'cleanup-airootfs.sh' "${CUSTOMIZE}"; then
        {
            echo ""
            echo "# Limpeza + Otimizações Covenant"
            echo "bash /root/cleanup-airootfs.sh"
        } >> "${CUSTOMIZE}"
        _log_ok "cleanup registrado em customize_airootfs.sh existente."
    else
        _log_ok "cleanup já está em customize_airootfs.sh."
    fi
else
    cat > "${CUSTOMIZE}" << 'CUSTEOF'
#!/bin/bash
# Covenant CachyOS — customize_airootfs
bash /root/cleanup-airootfs.sh
CUSTEOF
    chmod +x "${CUSTOMIZE}"
    _log_ok "customize_airootfs.sh criado com limpeza + otimizações."
fi

# ===========================================================================
# COVENANT POST-INSTALL — Script + first-boot service + Calamares hook
#
# Problema: o cleanup-airootfs.sh cria configs no live ISO, mas quando o
# Calamares instala no disco (modo online = pacstrap), o sistema instalado
# é LIMPO — configs não são copiadas. Solução com 3 camadas de redundância:
#
#   1. cleanup-airootfs.sh → configs no live ISO (já feito acima)
#   2. covenant-first-boot.service → roda covenant-post-install.sh no 1º boot
#      (funciona se Calamares copiar o filesystem — modo offline/unpackfs)
#   3. Calamares shellprocess hook → roda no chroot do target durante install
#      (funciona para modo online/pacstrap)
# ===========================================================================
_log_step "Criando covenant-post-install.sh no airootfs..."

COVENANT_PI="${ARCHISO}/airootfs/usr/local/bin/covenant-post-install.sh"
mkdir -p "$(dirname "${COVENANT_PI}")"

cat > "${COVENANT_PI}" << 'POSTINSTALL'
#!/bin/bash
# covenant-post-install.sh — Aplica TODAS as otimizações do Covenant CachyOS
# Hardware: Xeon E5-2680v4 (14c/28t) + AMD RX 560 + 64GB ECC RAM + NVMe
#
# Roda automaticamente via:
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

# Função helper: enable (+ start se não estiver em chroot)
_svc_enable() {
    local svc="$1"
    if $IN_CHROOT; then
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
POSTINSTALL

chmod +x "${COVENANT_PI}"
_log_ok "covenant-post-install.sh criado no airootfs."

# ---------------------------------------------------------------------------
# Serviço de primeiro boot — roda covenant-post-install.sh após instalação
# Funciona para modo offline/unpackfs do Calamares
# ---------------------------------------------------------------------------
_log_step "Criando serviço de primeiro boot..."

FIRSTBOOT_DIR="${ARCHISO}/airootfs/etc/systemd/system"
mkdir -p "${FIRSTBOOT_DIR}"

cat > "${FIRSTBOOT_DIR}/covenant-first-boot.service" << 'FIRSTBOOT'
[Unit]
Description=Covenant CachyOS - Apply optimizations on first boot
After=multi-user.target network.target
ConditionPathExists=!/var/lib/covenant-setup-done

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/usr/local/bin/covenant-post-install.sh && touch /var/lib/covenant-setup-done'
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
FIRSTBOOT

mkdir -p "${FIRSTBOOT_DIR}/multi-user.target.wants"
ln -sf /etc/systemd/system/covenant-first-boot.service \
    "${FIRSTBOOT_DIR}/multi-user.target.wants/covenant-first-boot.service"

_log_ok "covenant-first-boot.service criado e habilitado."

# ---------------------------------------------------------------------------
# Hook no Calamares — roda covenant-post-install.sh no chroot do target
# durante instalação online (pacstrap). O calamares-online.sh instala
# cachyos-calamares-next sob demanda; injetamos nosso módulo shellprocess
# logo após essa instalação.
# ---------------------------------------------------------------------------
_log_step "Configurando Calamares para pós-instalação Covenant..."

# Abordagem direta: criar configs em /etc/calamares/ no airootfs durante o build.
# O Calamares lê /etc/calamares/ com prioridade sobre /usr/share/calamares/.
# Funciona tanto para instalação online quanto offline, sem depender de
# patching de scripts em runtime.

CALAMARES_ETC="${ARCHISO}/airootfs/etc/calamares"
CALAMARES_SHARE="${ARCHISO}/airootfs/usr/share/calamares"
mkdir -p "${CALAMARES_ETC}/modules"

# 1. Criar shellprocess-covenant.conf em /etc/calamares/modules/
cat > "${CALAMARES_ETC}/modules/shellprocess-covenant.conf" << 'MODEOF'
---
dontChroot: false
timeout: 600
script:
    - command: "/usr/local/bin/covenant-post-install.sh && touch /var/lib/covenant-setup-done"
      timeout: 600
MODEOF
_log_ok "shellprocess-covenant.conf criado em /etc/calamares/modules/"

# 2. Copiar settings_online.conf para /etc/calamares/ e injetar shellprocess@covenant
#    /etc/calamares/ tem prioridade sobre /usr/share/calamares/ no Calamares.
SETTINGS_SRC="${CALAMARES_SHARE}/settings_online.conf"
SETTINGS_DST="${CALAMARES_ETC}/settings_online.conf"

if [[ -f "${SETTINGS_SRC}" ]]; then
    cp "${SETTINGS_SRC}" "${SETTINGS_DST}"

    # Adicionar instância covenant na seção instances:
    if ! grep -q 'covenant' "${SETTINGS_DST}"; then
        sed -i '/^instances:/a- id:       covenant
  module:   shellprocess
  config:   shellprocess-covenant.conf' "${SETTINGS_DST}"
    fi

    # Injetar shellprocess@covenant antes do umount na sequência exec:
    if ! grep -q 'shellprocess@covenant' "${SETTINGS_DST}"; then
        sed -i 's/  - umount/  - shellprocess@covenant\n  - umount/' "${SETTINGS_DST}"
    fi

    _log_ok "settings_online.conf copiado para /etc/calamares/ com shellprocess@covenant injetado."
else
    # Fallback: settings_online.conf não existe ainda no airootfs (será instalado
    # junto com o cachyos-calamares-next). Criamos um completo baseado no padrão
    # do CachyOS com shellprocess@covenant já incluído.
    _log_warn "settings_online.conf não encontrado em ${CALAMARES_SHARE} — criando fallback completo."
    cat > "${SETTINGS_DST}" << 'SETTEOF'
# SPDX-License-Identifier: CC0-1.0
---
modules-search: [ local ]

instances:
- id:       online
  module:   packages
  config:   packages_online.conf

- id:       online
  module:   welcome
  config:   welcome_online.conf

- id:       before-online
  module:   shellprocess
  config:   shellprocess-before-online.conf

- id:       modify_mk_hook
  module:   shellprocess
  config:   shellprocess_modify_mk_hook.conf

- id:       reset_mk_hook
  module:   shellprocess
  config:   shellprocess_reset_mk_hook.conf

- id:       initialize_pacman
  module:   shellprocess
  config:   shellprocess_initialize_pacman.conf

- id:       bootloader
  module:   packagechooser
  config:   packagechooser_bootloader.conf

- id:       desktop
  module:   packagechooser
  config:   packagechooser_desktop.conf

- id:       enable_ufw
  module:   shellprocess
  config:   shellprocess_enable_ufw.conf

- id:       btrfs_snapshot
  module:   shellprocess
  config:   shellprocess_btrfs_snapshot.conf

- id:       covenant
  module:   shellprocess
  config:   shellprocess-covenant.conf

sequence:
- show:
  - welcome@online
  - locale
  - keyboard
  - packagechooser@bootloader
  - partition
  - packagechooser@desktop
  - netinstall
  - users
  - summary
- exec:
  - partition
  - zfs
  - mount
  - shellprocess@modify_mk_hook
  - shellprocess@initialize_pacman
  - shellprocess@before-online
  - pacstrap
  - machineid
  - locale
  - keyboard
  - localecfg
  - chwd
  - packages@online
  - luksbootkeyfile
  - luksopenswaphookcfg
  - fstab
  - plymouthcfg
  - zfshostid
  - initcpiocfg
  - initcpio
  - users
  - networkcfg
  - displaymanager
  - hwclock
  - grubcfg
  - bootloader
  - shellprocess@reset_mk_hook
  - services-systemd
  - shellprocess
  - shellprocess@enable_ufw
  - shellprocess@btrfs_snapshot
  - shellprocess@covenant
  - umount
- show:
  - finished

branding: cachyos
prompt-install: true
dont-chroot: false
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: false
hide-back-and-next-during-exec: true
quit-at-end: false
SETTEOF
    _log_ok "settings_online.conf fallback criado com shellprocess@covenant."
fi

# ---------------------------------------------------------------------------
# Atualizar file_permissions no profiledef.sh
# ---------------------------------------------------------------------------
_log_step "Atualizando permissões no profiledef.sh..."

# Adiciona permissões para os novos scripts
if ! grep -q 'covenant-post-install' "${PROFILEDEF}" 2>/dev/null; then
    sed -i '/^)$/i\  ["/usr/local/bin/covenant-post-install.sh"]="0:0:755"' "${PROFILEDEF}" 2>/dev/null || true
    sed -i '/^)$/i\  ["/usr/local/bin/covenant-check.sh"]="0:0:755"' "${PROFILEDEF}" 2>/dev/null || true
    sed -i '/^)$/i\  ["/usr/local/bin/covenant-gpu-performance.sh"]="0:0:755"' "${PROFILEDEF}" 2>/dev/null || true
    sed -i '/^)$/i\  ["/usr/local/bin/covenant-irq-affinity.sh"]="0:0:755"' "${PROFILEDEF}" 2>/dev/null || true
    _log_ok "Permissões adicionadas ao profiledef.sh."
else
    _log_ok "Permissões já existem no profiledef.sh."
fi

# ---------------------------------------------------------------------------
# mkinitcpio.conf — NÃO sobrescrever
# O archiso usa hooks essenciais (archiso, archiso_loop_mnt)
# ---------------------------------------------------------------------------
_log_ok "mkinitcpio.conf — mantendo configuração original do archiso."

# ---------------------------------------------------------------------------
# Patch util-iso.sh — corrige mv hardcoded "cachyos-DATE.iso"
# O mkarchiso gera a ISO com o nome do profiledef (ISO_NAME_SAFE), mas
# util-iso.sh tenta mv de "cachyos-..." → falha. Corrigimos aqui.
# ---------------------------------------------------------------------------
_log_step "Verificando patch do util-iso.sh..."
[[ -r "${UTIL_ISO}" ]] || _log_fail "util-iso.sh não encontrado."

# Busca 'cachyos-$(date' no arquivo (sem aspas — está no meio de uma string)
if grep -qF 'cachyos-$(date' "${UTIL_ISO}"; then
    cp "${UTIL_ISO}" "${UTIL_ISO}.bak"
    sed -i 's|cachyos-$(date|'"${ISO_NAME_SAFE}"'-$(date|g' "${UTIL_ISO}"
    if grep -qF "${ISO_NAME_SAFE}-\$(date" "${UTIL_ISO}" || grep -qF "${ISO_NAME_SAFE}-\$(date" "${UTIL_ISO}"; then
        _log_ok "util-iso.sh corrigido: mv usa '${ISO_NAME_SAFE}-'."
    else
        # Verifica de outra forma (o sed pode ter funcionado com formato diferente)
        if grep -qF "${ISO_NAME_SAFE}" "${UTIL_ISO}"; then
            _log_ok "util-iso.sh corrigido: mv usa '${ISO_NAME_SAFE}-'."
        else
            cp "${UTIL_ISO}.bak" "${UTIL_ISO}"
            _log_warn "Patch falhou — restaurado original."
        fi
    fi
else
    if grep -qF "${ISO_NAME_SAFE}" "${UTIL_ISO}"; then
        _log_ok "util-iso.sh já usa '${ISO_NAME_SAFE}' — patch não necessário."
    else
        _log_warn "util-iso.sh: padrão 'cachyos-\$(date' não encontrado — mv pode falhar (cosmético)."
    fi
fi

# ---------------------------------------------------------------------------
# IMPORTANTE: desligar modo estrito antes de entregar o controle ao código
# upstream do CachyOS (util.sh / util-iso.sh / run_build). Esses scripts NÃO
# foram escritos para `set -euo pipefail` — usam retornos não-zero benignos,
# variáveis possivelmente não setadas e pipes que falham por design. Com o
# modo estrito ativo, qualquer um desses aborta o build inteiro (ex: morria
# em "Deleting the build folder"). A nossa parte (setup/otimizações acima) já
# rodou com modo estrito; daqui pra frente é tudo upstream.
# ---------------------------------------------------------------------------
set +e +u +o pipefail

# ---------------------------------------------------------------------------
# Carregar utilitários do repositório
# ---------------------------------------------------------------------------
_log_step "Carregando utilitários..."
src_dir="${REPO_DIR}"
cd "${src_dir}" || _log_fail "Não foi possível acessar '${src_dir}'."

if [[ -r "${src_dir}/util-msg.sh" ]]; then
    source "${src_dir}/util-msg.sh"
    _log_ok "util-msg.sh carregado."
else
    _log_warn "util-msg.sh não encontrado."
fi

[[ -r "${src_dir}/util.sh" ]] || _log_fail "util.sh não encontrado."
source "${src_dir}/util.sh" || _log_fail "Falha ao carregar util.sh"
_log_ok "util.sh carregado."

# ---------------------------------------------------------------------------
# Diretórios
# ---------------------------------------------------------------------------
work_dir="${src_dir}/build"
outFolder="${src_dir}/out"

_log_step "Diretórios:"
echo "    Repositório : ${src_dir}"
echo "    Build       : ${work_dir}"
echo "    ISO saída   : ${outFolder}"

# ---------------------------------------------------------------------------
# Build em RAM — monta tmpfs real (não depende de /tmp ser tmpfs)
# ---------------------------------------------------------------------------
_log_step "Modo de build..."
if [[ "$build_in_ram" == "true" ]]; then
    local_ram_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
    if [[ $local_ram_gb -gt 23 ]]; then
        work_dir="/tmp/cachyos-iso-build-$$"
        mkdir -p "${work_dir}"
        mount -t tmpfs -o "size=$((local_ram_gb - 8))G" tmpfs "${work_dir}" \
            || _log_fail "Falha ao montar tmpfs em ${work_dir}"
        _TMPFS_MOUNTED="${work_dir}"
        _log_ok "Build em RAM (${local_ram_gb}GB, tmpfs montado): ${work_dir}"
    else
        _log_warn "RAM insuficiente (${local_ram_gb}GB). Usando disco."
    fi
else
    _log_ok "Build em disco: ${work_dir}"
    _log_warn "Dica: use -r para build em RAM (64GB disponíveis)."
fi

# ---------------------------------------------------------------------------
# Limpar diretório de trabalho (se -c NÃO foi passado)
# ---------------------------------------------------------------------------
if [[ "$clean_first" == "true" ]]; then
    _log_step "Limpando diretório de trabalho anterior..."
    if [[ -d "${work_dir}" ]]; then
        rm -rf "${work_dir:?}"/*
        _log_ok "Diretório limpo."
    else
        _log_ok "Nada para limpar."
    fi
else
    _log_ok "Limpeza de diretório pulada (-c)."
fi

# ---------------------------------------------------------------------------
# Preparar diretório de trabalho
# ---------------------------------------------------------------------------
_log_step "Preparando diretório de trabalho..."
prepare_dir "${work_dir}" || _log_fail "Falha ao preparar '${work_dir}'."
_log_ok "Pronto: ${work_dir}"

# ---------------------------------------------------------------------------
# Carregar utilitários ISO
# ---------------------------------------------------------------------------
_log_step "Carregando utilitários ISO..."
[[ -r "${src_dir}/util-iso.sh" ]] || _log_fail "util-iso.sh não encontrado."
import "${src_dir}/util-iso.sh" || _log_fail "Falha ao carregar util-iso.sh"
_log_ok "util-iso.sh carregado."

[[ -r "${src_dir}/util-iso-mount.sh" ]] || _log_fail "util-iso-mount.sh não encontrado."
import "${src_dir}/util-iso-mount.sh" || _log_fail "Falha ao carregar util-iso-mount.sh"
_log_ok "util-iso-mount.sh carregado."

# ---------------------------------------------------------------------------
# Verificar requisitos
# ---------------------------------------------------------------------------
_log_step "Verificando requisitos do sistema..."
check_requirements || _log_fail "Requisitos não atendidos."
_log_ok "Requisitos OK."

# ---------------------------------------------------------------------------
# Traps (expansão corrigida — cada sinal recebe seu próprio valor)
# ---------------------------------------------------------------------------
_setup_trap() {
    local sig="$1"
    trap "trap_exit ${sig} \"$(gettext '%s signal caught. Exiting...')\" \"${sig}\"" "${sig}"
}
for sig in TERM HUP QUIT; do _setup_trap "$sig"; done
trap 'trap_exit INT "$(gettext "Aborted by user! Exiting...")"' INT
trap 'trap_exit USR1 "$(gettext "An unknown error has occurred. Exiting...")"' ERR

# ---------------------------------------------------------------------------
# Build!
# ---------------------------------------------------------------------------
_log_step "Iniciando build do perfil '${build_list_iso}'..."
echo ""
echo "    ================================================"
echo "    ISO         : ${ISO_NAME_RAW}"
echo "    Arquivo     : ${ISO_NAME_SAFE}-$(date +%Y.%m.%d)-x86_64.iso"
echo "    Hardware    : Xeon E5-2680v4 + RX 560 + r8169"
echo "    Performance : irqbalance, zram 1GB, ccache, thermald"
echo "    Limpeza     : locales, docs, fontes CJK, ícones, cache"
echo "    Otimizações : sysctl/BBR, ananicy-cpp, earlyoom,"
echo "                  I/O scheduler, RADV/VA-API, CPU gov,"
echo "                  makepkg native, DNS-over-TLS, /tmp RAM,"
echo "                  IRQ affinity, coredump off, psd, modprobe"
echo "    Gaming apps : instalar pós-setup"
echo "    ================================================"
echo ""

timer_start=$(get_timer)
run_build "${build_list_iso}"





