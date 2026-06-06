#!/bin/bash
# =============================================================================
# Covenant CachyOS — build-iso.sh
# Gera a ISO customizada baseada no CachyOS Live ISO
# Uso: sudo bash build-iso.sh [-c] [-r] [-w] [-v]
# =============================================================================

# ---------------------------------------------------------------------------
# Funções de log
# ---------------------------------------------------------------------------
_log_step() { echo ""; echo "===> [PASSO] $*"; }
_log_ok()   { echo "    [OK] $*"; }
_log_warn() { echo "    [AVISO] $*" >&2; }
_log_fail() { echo ""; echo "    [ERRO] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/cachyos-live-iso"
REPO_URL="https://github.com/CachyOS/CachyOS-Live-ISO.git"

ISO_NAME_RAW="Covenant-CachyOS"
ISO_NAME_SAFE="covenant-cachyos"

build_list_iso="desktop"
clean_first=true
verbose=false
build_in_ram=false
remove_build_dir=false

REQUIRED_PKGS=(archiso mkinitcpio-archiso git squashfs-tools grub)

HW_REMOVE_PKGS=(
    amd-ucode
    linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open
    linux-cachyos-zfs linux-cachyos-lts linux-cachyos-lts-zfs
    nvidia-utils lib32-nvidia-utils
    b43-fwcutter iw iwd wpa_supplicant wireless_tools wireless-regdb
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

PERFORMANCE_PKGS=(
    vulkan-radeon vulkan-icd-loader gamemode
    power-profiles-daemon irqbalance
    zram-generator f2fs-tools
    ananicy-cpp earlyoom
)

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
usage() {
    echo ""
    echo "Uso: ${0##*/} [opções]"
    echo "    -c    Não limpar diretório de trabalho"
    echo "    -r    Build em RAM (recomendado com 64GB)"
    echo "    -w    Remover diretório de build após gerar a ISO"
    echo "    -v    Verbose"
    echo "    -h    Ajuda"
    echo ""
    exit "$1"
}

while getopts "cvrwh" arg; do
    case "${arg}" in
        c) clean_first=false ;;
        v) verbose=true ;;
        r) build_in_ram=true ;;
        w) remove_build_dir=true ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || _log_fail "Execute com: sudo bash ${0##*/}"

# ---------------------------------------------------------------------------
# Sanitização do ambiente pacman
# ---------------------------------------------------------------------------
_log_step "Sanitizando ambiente pacman..."

# Remove pacotes corrompidos do cache
_log_ok "Verificando cache..."
find /var/cache/pacman/pkg -name "*.part" -delete 2>/dev/null || true
find /var/cache/pacman/pkg -name "*.pkg.tar.*" -size 0 -delete 2>/dev/null || true
CORRUPT=0
while IFS= read -r pkg; do
    if ! bsdtar -tqf "${pkg}" &>/dev/null 2>&1; then
        rm -f "${pkg}" "${pkg}.sig" 2>/dev/null
        (( CORRUPT++ )) || true
    fi
done < <(find /var/cache/pacman/pkg -name "*.pkg.tar.zst" 2>/dev/null)
[[ ${CORRUPT} -gt 0 ]] && _log_ok "${CORRUPT} pacote(s) corrompido(s) removido(s)." || _log_ok "Cache limpo."

# Atualiza mirrors
_log_ok "Atualizando mirrors..."
if command -v cachyos-rate-mirrors &>/dev/null; then
    cachyos-rate-mirrors 2>/dev/null && _log_ok "Mirrors atualizados (cachyos-rate-mirrors)." || _log_warn "cachyos-rate-mirrors falhou."
elif command -v reflector &>/dev/null; then
    reflector --country "Brazil,United States,Germany" --age 6 --protocol https \
        --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null \
        && _log_ok "Mirrors atualizados (reflector)." || _log_warn "reflector falhou."
else
    _log_warn "Nenhum utilitário de mirror disponível — usando mirrors atuais."
fi

# Atualiza keyrings
_log_ok "Atualizando keyrings..."
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
pacman -Sy --noconfirm cachyos-keyring   2>/dev/null || true
pacman-key --populate archlinux cachyos  2>/dev/null || true
pacman -Syy --noconfirm || _log_fail "Falha ao sincronizar pacman."
_log_ok "Pacman sanitizado."

# ---------------------------------------------------------------------------
# Dependências do host
# ---------------------------------------------------------------------------
_log_step "Verificando dependências..."
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    pacman -Qi "${pkg}" &>/dev/null || MISSING+=("${pkg}")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    _log_ok "Instalando: ${MISSING[*]}"
    pacman -S --noconfirm "${MISSING[@]}" || _log_fail "Falha ao instalar dependências."
fi
_log_ok "Dependências OK."

# ---------------------------------------------------------------------------
# Repositório CachyOS Live ISO
# ---------------------------------------------------------------------------
_log_step "Verificando repositório CachyOS-Live-ISO..."
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    git clone --depth=1 "${REPO_URL}" "${REPO_DIR}" \
        || _log_fail "Falha ao clonar ${REPO_URL}"
    _log_ok "Repositório clonado."
else
    cd "${REPO_DIR}" && git pull --ff-only 2>/dev/null \
        && _log_ok "Repositório atualizado." \
        || _log_warn "git pull falhou — usando versão atual."
fi
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Variáveis de path
# ---------------------------------------------------------------------------
ARCHISO="${REPO_DIR}/archiso"
PACMAN_CONF="${ARCHISO}/pacman.conf"
UTIL_ISO="${REPO_DIR}/util-iso.sh"

# ---------------------------------------------------------------------------
# Fix pacman.conf da ISO — SigLevel=Never resolve 404 nos .db.sig
# ---------------------------------------------------------------------------
_log_step "Configurando pacman.conf da ISO..."
if [[ -f "${PACMAN_CONF}" ]]; then
    sed -i 's/^SigLevel\s*=.*/SigLevel = Never/'                 "${PACMAN_CONF}"
    sed -i 's/^LocalFileSigLevel\s*=.*/LocalFileSigLevel = Never/' "${PACMAN_CONF}"
    grep -q '^LocalFileSigLevel' "${PACMAN_CONF}" \
        || echo 'LocalFileSigLevel = Never' >> "${PACMAN_CONF}"
    sed -i 's/^#\?ParallelDownloads\s*=.*/ParallelDownloads = 10/' "${PACMAN_CONF}"
    _log_ok "SigLevel=Never + ParallelDownloads=10 configurados."
else
    _log_warn "pacman.conf não encontrado em ${PACMAN_CONF}"
fi

# Copia mirrorlists do host para a ISO
mkdir -p "${ARCHISO}/airootfs/etc/pacman.d"
[[ -f /etc/pacman.d/mirrorlist ]]         && cp /etc/pacman.d/mirrorlist         "${ARCHISO}/airootfs/etc/pacman.d/mirrorlist"         && _log_ok "mirrorlist copiado."
[[ -f /etc/pacman.d/cachyos-mirrorlist ]] && cp /etc/pacman.d/cachyos-mirrorlist "${ARCHISO}/airootfs/etc/pacman.d/cachyos-mirrorlist" && _log_ok "cachyos-mirrorlist copiado."

# ---------------------------------------------------------------------------
# Patch util-iso.sh
# ---------------------------------------------------------------------------
_log_step "Patchando util-iso.sh..."
[[ -f "${UTIL_ISO}" ]] || _log_fail "util-iso.sh não encontrado."

# Patch A: fetch_cachyos_mirrorlist — usa mirrorlist local em vez de baixar
python3 - "${UTIL_ISO}" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

old = re.search(r'fetch_cachyos_mirrorlist\(\)\s*\{.*?\n\}', content, re.DOTALL)
if old:
    new = '''fetch_cachyos_mirrorlist() {
    # Covenant: usa mirrorlist local do host
    mkdir -p "${src_dir}/archiso/airootfs/etc/pacman.d"
    [[ -f /etc/pacman.d/cachyos-mirrorlist ]] && \
        cp /etc/pacman.d/cachyos-mirrorlist \
           "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist"
    [[ -f /etc/pacman.d/mirrorlist ]] && \
        cp /etc/pacman.d/mirrorlist \
           "${src_dir}/archiso/airootfs/etc/pacman.d/mirrorlist"
    echo "==> [Covenant] mirrorlist local aplicado."
}'''
    content = content[:old.start()] + new + content[old.end():]
    open(path, 'w').write(content)
    print("OK: fetch_cachyos_mirrorlist substituído.")
else:
    print("WARN: fetch_cachyos_mirrorlist não encontrada.")
PYEOF

# Patch B: SigLevel=Never no work_dir após cp -r archiso
python3 - "${UTIL_ISO}" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
marker = '    cp -r archiso ${work_dir}/archiso'
inject = '''
    # Covenant: SigLevel=Never no work_dir — resolve 404 nos .db.sig
    _wpc="${work_dir}/archiso/pacman.conf"
    if [[ -f "${_wpc}" ]]; then
        sed -i 's/^SigLevel\\s*=.*/SigLevel = Never/' "${_wpc}"
        grep -q '^LocalFileSigLevel' "${_wpc}" || echo 'LocalFileSigLevel = Never' >> "${_wpc}"
        echo "==> [Covenant] SigLevel=Never em ${_wpc}"
    fi'''
if marker in content and 'Covenant: SigLevel' not in content:
    content = content.replace(marker, marker + inject)
    open(path, 'w').write(content)
    print("OK: SigLevel patch injetado após cp -r.")
elif 'Covenant: SigLevel' in content:
    print("OK: SigLevel patch já presente.")
else:
    print("WARN: marcador 'cp -r archiso' não encontrado.")
PYEOF

# Patch C: corrige nome da ISO (cachyos- → covenant-cachyos-)
if grep -q '"cachyos-' "${UTIL_ISO}"; then
    sed -i "s|\"cachyos-\$(date|\"${ISO_NAME_SAFE}-\$(date|g" "${UTIL_ISO}"
    _log_ok "Nome da ISO corrigido para '${ISO_NAME_SAFE}-'."
fi

# Patch D: passa --noconfirm para todas as chamadas de pacman dentro do util-iso.sh
# Resolve prompts interativos de providers (iptables, qt6-multimedia, etc.)
python3 - "${UTIL_ISO}" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

# Adiciona --noconfirm em chamadas pacman -S que não tenham ainda
# Evita duplicar se já presente
new_content = re.sub(
    r'(pacman\s+-S(?!.*--noconfirm)(?:\s+--needed)?)\b',
    r'\1 --noconfirm',
    content
)
if new_content != content:
    open(path, 'w').write(new_content)
    print("OK: --noconfirm adicionado nas chamadas pacman -S.")
else:
    print("OK: --noconfirm já presente ou sem chamadas pacman -S para patchar.")
PYEOF

# Patch E: garante GPL-2.0-only.txt no work_dir antes do syslinux rodar
# O mkarchiso faz 'install GPL-2.0-only.txt' de dentro do airootfs.
# Injetamos um bloco que cria o arquivo se não existir, logo antes do
# setup do syslinux.
python3 - "${UTIL_ISO}" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

# Procura a função que faz setup do syslinux
# Injeta garantia do arquivo GPL antes do install
marker = 'make_syslinux'
inject = '''
    # Covenant: garante GPL-2.0-only.txt para o syslinux
    _gpl_dir="${work_dir}/x86_64/airootfs/usr/share/licenses/spdx"
    _gpl_file="${_gpl_dir}/GPL-2.0-only.txt"
    if [[ ! -f "${_gpl_file}" ]]; then
        mkdir -p "${_gpl_dir}"
        _src=$(find "${work_dir}/x86_64/airootfs/usr/share/licenses" \\
            -name "GPL*" 2>/dev/null | head -1)
        if [[ -n "${_src}" ]]; then
            cp "${_src}" "${_gpl_file}"
        else
            printf 'GNU GENERAL PUBLIC LICENSE\\nVersion 2, June 1991\\n' > "${_gpl_file}"
        fi
        echo "==> [Covenant] GPL-2.0-only.txt criado para syslinux"
    fi'''

if marker in content and 'Covenant: garante GPL' not in content:
    # Injeta antes da primeira chamada de make_syslinux
    content = content.replace(marker, inject.lstrip() + '\n' + marker, 1)
    open(path, 'w').write(content)
    print("OK: Patch E (GPL syslinux) aplicado.")
elif 'Covenant: garante GPL' in content:
    print("OK: Patch E já presente.")
else:
    print("WARN: make_syslinux não encontrado — patch E não aplicado.")
PYEOF

_log_ok "util-iso.sh patchado."

# ---------------------------------------------------------------------------
# Profiledef — nome da ISO
# ---------------------------------------------------------------------------
_log_step "Configurando profiledef.sh..."
PROFILEDEF="${ARCHISO}/profiledef.sh"
if [[ -f "${PROFILEDEF}" ]]; then
    sed -i "s/^iso_name=.*/iso_name=\"${ISO_NAME_RAW}\"/"     "${PROFILEDEF}" 2>/dev/null || true
    sed -i "s/^iso_label=.*/iso_label=\"${ISO_NAME_SAFE^^}\"/" "${PROFILEDEF}" 2>/dev/null || true
    ISO_NAME_SAFE_R=$(grep '^iso_name=' "${PROFILEDEF}" | cut -d'"' -f2 \
        | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
    [[ -n "${ISO_NAME_SAFE_R}" ]] && ISO_NAME_SAFE="${ISO_NAME_SAFE_R}"
    _log_ok "ISO: '${ISO_NAME_RAW}' → arquivo: ${ISO_NAME_SAFE}-DATE-x86_64.iso"
fi

# ---------------------------------------------------------------------------
# packages.x86_64 e packages_desktop.x86_64 customizados
# ---------------------------------------------------------------------------
_log_step "Aplicando packages customizados..."

PACKAGES="${ARCHISO}/packages.x86_64"
PACKAGES_DESKTOP="${ARCHISO}/packages_desktop.x86_64"

# Sobrescreve packages.x86_64 se tiver versão customizada
if [[ -f "${SCRIPT_DIR}/packages.x86_64" ]]; then
    cp "${SCRIPT_DIR}/packages.x86_64" "${PACKAGES}"
    _log_ok "packages.x86_64 aplicado ($(wc -l < "${PACKAGES}") pacotes)."
fi

# Sobrescreve packages_desktop.x86_64 se tiver versão customizada
# Se não tiver, usa o do CachyOS mas limpa os pacotes problemáticos
if [[ -f "${SCRIPT_DIR}/packages_desktop.x86_64" ]]; then
    cp "${SCRIPT_DIR}/packages_desktop.x86_64" "${PACKAGES_DESKTOP}"
    _log_ok "packages_desktop.x86_64 aplicado ($(wc -l < "${PACKAGES_DESKTOP}") pacotes)."
fi

# O build desktop usa packages_desktop.x86_64 — garante remoção dos problemáticos
TARGET_FILES=("${PACKAGES}" "${PACKAGES_DESKTOP}")

_log_step "Removendo pacotes incompatíveis de TODOS os arquivos de packages..."
for pkg in "${HW_REMOVE_PKGS[@]}"; do
    for f in "${TARGET_FILES[@]}"; do
        [[ -f "${f}" ]] || continue
        if grep -q "^${pkg}$" "${f}" 2>/dev/null; then
            sed -i "/^${pkg}$/d" "${f}"
            _log_ok "Removido de $(basename "${f}"): ${pkg}"
        fi
    done
done

# Resolve prompts interativos nos dois arquivos
for f in "${TARGET_FILES[@]}"; do
    [[ -f "${f}" ]] || continue

    # iptables → iptables-nft
    if grep -q '^iptables$' "${f}" 2>/dev/null; then
        sed -i 's/^iptables$/iptables-nft/' "${f}"
        _log_ok "$(basename "${f}"): iptables → iptables-nft"
    fi
    sed -i '/^iptables-legacy$/d' "${f}" 2>/dev/null || true

    # qt6-multimedia → qt6-multimedia-ffmpeg
    if grep -q '^qt6-multimedia$' "${f}" 2>/dev/null; then
        sed -i 's/^qt6-multimedia$/qt6-multimedia-ffmpeg/' "${f}"
        _log_ok "$(basename "${f}"): qt6-multimedia → qt6-multimedia-ffmpeg"
    fi
done

# Garante pacotes obrigatórios do mkarchiso nos dois arquivos
REQUIRED_ISO_PKGS=(syslinux memtest86+ memtest86+-efi edk2-shell licenses)
for pkg in "${REQUIRED_ISO_PKGS[@]}"; do
    for f in "${TARGET_FILES[@]}"; do
        [[ -f "${f}" ]] || continue
        grep -q "^${pkg}$" "${f}" 2>/dev/null || echo "${pkg}" >> "${f}"
    done
done
_log_ok "Pacotes obrigatórios do mkarchiso garantidos (syslinux, memtest, edk2-shell)."

# Garante kernel linux-cachyos no packages_desktop.x86_64
# O mkarchiso PRECISA do vmlinuz-linux-cachyos para gerar a ISO.
# O linux-covenant é instalado apenas no sistema final (1º boot).
for f in "${TARGET_FILES[@]}"; do
    [[ -f "${f}" ]] || continue
    grep -q "^linux-cachyos$" "${f}" 2>/dev/null \
        || echo "linux-cachyos" >> "${f}"
    grep -q "^linux-cachyos-headers$" "${f}" 2>/dev/null \
        || echo "linux-cachyos-headers" >> "${f}"
done
_log_ok "linux-cachyos garantido em todos os arquivos de packages (kernel da live ISO)."

# Garante pacotes de performance no packages.x86_64
for pkg in "${PERFORMANCE_PKGS[@]}"; do
    grep -q "^${pkg}$" "${PACKAGES}" 2>/dev/null || echo "${pkg}" >> "${PACKAGES}"
done

_log_ok "packages.x86_64        : $(wc -l < "${PACKAGES}") pacotes"
[[ -f "${PACKAGES_DESKTOP}" ]] && _log_ok "packages_desktop.x86_64: $(wc -l < "${PACKAGES_DESKTOP}") pacotes"

# ---------------------------------------------------------------------------
# Garante GPL-2.0-only.txt no airootfs — necessário para syslinux BIOS
# O util-iso.sh copia esse arquivo de dentro do airootfs para a ISO.
# O pacote 'licenses' instala em /usr/share/licenses/spdx/ mas às vezes
# não está presente. Criamos preventivamente.
# ---------------------------------------------------------------------------
_log_step "Garantindo licença GPL para syslinux..."
SPDX_DIR="${ARCHISO}/airootfs/usr/share/licenses/spdx"
mkdir -p "${SPDX_DIR}"
if [[ ! -f "${SPDX_DIR}/GPL-2.0-only.txt" ]]; then
    # Tenta copiar do sistema host
    HOST_GPL=$(find /usr/share/licenses /usr/share/common-licenses \
        -name 'GPL-2*' -o -name 'GPL2*' 2>/dev/null | head -1)
    if [[ -n "${HOST_GPL}" ]]; then
        cp "${HOST_GPL}" "${SPDX_DIR}/GPL-2.0-only.txt"
        _log_ok "GPL-2.0-only.txt copiado do host: ${HOST_GPL}"
    else
        # Cria placeholder — o syslinux só precisa que o arquivo exista
        printf 'GNU GENERAL PUBLIC LICENSE\nVersion 2, June 1991\n' \
            > "${SPDX_DIR}/GPL-2.0-only.txt"
        _log_ok "GPL-2.0-only.txt criado (placeholder)."
    fi
else
    _log_ok "GPL-2.0-only.txt já existe no airootfs."
fi


_log_step "Configurando kernel linux-covenant..."
AIROOTFS_PKGS="${ARCHISO}/airootfs/root/covenant-pkgs"
mkdir -p "${AIROOTFS_PKGS}"

KERNEL_PKG=$(ls -1 "${SCRIPT_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v headers | sort -V | tail -1)
KERNEL_HDR=$(ls -1 "${SCRIPT_DIR}"/linux-covenant-headers-[0-9]*.pkg.tar.zst 2>/dev/null | sort -V | tail -1)

if [[ -n "${KERNEL_PKG}" ]]; then
    cp "${KERNEL_PKG}" "${AIROOTFS_PKGS}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${AIROOTFS_PKGS}/"
    _log_ok "Kernel pré-compilado copiado: $(basename "${KERNEL_PKG}")"
else
    _log_warn "linux-covenant não encontrado — compilando automaticamente..."

    BUILD_USER="${SUDO_USER:-}"
    if [[ -z "${BUILD_USER}" || "${BUILD_USER}" == "root" ]]; then
        BUILD_USER="covenant-build"
        id "${BUILD_USER}" &>/dev/null || useradd -m -s /bin/bash "${BUILD_USER}"
        echo "${BUILD_USER} ALL=(ALL) NOPASSWD: /usr/bin/pacman" \
            > /etc/sudoers.d/covenant-build-tmp
        CREATED_USER=true
    else
        CREATED_USER=false
    fi

    BUILD_HOME=$(getent passwd "${BUILD_USER}" | cut -d: -f6)
    KERNEL_REPO="https://github.com/araujo791/Covenant-CachyOS.git"
    BUILD_TMP="${BUILD_HOME}/covenant-kernel-build"

    sudo -u "${BUILD_USER}" bash -c "
        set -e
        rm -rf '${BUILD_TMP}'
        git clone --depth=1 '${KERNEL_REPO}' '${BUILD_TMP}'
        cd '${BUILD_TMP}'
        bash covenant-build.sh
    " || _log_fail "Falha na compilação do kernel Covenant."

    BUILD_PKGDIR="${BUILD_HOME}/kernel-build/linux-cachyos/linux-cachyos"
    KERNEL_PKG=$(ls -1 "${BUILD_PKGDIR}"/linux-covenant-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v headers | sort -V | tail -1)
    KERNEL_HDR=$(ls -1 "${BUILD_PKGDIR}"/linux-covenant-headers-[0-9]*.pkg.tar.zst 2>/dev/null | sort -V | tail -1)

    [[ -z "${KERNEL_PKG}" ]] && _log_fail "Pacote não encontrado após compilação."

    cp "${KERNEL_PKG}" "${AIROOTFS_PKGS}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${AIROOTFS_PKGS}/"
    cp "${KERNEL_PKG}" "${SCRIPT_DIR}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${SCRIPT_DIR}/"

    [[ "${CREATED_USER}" == "true" ]] && { userdel -r "${BUILD_USER}" 2>/dev/null || true; rm -f /etc/sudoers.d/covenant-build-tmp; }
    _log_ok "Kernel compilado: $(basename "${KERNEL_PKG}")"
fi

# ---------------------------------------------------------------------------
# Script cleanup-airootfs.sh
# ---------------------------------------------------------------------------
_log_step "Criando cleanup-airootfs.sh..."
CLEANUP_SCRIPT="${ARCHISO}/airootfs/root/cleanup-airootfs.sh"
mkdir -p "${ARCHISO}/airootfs/root"

# Usamos o arquivo separado se existir, senão usa o embutido
if [[ -f "${SCRIPT_DIR}/cleanup-airootfs.sh" ]]; then
    cp "${SCRIPT_DIR}/cleanup-airootfs.sh" "${CLEANUP_SCRIPT}"
    chmod +x "${CLEANUP_SCRIPT}"
    _log_ok "cleanup-airootfs.sh copiado do diretório do projeto."
else
    _log_warn "cleanup-airootfs.sh não encontrado — gere-o com: bash build-kernel.sh --generate-cleanup"
    _log_fail "cleanup-airootfs.sh é obrigatório para o build."
fi

# Registra no customize_airootfs.sh
CUSTOMIZE="${ARCHISO}/airootfs/root/customize_airootfs.sh"
if [[ -f "${CUSTOMIZE}" ]]; then
    grep -q 'cleanup-airootfs.sh' "${CUSTOMIZE}" \
        || echo "bash /root/cleanup-airootfs.sh" >> "${CUSTOMIZE}"
else
    printf '#!/bin/bash\nbash /root/cleanup-airootfs.sh\n' > "${CUSTOMIZE}"
    chmod +x "${CUSTOMIZE}"
fi
_log_ok "customize_airootfs.sh configurado."

# ---------------------------------------------------------------------------
# Carregar utilitários e disparar build
# ---------------------------------------------------------------------------
_log_step "Carregando utilitários do repositório..."
src_dir="${REPO_DIR}"
cd "${src_dir}" || _log_fail "Não foi possível acessar '${src_dir}'."

[[ -r "${src_dir}/util-msg.sh" ]] && source "${src_dir}/util-msg.sh" || true
[[ -r "${src_dir}/util.sh" ]] || _log_fail "util.sh não encontrado."
source "${src_dir}/util.sh" || _log_fail "Falha ao carregar util.sh"
[[ -r "${src_dir}/util-iso.sh" ]] || _log_fail "util-iso.sh não encontrado."
import "${src_dir}/util-iso.sh"
[[ -r "${src_dir}/util-iso-mount.sh" ]] || _log_fail "util-iso-mount.sh não encontrado."
import "${src_dir}/util-iso-mount.sh"

work_dir="${src_dir}/build"
outFolder="${src_dir}/out"

if [[ "${build_in_ram}" == "true" ]]; then
    ram_gb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
    [[ $ram_gb -gt 23 ]] \
        && { work_dir="$(mktemp -d --suffix='-cachyos-iso')"; _log_ok "Build em RAM (${ram_gb}GB): ${work_dir}"; } \
        || _log_warn "RAM insuficiente — usando disco."
fi

prepare_dir "${work_dir}" || _log_fail "Falha ao preparar work_dir."
check_requirements || _log_fail "Requisitos não atendidos."

for sig in TERM HUP QUIT; do
    trap "trap_exit $sig" "$sig"
done
trap 'trap_exit INT' INT
trap 'trap_exit USR1' ERR

_log_step "Iniciando build '${build_list_iso}'..."
echo ""
echo "    ================================================"
echo "    ISO     : ${ISO_NAME_RAW}"
echo "    Arquivo : ${ISO_NAME_SAFE}-$(date +%Y.%m.%d)-x86_64.iso"
echo "    Hardware: Xeon E5-2680v4 + RX 560 + 64GB ECC"
echo "    ================================================"
echo ""

timer_start=$(get_timer)
run_build "${build_list_iso}"

[[ "${remove_build_dir}" == "true" ]] && rm -rf "${work_dir}"
_log_ok "Build concluído em $(elapsed_time "${timer_start}")."
