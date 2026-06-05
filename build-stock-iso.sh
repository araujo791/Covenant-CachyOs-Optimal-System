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
# ---------------------------------------------------------------------------
PERFORMANCE_PKGS=(
    vulkan-radeon
    vulkan-icd-loader
    gamemode
    power-profiles-daemon
    irqbalance           # balanceia interrupções entre os 28 cores
    zram-generator
    f2fs-tools
    ananicy-cpp          # priorização automática de processos
    earlyoom             # mata processos antes de travar o sistema por OOM
    # haveged removido: kernel moderno usa jitterentropy nativo
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
    exit $1
}

orig_argv=("$@")
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
shift $(($OPTIND - 1))

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
_log_step "Verificando privilégios..."
[[ $EUID -eq 0 ]] || _log_fail "Execute com: sudo bash ${0##*/}"
_log_ok "Executando como root."

# ---------------------------------------------------------------------------
# Sanitização do ambiente pacman
# Resolve os problemas mais comuns que quebram o build:
#   1. Pacotes corrompidos no cache
#   2. Mirrors desatualizados / com 404
#   3. Keyring desatualizada (assinaturas inválidas)
#   4. DB desatualizado
# ---------------------------------------------------------------------------
_log_step "Sanitizando ambiente pacman..."

# 1. Remove pacotes corrompidos do cache (parciais, tamanho zero, .part)
_log_ok "Limpando cache corrompido..."
find /var/cache/pacman/pkg -name "*.part" -delete 2>/dev/null || true
find /var/cache/pacman/pkg -name "*.pkg.tar.*" -size 0 -delete 2>/dev/null || true

# Verifica integridade dos pacotes em cache e remove os inválidos
CORRUPT_COUNT=0
while IFS= read -r pkg; do
    if ! bsdtar -tqf "${pkg}" &>/dev/null 2>&1; then
        _log_warn "Cache corrompido removido: $(basename "${pkg}")"
        rm -f "${pkg}" "${pkg}.sig" 2>/dev/null
        (( CORRUPT_COUNT++ )) || true
    fi
done < <(find /var/cache/pacman/pkg -name "*.pkg.tar.zst" 2>/dev/null)
[[ ${CORRUPT_COUNT} -gt 0 ]] \
    && _log_ok "${CORRUPT_COUNT} pacote(s) corrompido(s) removido(s) do cache." \
    || _log_ok "Cache limpo — nenhum arquivo corrompido."

# 2. Atualiza mirrors do CachyOS e Arch
_log_ok "Atualizando mirrors..."
if command -v cachyos-rate-mirrors &>/dev/null; then
    cachyos-rate-mirrors 2>/dev/null \
        && _log_ok "Mirrors CachyOS atualizados via cachyos-rate-mirrors." \
        || _log_warn "cachyos-rate-mirrors falhou — usando mirrors atuais."
elif command -v rate-mirrors &>/dev/null; then
    rate-mirrors --save /etc/pacman.d/mirrorlist arch 2>/dev/null \
        && _log_ok "Mirrors Arch atualizados via rate-mirrors." \
        || _log_warn "rate-mirrors falhou — usando mirrors atuais."
elif command -v reflector &>/dev/null; then
    reflector \
        --country "Brazil,United States,Germany" \
        --age 6 \
        --protocol https \
        --sort rate \
        --save /etc/pacman.d/mirrorlist 2>/dev/null \
        && _log_ok "Mirrors atualizados via reflector." \
        || _log_warn "reflector falhou — usando mirrors atuais."
else
    _log_warn "Nenhum utilitário de mirror encontrado (cachyos-rate-mirrors/reflector)."
    _log_warn "Mirrors não foram atualizados — erros 404 podem ocorrer."
fi

# 3. Atualiza keyring (resolve "invalid or corrupted package (PGP signature)")
_log_ok "Atualizando keyrings..."
pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
pacman -Sy --noconfirm cachyos-keyring   2>/dev/null || true
pacman-key --populate archlinux cachyos  2>/dev/null || true

# 4. Sincroniza DBs forçando refresh de todos os repos
_log_ok "Sincronizando base de dados pacman..."
pacman -Syy --noconfirm \
    || _log_fail "Falha ao sincronizar pacman. Verifique a conexão de rede."

_log_ok "Ambiente pacman sanitizado."

# ---------------------------------------------------------------------------
# Dependências do host
# ---------------------------------------------------------------------------
_log_step "Verificando dependências do host..."
missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    pacman -Qi "$pkg" &>/dev/null \
        && _log_ok "$pkg — OK" \
        || { _log_warn "$pkg — ausente"; missing+=("$pkg"); }
done

if [[ ${#missing[@]} -gt 0 ]]; then
    _log_step "Instalando dependências ausentes: ${missing[*]}"
    pacman -Syy --noconfirm || _log_fail "Falha ao sincronizar pacman."
    pacman -S --needed --noconfirm "${missing[@]}" \
        || _log_fail "Falha ao instalar: ${missing[*]}"
    for pkg in "${missing[@]}"; do
        pacman -Qi "$pkg" &>/dev/null \
            && _log_ok "$pkg — instalado" \
            || _log_fail "Não foi possível instalar: $pkg"
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
GRUB_CFG="${ARCHISO}/grub/grub.cfg"
MKINIT="${ARCHISO}/airootfs/etc/mkinitcpio.conf"
PACMAN_CONF="${ARCHISO}/pacman.conf"
UTIL_ISO="${REPO_DIR}/util-iso.sh"

# ---------------------------------------------------------------------------
# Configura pacman.conf da ISO
# O pacman.conf dentro do archiso controla como os pacotes são instalados
# no squashfs. Ajustes importantes:
#   - Copia o mirrorlist atualizado do host para dentro da ISO
#   - Ajusta SigLevel para TrustAll durante o build (evita falhas de PGP
#     em pacotes recém-assinados que o keyring local ainda não conhece)
#   - Configura CacheDir dedicado para a build (não polui /var/cache/pacman)
# ---------------------------------------------------------------------------
_log_step "Configurando pacman.conf da ISO..."

if [[ -f "${PACMAN_CONF}" ]]; then
    # --- SigLevel ---
    # O mirror do CachyOS frequentemente não serve .db.sig (retorna 404).
    # "TrustAll" faz o pacman ignorar assinaturas completamente.
    # "Never" idem mas mais explícito — ambos resolvem o 404 nos .db.sig.
    # Usamos "TrustAll" para manter verificação de integridade dos pacotes
    # mas não exigir o .sig do banco de dados.
    sed -i 's/^SigLevel\s*=.*/SigLevel = TrustAll/'                 "${PACMAN_CONF}"
    sed -i 's/^LocalFileSigLevel\s*=.*/LocalFileSigLevel = Optional/' "${PACMAN_CONF}"
    # Garante que a linha existe se não estiver presente
    grep -q '^LocalFileSigLevel' "${PACMAN_CONF}" \
        || sed -i '/^SigLevel/a LocalFileSigLevel = Optional' "${PACMAN_CONF}"
    _log_ok "SigLevel = TrustAll, LocalFileSigLevel = Optional."

    # --- Substitui o mirror problemático no pacman.conf da ISO ---
    # O archiso do CachyOS tem Include para cachyos-mirrorlist e mirrorlist.
    # Copiamos os mirrorlists atualizados do host para garantir que o mkarchiso
    # use os mesmos mirrors que acabamos de validar na etapa de sanitização.
    mkdir -p "${ARCHISO}/airootfs/etc/pacman.d"

    if [[ -f /etc/pacman.d/cachyos-mirrorlist ]]; then
        cp /etc/pacman.d/cachyos-mirrorlist "${ARCHISO}/airootfs/etc/pacman.d/cachyos-mirrorlist"
        _log_ok "cachyos-mirrorlist copiado para a ISO."
    fi

    if [[ -f /etc/pacman.d/mirrorlist ]]; then
        cp /etc/pacman.d/mirrorlist "${ARCHISO}/airootfs/etc/pacman.d/mirrorlist"
        _log_ok "mirrorlist copiado para a ISO."
    fi

    # O pacman.conf da ISO usa Include para esses arquivos — mas o mkarchiso
    # também passa -C com o pacman.conf diretamente ao instalar pacotes no
    # chroot. Para garantir que o mirrorlist correto é usado nesse momento,
    # também copiamos para o diretório de trabalho do pacman da archiso:
    ARCHISO_PACMAN_D="${ARCHISO}/pacman.conf"

    # Injeta mirrors diretamente em cada repo que usa archlinux.cachyos.org,
    # caso o Include não funcione durante o build fora do chroot.
    # Verifica se o pacman.conf tem Server hardcoded (sem Include):
    if grep -q 'Server\s*=.*archlinux\.cachyos\.org' "${PACMAN_CONF}"; then
        _log_warn "Encontrado Server hardcoded para archlinux.cachyos.org — substituindo..."
        # Substitui por Include para o mirrorlist do host
        sed -i 's|^Server\s*=.*archlinux\.cachyos\.org.*|Include = /etc/pacman.d/cachyos-mirrorlist|' \
            "${PACMAN_CONF}" 2>/dev/null || true
        _log_ok "Server hardcoded substituído por Include."
    fi

    # ParallelDownloads
    sed -i 's/^#\?ParallelDownloads\s*=.*/ParallelDownloads = 10/' "${PACMAN_CONF}"
    grep -q '^ParallelDownloads' "${PACMAN_CONF}" \
        || echo 'ParallelDownloads = 10' >> "${PACMAN_CONF}"
    _log_ok "ParallelDownloads = 10."
else
    _log_warn "pacman.conf da ISO não encontrado em ${PACMAN_CONF} — pulando."
fi

# CacheDir dedicado para o build (evita misturar com /var/cache/pacman/pkg)
BUILD_CACHE="${SCRIPT_DIR}/build-cache"
mkdir -p "${BUILD_CACHE}"
_log_ok "CacheDir de build: ${BUILD_CACHE}"
# mkarchiso usa essa variável se definida via -C, mas o util-iso.sh do CachyOS
# passa o cachedir internamente. Exportamos para o ambiente do mkarchiso.
export ARCHISO_PACMAN_CACHE="${BUILD_CACHE}"

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
# Aplicar packages customizados
# NOTA: util-iso.sh linha 142 copia packages_desktop → packages antes do
# mkarchiso, por isso copiamos para AMBOS os arquivos.
# ---------------------------------------------------------------------------
_log_step "Aplicando packages.x86_64 customizado..."

if [[ -f "${SCRIPT_DIR}/packages.x86_64" ]]; then
    cp "${SCRIPT_DIR}/packages.x86_64" "${PACKAGES}"
    cp "${SCRIPT_DIR}/packages.x86_64" "${PACKAGES_DESKTOP}"
    total_p=$(grep -v '^#' "${PACKAGES}" | grep -v '^$' | wc -l)
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
[[ ${#removed[@]} -gt 0 ]] \
    && { _log_ok "Removidos:"; for p in "${removed[@]}"; do echo "      - $p"; done; } \
    || _log_ok "Nenhum pacote desnecessário encontrado."

added=()
for pkg in "${PERFORMANCE_PKGS[@]}"; do
    if ! grep -q "^${pkg}$" "${PACKAGES}" 2>/dev/null; then
        echo "${pkg}" >> "${PACKAGES}"
        echo "${pkg}" >> "${PACKAGES_DESKTOP}"
        added+=("$pkg")
    fi
done
[[ ${#added[@]} -gt 0 ]] \
    && { _log_ok "Adicionados (performance):"; for p in "${added[@]}"; do echo "      + $p"; done; } \
    || _log_ok "Pacotes de performance já presentes."

total=$(grep -v '^#' "${PACKAGES}" | grep -v '^$' | wc -l)
_log_ok "Total de pacotes: ${total}"


# ---------------------------------------------------------------------------
# KERNEL COVENANT — inclui os pacotes pré-compilados na ISO
# ---------------------------------------------------------------------------
_log_step "Configurando kernel linux-covenant na ISO..."

KERNEL_PKG_DIR="${SCRIPT_DIR}"
AIROOTFS_PKGS="${ARCHISO}/airootfs/root/covenant-pkgs"
mkdir -p "${AIROOTFS_PKGS}"

# Localiza os .pkg.tar.zst do kernel Covenant na pasta do script
KERNEL_PKG=$(ls -1 "${KERNEL_PKG_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst 2>/dev/null \
    | grep -v headers | sort -V | tail -1)
KERNEL_HDR=$(ls -1 "${KERNEL_PKG_DIR}"/linux-covenant-headers-[0-9]*.pkg.tar.zst 2>/dev/null \
    | sort -V | tail -1)

if [[ -n "${KERNEL_PKG}" ]]; then
    # Usa os pacotes pré-compilados
    cp "${KERNEL_PKG}" "${AIROOTFS_PKGS}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${AIROOTFS_PKGS}/"
    _log_ok "Kernel pré-compilado copiado para a ISO:"
    _log_ok "  kernel : $(basename "${KERNEL_PKG}")"
    [[ -n "${KERNEL_HDR}" ]] && _log_ok "  headers: $(basename "${KERNEL_HDR}")"
else
    # ---------------------------------------------------------------------------
    # Compilação automática do kernel Covenant
    #
    # PROBLEMA: build-stock-iso.sh roda como root, mas makepkg recusa root.
    # SOLUÇÃO:  detecta o usuário real que chamou sudo e compila como ele.
    #           Se não houver usuário real (ex: root puro), cria um usuário
    #           temporário "covenant-build" só para a compilação.
    # ---------------------------------------------------------------------------
    _log_warn "Pacotes linux-covenant não encontrados em ${KERNEL_PKG_DIR}/"
    _log_warn "Compilando kernel do zero (1-3h dependendo da máquina)..."

    # Detecta usuário real por trás do sudo
    BUILD_USER="${SUDO_USER:-}"
    if [[ -z "${BUILD_USER}" || "${BUILD_USER}" == "root" ]]; then
        # Cria usuário temporário para a compilação
        BUILD_USER="covenant-build"
        if ! id "${BUILD_USER}" &>/dev/null; then
            useradd -m -s /bin/bash "${BUILD_USER}" \
                || _log_fail "Não foi possível criar usuário temporário ${BUILD_USER}."
            # Permite ao usuário temporário instalar dependências via pacman sem senha
            echo "${BUILD_USER} ALL=(ALL) NOPASSWD: /usr/bin/pacman" \
                >> /etc/sudoers.d/covenant-build-tmp
        fi
        CREATED_BUILD_USER=true
    else
        CREATED_BUILD_USER=false
    fi

    BUILD_HOME=$(getent passwd "${BUILD_USER}" | cut -d: -f6)
    COVENANT_KERNEL_REPO="https://github.com/araujo791/Covenant-CachyOS.git"
    COVENANT_BUILD_TMP="${BUILD_HOME}/covenant-kernel-build"

    _log_ok "Compilando como usuário: ${BUILD_USER}"

    # Clona o repositório do kernel como o usuário de build
    sudo -u "${BUILD_USER}" bash -c "
        set -e
        [[ -d '${COVENANT_BUILD_TMP}' ]] && rm -rf '${COVENANT_BUILD_TMP}'
        git clone --depth=1 '${COVENANT_KERNEL_REPO}' '${COVENANT_BUILD_TMP}'
    " || _log_fail "Falha ao clonar repositório do kernel Covenant."

    # Roda o covenant-build.sh como usuário normal
    # O script já tem seu próprio tratamento de sudo para pacman -S
    sudo -u "${BUILD_USER}" bash -c "
        set -e
        cd '${COVENANT_BUILD_TMP}'
        bash covenant-build.sh
    " || _log_fail "Falha na compilação do kernel Covenant. Verifique os logs acima."

    # Localiza os pacotes compilados (covenant-build.sh usa $HOME/kernel-build)
    BUILD_PKGDIR="${BUILD_HOME}/kernel-build/linux-cachyos/linux-cachyos"
    KERNEL_PKG=$(ls -1 "${BUILD_PKGDIR}"/linux-covenant-[0-9]*.pkg.tar.zst 2>/dev/null \
        | grep -v headers | sort -V | tail -1)
    KERNEL_HDR=$(ls -1 "${BUILD_PKGDIR}"/linux-covenant-headers-[0-9]*.pkg.tar.zst 2>/dev/null \
        | sort -V | tail -1)

    [[ -z "${KERNEL_PKG}" ]] && _log_fail "Compilação concluída mas pacote não encontrado em ${BUILD_PKGDIR}."

    # Copia para a ISO
    cp "${KERNEL_PKG}" "${AIROOTFS_PKGS}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${AIROOTFS_PKGS}/"

    # Salva cópia na pasta do script para próximas builds (evita recompilar)
    cp "${KERNEL_PKG}" "${KERNEL_PKG_DIR}/"
    [[ -n "${KERNEL_HDR}" ]] && cp "${KERNEL_HDR}" "${KERNEL_PKG_DIR}/"

    # Limpa usuário temporário se foi criado
    if [[ "${CREATED_BUILD_USER}" == "true" ]]; then
        userdel -r "${BUILD_USER}" 2>/dev/null || true
        rm -f /etc/sudoers.d/covenant-build-tmp
        _log_ok "Usuário temporário ${BUILD_USER} removido."
    fi

    cd "${SCRIPT_DIR}"
    _log_ok "Kernel compilado e salvo para próximas builds:"
    _log_ok "  kernel : $(basename "${KERNEL_PKG}")"
    [[ -n "${KERNEL_HDR}" ]] && _log_ok "  headers: $(basename "${KERNEL_HDR}")"
fi


_log_step "Criando script de limpeza do airootfs..."

CLEANUP_SCRIPT="${ARCHISO}/airootfs/root/cleanup-airootfs.sh"
mkdir -p "${ARCHISO}/airootfs/root"

cat > "${CLEANUP_SCRIPT}" << 'CLEANUP'
#!/bin/bash
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

if ! grep -q 'XCURSOR_THEME' /etc/environment 2>/dev/null; then
    echo "XCURSOR_THEME=Adwaita" >> /etc/environment
    echo "XCURSOR_SIZE=24"       >> /etc/environment
fi

echo "     Cursor theme: Adwaita 24px configurado."

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

# --- Rede: BBR + fq (CachyOS não define por padrão) ---
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

# --- VM: apenas o que CachyOS não toca ---
vm.max_map_count = 1048576
kernel.pid_max = 4194304
kernel.numa_balancing = 1
SYSCTL

echo "     sysctl 90-covenant.conf criado (BBR, buffers, VM extra)."

# ---------------------------------------------------------------------------
# 2. BBR — módulo carregado no boot via modules-load.d
# ---------------------------------------------------------------------------
echo "  -> Configurando módulo BBR..."
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
echo "     tcp_bbr adicionado a modules-load.d."

# ---------------------------------------------------------------------------
# 3. zram — otimizado para 64GB RAM
# ---------------------------------------------------------------------------
echo "  -> Configurando zram..."

cat > /etc/systemd/zram-generator.conf << 'ZRAM'
# Covenant CachyOS — zram otimizado para 64GB
[zram0]
zram-size = 8192
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

echo "     zram: 8GB zstd configurado."

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
# scheduler none: NVMe tem sua própria fila interna (HW queue), não precisa de
#   scheduler de software. Qualquer scheduler adiciona latência desnecessária.
# nr_requests 2048: aumenta profundidade de fila para saturar o device
# read_ahead_kb 512: prefetch moderado; NVMe é rápido o suficiente para não
#   precisar de leitura antecipada agressiva
# add_random 0: NVMe não contribui de forma útil para o pool de entropia
# write_cache writethrough: em desktop sem UPS, writeback pode causar corrupção
#   em queda de energia. writethrough é mais seguro sem custo perceptível.
# nomerges 0: permite merging de I/O (padrão, mas explícito para clareza)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nr_requests}="2048"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/read_ahead_kb}="512"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/nomerges}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/wbt_lat_usec}="0"

# --- SSD SATA (rotational=0) ---
# scheduler mq-deadline: melhor latência para SSDs SATA; evita starvation
# nr_requests 256: fila menor que NVMe pois SATA é mais lento
# read_ahead_kb 256: prefetch baixo; SSD responde rápido sem necessidade
# add_random 0: SSD não contribui de forma útil para entropia
# rotational 0: confirma para o kernel que é SSD (às vezes mal detectado)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/wbt_lat_usec}="0"

# --- HDD (rotational=1) ---
# scheduler bfq: Budget Fair Queueing — melhor para HDDs, garante fairness
#   e previne starvation em uso misto (desktop + background I/O)
# nr_requests 128: fila menor para evitar latência excessiva por seek
# read_ahead_kb 2048: prefetch agressivo compensa latência de seek do HDD
# add_random 1: HDD contribui genuinamente para entropia do kernel
# rq_affinity 2: processa completions no core que submeteu o I/O (reduz cache miss)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/nr_requests}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="2048"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/add_random}="1"

# --- Todos os dispositivos de bloco ---
# rq_affinity 1: processa I/O completions no mesmo core que submeteu a req
#   (melhora cache locality em NVMe/SSD; valor 2 em HDD pode ser contraproducente)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]*", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/rq_affinity}="1"
IOSCHEDULER

# --- sysctl: writeback e dirty pages para I/O de desktop ---
# dirty_ratio 10: começa sync quando 10% da RAM estiver suja
#   (com 64GB = 6.4GB de buffer — bom para compilação/escrita intensa)
# dirty_background_ratio 3: começa writeback em background com 3% sujo
# dirty_writeback_centisecs 1500: flush a cada 15s (padrão 5s é excessivo para SSD)
# dirty_expire_centisecs 3000: dados sujos expiram em 30s (padrão 30s, explícito)
# vfs_cache_pressure 50: kernel retém mais inodes/dentries no cache
#   (padrão 100 é muito agressivo no reclaim)
cat >> /etc/sysctl.d/99-covenant.conf << 'SYSCTL_IO'

# I/O writeback — Covenant
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.vfs_cache_pressure = 50
SYSCTL_IO

echo "     I/O: NVMe/SSD/HDD scheduler + queue depth + readahead + writeback configurados."

# ---------------------------------------------------------------------------
# 5. makepkg.conf — -march=native, paralelismo total
# ---------------------------------------------------------------------------
echo "  -> Configurando makepkg.conf..."

MAKEPKG_CONF="/etc/makepkg.conf"
if [[ -f "${MAKEPKG_CONF}" ]]; then
    NPROC=$(nproc 2>/dev/null || echo 4)
    sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i 's/^CXXFLAGS=.*/CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i 's/^RUSTFLAGS=.*/RUSTFLAGS="-C opt-level=3 -C target-cpu=native"/' "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i "s/^MAKEFLAGS=.*/MAKEFLAGS=\"-j${NPROC}\"/" "${MAKEPKG_CONF}" 2>/dev/null || true
    sed -i "s/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/" "${MAKEPKG_CONF}" 2>/dev/null || true
    echo "     makepkg: -march=native -O2 com ${NPROC} threads."
else
    echo "     makepkg.conf não encontrado — pulando."
fi

# ---------------------------------------------------------------------------
# 6. ananicy-cpp — regras de prioridade
# ---------------------------------------------------------------------------
echo "  -> Configurando ananicy-cpp..."

systemctl enable ananicy-cpp.service 2>/dev/null \
    || systemctl enable ananicy.service 2>/dev/null \
    || echo "     ananicy: será habilitado no primeiro boot."

mkdir -p /etc/ananicy.d
cat > /etc/ananicy.d/covenant-custom.rules << 'ANANICY'
{ "name": "make",         "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1",          "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "cc1plus",      "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "ld",           "type": "BG_CPUIO", "nice": 10, "ioclass": "idle" }
{ "name": "kwin_wayland", "type": "WM",       "nice": -5  }
{ "name": "kwin_x11",     "type": "WM",       "nice": -5  }
{ "name": "plasmashell",  "type": "LightWM",  "nice": -3  }
{ "name": "pipewire",     "type": "Audio",    "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "pipewire-pulse","type": "Audio",   "nice": -11, "sched": "RR", "rtprio": 90 }
{ "name": "wireplumber",  "type": "Audio",    "nice": -11 }
ANANICY

echo "     ananicy-cpp: regras criadas."

# ---------------------------------------------------------------------------
# 7. earlyoom
# ---------------------------------------------------------------------------
echo "  -> Configurando earlyoom..."

mkdir -p /etc/default
cat > /etc/default/earlyoom << 'EARLYOOM'
EARLYOOM_ARGS="-m 5 -M 3 -s 5 -S 3 --avoid '(sshd|systemd|init)' --prefer '(chrome|firefox|electron)'"
EARLYOOM

systemctl enable earlyoom.service 2>/dev/null \
    && echo "     earlyoom habilitado." \
    || echo "     earlyoom: será habilitado no primeiro boot."

# ---------------------------------------------------------------------------
# 8. Variáveis de ambiente — AMD/Vulkan/Mesa/Qt
# ---------------------------------------------------------------------------
echo "  -> Configurando variáveis de ambiente..."

cat >> /etc/environment << 'ENVVARS'

# === Covenant CachyOS — Performance Environment ===
AMD_VULKAN_ICD=RADV
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
MESA_NO_ERROR=1
RADV_PERFTEST=aco
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
_JAVA_AWT_WM_NONREPARENTING=1
ENVVARS

echo "     Variáveis de ambiente configuradas."

# ---------------------------------------------------------------------------
# 9. Serviços systemd
# ---------------------------------------------------------------------------
echo "  -> Configurando serviços systemd..."

ENABLE_SERVICES=(
    irqbalance.service
    power-profiles-daemon.service
    fstrim.timer
    earlyoom.service
)

for svc in "${ENABLE_SERVICES[@]}"; do
    systemctl enable "${svc}" 2>/dev/null \
        && echo "     [+] ${svc}" \
        || echo "     [!] ${svc} — não encontrado (ok)"
done

# fstrim: muda cadência de semanal para diária e adiciona log
# O padrão (semanal) é conservador. Para desktop com compilação/Docker,
# diário garante que o controller NVMe/SSD tem blocos livres anotados
# com mais frequência, mantendo performance de escrita consistente.
# OnCalendar=daily roda uma vez por dia no horário que o sistema estiver ligado.
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/covenant-daily.conf << 'FSTRIMOVERRIDE'
[Timer]
# Sobrescreve a cadência padrão (semanal) para diária
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=1800
FSTRIMOVERRIDE

echo "     fstrim.timer: cadência alterada para diária (override em fstrim.timer.d/)."

DISABLE_SERVICES=(
    ModemManager.service
    bluetooth.service
)

# NOTA: cups.service e avahi-daemon NÃO são desabilitados aqui.
# - cups é instalado e deve estar disponível para o instalador (Calamares) configurar.
# - avahi é necessário para o nss-mdns (resolução .local) funcionar corretamente.

for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable "${svc}" 2>/dev/null \
        && echo "     [-] ${svc}" \
        || true
done

# ---------------------------------------------------------------------------
# 10. journald
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
# 11. DNS com cache local
# ---------------------------------------------------------------------------
echo "  -> Configurando DNS..."
mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/covenant.conf << 'RESOLVED'
[Resolve]
DNS=1.1.1.1 9.9.9.9 8.8.8.8
FallbackDNS=1.0.0.1 149.112.112.112
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=yes
RESOLVED

systemctl enable systemd-resolved.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 12. CPU governor — performance via serviço de primeiro boot
#
#     NÃO usamos tmpfiles.d gerado aqui porque nproc retornaria os cores da
#     máquina de BUILD, não do sistema instalado.
#
#     Solução: serviço one-shot que roda na primeira inicialização do sistema
#     instalado, detecta os CPUs reais e grava o tmpfiles.d correto.
#     O serviço se auto-desabilita após execução (ConditionPathExists).
# ---------------------------------------------------------------------------
echo "  -> Configurando CPU governor (serviço de primeiro boot)..."

mkdir -p /etc/systemd/system /usr/local/bin /etc/udev/rules.d

# Script executado no primeiro boot do sistema instalado
cat > /usr/local/bin/covenant-cpu-governor-setup.sh << 'CPUSCRIPT'
#!/bin/bash
# Covenant CachyOS — CPU governor setup (primeiro boot)
CPU_COUNT=$(nproc 2>/dev/null \
    || ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l \
    || echo 4)

mkdir -p /etc/tmpfiles.d
{
    echo "# Covenant — cpu governor: performance"
    echo "# Gerado no primeiro boot para ${CPU_COUNT} cores"
    for i in $(seq 0 $(( CPU_COUNT - 1 ))); do
        printf 'w! /sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor - - - - performance\n' "$i"
    done
} > /etc/tmpfiles.d/cpu-governor.conf

# Aplica imediatamente sem precisar reiniciar
systemd-tmpfiles --create /etc/tmpfiles.d/cpu-governor.conf 2>/dev/null || true

CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
echo "covenant-cpu-governor: ${CPU_COUNT} cores configurados — governor atual: ${CURRENT}"

systemctl disable covenant-cpu-governor-setup.service 2>/dev/null || true
CPUSCRIPT

chmod +x /usr/local/bin/covenant-cpu-governor-setup.sh

# Serviço one-shot: roda uma vez no primeiro boot, depois se desabilita
cat > /etc/systemd/system/covenant-cpu-governor-setup.service << 'CPUSVC'
[Unit]
Description=Covenant CachyOS - CPU Governor Setup (primeiro boot)
After=systemd-tmpfiles-setup.service
Before=display-manager.service
ConditionPathExists=!/etc/tmpfiles.d/cpu-governor.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/covenant-cpu-governor-setup.sh
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
CPUSVC

systemctl enable covenant-cpu-governor-setup.service 2>/dev/null \
    && echo "     covenant-cpu-governor-setup.service habilitado (roda no primeiro boot)." \
    || echo "     [!] será habilitado no primeiro boot."

# udev como camada extra: garante hotplug de CPUs
cat > /etc/udev/rules.d/50-cpu-governor.rules << 'CPUUDEV'
# Covenant — performance governor (udev fallback)
SUBSYSTEM=="cpu", ACTION=="add", ATTR{cpufreq/scaling_governor}="performance"
CPUUDEV

echo "     CPU governor: serviço de primeiro boot + udev fallback configurados."

# ---------------------------------------------------------------------------
# 13. Limites de sistema
# ---------------------------------------------------------------------------
echo "  -> Configurando limites de sistema..."

cat > /etc/security/limits.d/covenant.conf << 'LIMITS'
*      soft  nofile   524288
*      hard  nofile   1048576
*      soft  nproc    65536
*      hard  nproc    131072
@audio soft  memlock  unlimited
@audio hard  memlock  unlimited
LIMITS

# ---------------------------------------------------------------------------
# 14. /tmp em RAM
# ---------------------------------------------------------------------------
echo "  -> Configurando /tmp em tmpfs..."

if ! grep -q 'tmpfs.*/tmp' /etc/fstab 2>/dev/null; then
    printf '\n# Covenant — /tmp em RAM\ntmpfs\t/tmp\ttmpfs\trw,nosuid,nodev,noatime,size=8G,mode=1777\t0 0\n' >> /etc/fstab
    echo "     /tmp: tmpfs 8GB adicionado ao fstab."
else
    echo "     /tmp tmpfs já configurado."
fi

# ---------------------------------------------------------------------------
# 15. pacman.conf — sistema instalado
# ---------------------------------------------------------------------------
echo "  -> Otimizando pacman..."

PACMAN_CONF_FILE="/etc/pacman.conf"
if [[ -f "${PACMAN_CONF_FILE}" ]]; then
    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 5/'   "${PACMAN_CONF_FILE}" 2>/dev/null || true
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/'  "${PACMAN_CONF_FILE}" 2>/dev/null || true
    sed -i 's/^#Color$/Color/'                               "${PACMAN_CONF_FILE}" 2>/dev/null || true
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'            "${PACMAN_CONF_FILE}" 2>/dev/null || true

    # Restaura SigLevel correto (o build usa TrustAll, o sistema instalado
    # deve usar o padrão seguro: Required DatabaseOptional)
    sed -i 's/^SigLevel\s*=.*/SigLevel = Required DatabaseOptional/' \
        "${PACMAN_CONF_FILE}" 2>/dev/null || true

    # ILoveCandy :)
    grep -q 'ILoveCandy' "${PACMAN_CONF_FILE}" \
        || sed -i '/^Color/a ILoveCandy' "${PACMAN_CONF_FILE}" 2>/dev/null || true

    echo "     pacman: downloads paralelos=5, Color, VerbosePkgLists, SigLevel restaurado."
fi

# ---------------------------------------------------------------------------
# 16. Kernel cmdline — parâmetros de performance para o sistema instalado
#
#     Abordagem dupla:
#       a) /etc/default/grub.d/covenant-cmdline.cfg  → GRUB (grub-mkconfig)
#       b) /etc/kernel/cmdline.d/covenant.conf        → systemd-boot / mkinitcpio-uki
#          + hook pacman para auto-aplicar após atualizações de kernel
#
#     Parâmetros escolhidos para Xeon E5-2680v4 + AMD RX 560 + 64GB ECC:
#
#       intel_pstate=disable
#           → Desativa o driver intel_pstate e usa intel_cpufreq no lugar.
#             OBRIGATÓRIO para o governor "performance" funcionar.
#             Com intel_pstate ativo, o governor é ignorado em boa parte dos
#             kernels CachyOS porque ele usa seu próprio P-state management.
#
#       cpufreq.default_governor=performance
#           → Define o governor ANTES do systemd subir, eliminando a janela
#             em que o sistema usa "schedutil" durante o boot.
#
#       nvme_core.default_ps_state=0
#           → Desativa o power saving do NVMe (APST — Autonomous Power State
#             Transition). Com APST ativo, o NVMe entra em estado de baixo
#             consumo após inatividade e acorda com latência de 3-10ms.
#             Em desktop isso causa micro-stutters perceptíveis.
#
#       nvme_core.io_timeout=4294967295
#           → Timeout máximo para I/O NVMe (evita reset prematuro em cargas pesadas)
#
#       mitigations=off
#           → Desabilita Spectre/Meltdown/MDS mitigations.
#             Ganho de ~10-20% em workloads de I/O e syscall-heavy (compilação,
#             containers). Xeon E5-2680v4 é afetado por várias mitigations.
#             Aceitável em máquina desktop sem acesso público.
#
#       nowatchdog + nmi_watchdog=0
#           → Desativa NMI watchdog. Libera um IRQ, reduz jitter de timer.
#
#       skew_tick=1
#           → Desincroniza os ticks dos CPUs em sistemas multi-core/NUMA.
#             Evita que todos os cores acordem ao mesmo tempo, reduzindo
#             latência e contenção de lock.
#
#       transparent_hugepage=madvise
#           → THP (Transparent HugePages) só é alocado quando o processo
#             solicita explicitamente via madvise(MADV_HUGEPAGE).
#             O padrão "always" causa stalls de alocação imprevisíveis.
#
#       amdgpu.ppfeaturemask=0xffffffff
#           → Habilita todas as features do driver AMDGPU, incluindo
#             OverDrive (controle manual de clock/voltagem da RX 560).
#
#       pcie_aspm=off
#           → Desabilita Active State Power Management do PCIe.
#             ASPM coloca o link PCIe em estado de baixo consumo quando
#             inativo, acordando com latência. Em desktop = micro-stutters
#             na GPU e NVMe. Desabilitar elimina esse jitter.
#
#       split_lock_detect=off
#           → Desativa a detecção de split-lock (acesso atômico cruzando
#             linha de cache). Sem isso, algumas workloads antigas geram
#             SIGBUS. Sem impacto de segurança em desktop.
#
#       iomem=relaxed
#           → Permite acesso userspace a regiões de memória de dispositivos
#             sem CAP_SYS_RAWIO. Necessário para algumas ferramentas de
#             diagnóstico de GPU e hardware.
#
#       quiet loglevel=3
#           → Boot limpo. Só mensagens de erro aparecem no console.
# ---------------------------------------------------------------------------
echo "  -> Configurando kernel cmdline de performance..."

COVENANT_CMDLINE="intel_pstate=disable cpufreq.default_governor=performance nvme_core.default_ps_state=0 nvme_core.io_timeout=4294967295 mitigations=off nowatchdog nmi_watchdog=0 skew_tick=1 transparent_hugepage=madvise amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off split_lock_detect=off iomem=relaxed quiet loglevel=3"

# --- a) GRUB ---
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/covenant-cmdline.cfg << GRUBCMD
# Covenant CachyOS — parâmetros de performance
# Injetado via GRUB_CMDLINE_LINUX_DEFAULT pelo grub-mkconfig
GRUB_CMDLINE_LINUX_DEFAULT="${COVENANT_CMDLINE}"
GRUBCMD

# Regenera grub.cfg se grub estiver presente
if command -v grub-mkconfig &>/dev/null && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null \
        && echo "     grub.cfg regenerado com novos parâmetros." \
        || echo "     grub-mkconfig: será aplicado no primeiro boot."
else
    echo "     GRUB: /etc/default/grub.d/covenant-cmdline.cfg instalado (aplicado na próxima grub-mkconfig)."
fi

# --- b) systemd-boot / UKI (kernel cmdline direto) ---
mkdir -p /etc/kernel/cmdline.d
echo "${COVENANT_CMDLINE}" > /etc/kernel/cmdline.d/covenant.conf
echo "     systemd-boot/UKI: /etc/kernel/cmdline.d/covenant.conf instalado."

# Hook pacman: re-aplica GRUB após cada atualização de kernel
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/covenant-grub-update.hook << 'GRUBHOOK'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = linux*
Target = grub

[Action]
Description = Covenant: regenerando GRUB após atualização de kernel...
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
GRUBHOOK

echo "     Hook pacman: grub-mkconfig automático após update de kernel instalado."
echo "     Kernel cmdline: performance total configurado."

# ---------------------------------------------------------------------------
# 17. Scheduler BORE — parâmetros para latência de desktop
#     CachyOS usa kernel BORE (Burst-Oriented Response Enhancer).
#     Os parâmetros abaixo reduzem latência de resposta para tarefas
#     interativas (desktop, compilação paralela, áudio) sem sacrificar
#     throughput nos 28 cores.
# ---------------------------------------------------------------------------
echo "  -> Configurando scheduler BORE/sched..."

cat > /etc/sysctl.d/91-covenant-sched.conf << 'SCHED'
# Covenant CachyOS — BORE scheduler tuning
# Xeon E5-2680v4 (14c/28t Broadwell-EP)

# Latência alvo do scheduler em ns (padrão: 6000000 = 6ms)
# Reduzir melhora responsividade; 3ms é bom para desktop com 28 cores
kernel.sched_latency_ns = 3000000

# Granularidade mínima de execução (padrão: 750000 = 0.75ms)
# Evita que tarefas sejam preemptadas muito cedo
kernel.sched_min_granularity_ns = 500000

# Wakeup granularity: quanto uma tarefa recém-acordada precisa "superar"
# a tarefa atual para preemptar (padrão: 1000000 = 1ms)
kernel.sched_wakeup_granularity_ns = 2000000

# Migration cost: custo estimado de mover thread entre cores (ns)
# Aumentar reduz migração desnecessária em Xeon com cache L3 grande
kernel.sched_migration_cost_ns = 5000000

# Autogroup: agrupa processos do mesmo terminal/sessão
# Isola builds intensos (make -j28) do restante do desktop
kernel.sched_autogroup_enabled = 1
SCHED

echo "     BORE/sched: latência de desktop configurada."

# ---------------------------------------------------------------------------
# 18. Coredump — desabilitado
#     Coredumps consomem I/O e disco sem utilidade em desktop.
#     Em caso de crash, o journald captura o backtrace via systemd-coredump.
# ---------------------------------------------------------------------------
echo "  -> Desabilitando coredumps..."

mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/covenant.conf << 'COREDUMP'
[Coredump]
Storage=none
ProcessSizeMax=0
COREDUMP

# Também via limits.d (dupla proteção)
cat >> /etc/security/limits.d/covenant.conf << 'CORELIMIT'
*      soft  core     0
*      hard  core     0
CORELIMIT

echo "     Coredumps desabilitados (storage=none + limits core=0)."

# ---------------------------------------------------------------------------
# 19. Hardware watchdog — desabilitado
#     O watchdog de hardware (iTCO_wdt no Xeon) reinicia a máquina se o
#     kernel travar por X segundos. Em desktop é desnecessário e consome
#     um timer de hardware. Separado do NMI watchdog (já desabilitado no cmdline).
# ---------------------------------------------------------------------------
echo "  -> Desabilitando hardware watchdog..."

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/covenant-watchdog.conf << 'HWWATCHDOG'
[Manager]
RuntimeWatchdogSec=off
RebootWatchdogSec=off
KExecWatchdogSec=off
HWWATCHDOG

# Blacklist o módulo iTCO_wdt (watchdog do Xeon/ICH)
echo 'blacklist iTCO_wdt' >> /etc/modprobe.d/covenant-blacklist.conf
echo 'blacklist iTCO_vendor_support' >> /etc/modprobe.d/covenant-blacklist.conf

echo "     Hardware watchdog: desabilitado (iTCO_wdt blacklisted)."

# ---------------------------------------------------------------------------
# 20. AMDGPU — power profile forçado em high performance
#     O ppfeaturemask já está no cmdline para habilitar overdrive.
#     Aqui forçamos o DPM (Dynamic Power Management) profile para
#     "high" via udev rule ao detectar o device AMDGPU.
#     Sem isso, a RX 560 pode ficar em profile "auto" e não escalar
#     clocks completamente sob carga.
# ---------------------------------------------------------------------------
echo "  -> Configurando AMDGPU power profile..."

cat > /etc/udev/rules.d/61-amdgpu-performance.rules << 'AMDGPURULES'
# Covenant CachyOS — AMDGPU performance profile
# Força DPM power_dpm_force_performance_level=high para AMD RX 560

# Perfil de performance: evita throttling no DPM da GPU
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="amdgpu", \
    ATTR{device/power_dpm_force_performance_level}="high"

# Método heurístico: liga ao detectar o device PCI da GPU
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", \
    ATTR{power/power_dpm_force_performance_level}="high"
AMDGPURULES

# Serviço de primeiro boot para garantir o profile após o driver carregar
cat > /etc/systemd/system/covenant-amdgpu-perf.service << 'AMDGPUSVC'
[Unit]
Description=Covenant CachyOS - AMDGPU Performance Profile
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  for card in /sys/class/drm/card[0-9]*/device; do \
    if [[ -f "$card/power_dpm_force_performance_level" ]]; then \
      echo "high" > "$card/power_dpm_force_performance_level" && \
      echo "AMDGPU: $card -> high performance profile"; \
    fi; \
  done'
ExecStop=/bin/bash -c '\
  for card in /sys/class/drm/card[0-9]*/device; do \
    [[ -f "$card/power_dpm_force_performance_level" ]] && \
      echo "auto" > "$card/power_dpm_force_performance_level"; \
  done'

[Install]
WantedBy=multi-user.target
AMDGPUSVC

systemctl enable covenant-amdgpu-perf.service 2>/dev/null \
    && echo "     AMDGPU: power profile high habilitado (serviço + udev)." \
    || echo "     AMDGPU: udev rule instalada (serviço ativo no primeiro boot)."

# ---------------------------------------------------------------------------
# 21. Hugepages estáticas — para JVM, browsers e compilação intensa
#     Com 64GB RAM, reservar 1GB de hugepages (512 x 2MB) não tem custo
#     perceptível. Aplicações como Java e compiladores alocam em hugepages
#     automaticamente via libhugetlbfs ou madvise(), reduzindo TLB misses.
# ---------------------------------------------------------------------------
echo "  -> Configurando hugepages estáticas..."

cat >> /etc/sysctl.d/91-covenant-sched.conf << 'HUGEPAGES'

# Hugepages estáticas — 1GB reservado (512 x 2MB)
# Reduce TLB pressure em workloads de compilação, JVM e browsers
vm.nr_hugepages = 512
# Hugepages movíveis: permite defrag sem reiniciar
vm.hugepages_treat_as_movable = 1
HUGEPAGES

# Monta hugetlbfs
if ! grep -q 'hugetlbfs' /etc/fstab 2>/dev/null; then
    printf '\n# Covenant — hugetlbfs\nhugetlbfs\t/dev/hugepages\thugetlbfs\tdefaults\t0 0\n' >> /etc/fstab
fi

echo "     Hugepages: 512x2MB reservadas + hugetlbfs no fstab."

# ---------------------------------------------------------------------------
# 22. Módulos de kernel — pré-carregados no boot
#     tcp_bbr já estava em modules-load.d.
#     Adiciona módulos que melhoram performance e são carregados tarde:
# ---------------------------------------------------------------------------
echo "  -> Configurando módulos de boot..."

cat >> /etc/modules-load.d/bbr.conf << 'MODULES'
# Covenant — módulos adicionais
dm_crypt       # desencriptação LUKS sem delay no boot
msr            # acesso a MSRs (necessário para algumas ferramentas de CPU)
cpuid          # informações de CPU para userspace
coretemp       # sensores de temperatura dos cores (Xeon)
MODULES

echo "     Módulos: coretemp, msr, cpuid adicionados ao boot."

# ---------------------------------------------------------------------------
# 23. Kernel Covenant — instala como padrão e configura GRUB
#
#     Os pacotes .pkg.tar.zst foram copiados para /root/covenant-pkgs/
#     durante o build da ISO. Aqui são instalados no airootfs e um
#     serviço de primeiro boot garante a instalação no sistema final.
# ---------------------------------------------------------------------------
echo "  -> Instalando kernel linux-covenant..."

COVENANT_PKGS_DIR="/root/covenant-pkgs"

if ls "${COVENANT_PKGS_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst &>/dev/null 2>&1; then

    pacman -U --noconfirm --needed \
        "${COVENANT_PKGS_DIR}"/linux-covenant-*.pkg.tar.zst 2>/dev/null \
        && echo "     linux-covenant instalado no airootfs." \
        || echo "     [!] Instalação no airootfs falhou — será feita no primeiro boot."

    cat > /usr/local/bin/covenant-kernel-setup.sh << 'KERNELSCRIPT'
#!/bin/bash
# Covenant CachyOS — kernel setup (primeiro boot)
PKGS_DIR="/root/covenant-pkgs"
DONE_FILE="/var/lib/covenant/kernel-setup-done"
LOG="/var/log/covenant-kernel-setup.log"
exec > >(tee -a "${LOG}") 2>&1
echo "[$(date)] covenant-kernel-setup iniciado"

if ! pacman -Qi linux-covenant &>/dev/null; then
    if ls "${PKGS_DIR}"/linux-covenant-[0-9]*.pkg.tar.zst &>/dev/null 2>&1; then
        pacman -U --noconfirm "${PKGS_DIR}"/linux-covenant-*.pkg.tar.zst \
            || { echo "[ERRO] Falha ao instalar linux-covenant"; exit 1; }
    else
        echo "[ERRO] Pacotes não encontrados em ${PKGS_DIR}"; exit 1
    fi
fi

[[ -f /boot/vmlinuz-linux-covenant ]] \
    || { echo "[ERRO] vmlinuz-linux-covenant não encontrado"; exit 1; }

if pacman -Qi linux-cachyos &>/dev/null; then
    pacman -R --noconfirm linux-cachyos linux-cachyos-headers 2>/dev/null \
        && echo "linux-cachyos removido." \
        || echo "[AVISO] Não foi possível remover linux-cachyos."
fi

mkinitcpio -p linux-covenant 2>/dev/null \
    && echo "initramfs gerado." \
    || echo "[AVISO] mkinitcpio falhou — usando initramfs existente."

if command -v grub-mkconfig &>/dev/null && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg \
        && sed -i 's/CachyOS Linux/Covenant-CachyOS/g' /boot/grub/grub.cfg \
        && grub-set-default 0 \
        && echo "GRUB atualizado → Covenant-CachyOS (default=0)."
fi

rm -rf "${PKGS_DIR}" 2>/dev/null || true

# Cria arquivo de marca — impede re-execução do serviço
mkdir -p /var/lib/covenant
touch "${DONE_FILE}"

echo "[$(date)] covenant-kernel-setup concluído."
systemctl disable covenant-kernel-setup.service 2>/dev/null || true
KERNELSCRIPT

    chmod +x /usr/local/bin/covenant-kernel-setup.sh

    cat > /etc/systemd/system/covenant-kernel-setup.service << 'KERNELSVC'
[Unit]
Description=Covenant CachyOS - Kernel Setup (primeiro boot)
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
KERNELSVC

    systemctl enable covenant-kernel-setup.service 2>/dev/null \
        && echo "     covenant-kernel-setup.service habilitado." \
        || echo "     [!] Será habilitado no primeiro boot."
else
    echo "     [!] linux-covenant não encontrado em ${COVENANT_PKGS_DIR} — pulando."
fi
echo "    $(du -sh /usr/share 2>/dev/null | cut -f1) — /usr/share após limpeza"
echo ""
echo "==> [OTIMIZAÇÕES] Resumo aplicado:"
echo "    ✓ sysctl: BBR, VM, rede, NUMA"
echo "    ✓ zram: 8GB zstd"
echo "    ✓ I/O: NVMe(none+nr_requests+wbt+rq_affinity), SSD(mq-deadline), HDD(bfq+readahead)"
echo "    ✓ I/O sysctl: dirty_ratio, vfs_cache_pressure"
echo "    ✓ makepkg: -march=native -O2, threads auto"
echo "    ✓ ananicy-cpp: regras compilação/WM/audio"
echo "    ✓ earlyoom: kill em <3% RAM livre"
echo "    ✓ Env vars: RADV/Mesa/Vulkan/Qt Wayland"
echo "    ✓ Serviços: irqbalance, power-profiles-daemon, fstrim (diário), earlyoom"
echo "    ✓ journald: 512MB máx, 1 semana"
echo "    ✓ DNS: 1.1.1.1/9.9.9.9 com cache"
echo "    ✓ CPU governor: performance (serviço de primeiro boot)"
echo "    ✓ Limites: nofile=1M, nproc=131K"
echo "    ✓ /tmp: tmpfs 8GB em RAM"
echo "    ✓ pacman: downloads paralelos=5"
echo "    ✓ Kernel cmdline: intel_pstate=disable, mitigations=off, nvme_core ps=0, THP=madvise, AMDGPU overdrive, pcie_aspm=off"
echo "    ✓ BORE scheduler: latency_ns=3ms, migration_cost=5ms, autogroup=1"
echo "    ✓ Coredumps: desabilitados (storage=none)"
echo "    ✓ HW watchdog: desabilitado (iTCO_wdt blacklisted)"
echo "    ✓ AMDGPU: power profile=high (udev + serviço)"
echo "    ✓ Hugepages: 512x2MB estáticas + hugetlbfs"
echo "    ✓ Módulos: coretemp, msr, cpuid no boot"
echo "    ✓ Kernel: linux-covenant instalado como padrão (remove linux-cachyos no 1º boot)"
CLEANUP

chmod +x "${CLEANUP_SCRIPT}"
_log_ok "Script de limpeza + otimizações criado."

# Registra no customize_airootfs.sh (executado pelo mkarchiso no chroot)
CUSTOMIZE="${ARCHISO}/airootfs/root/customize_airootfs.sh"
if [[ -f "${CUSTOMIZE}" ]]; then
    if ! grep -q 'cleanup-airootfs.sh' "${CUSTOMIZE}"; then
        echo "" >> "${CUSTOMIZE}"
        echo "# Limpeza + Otimizações Covenant" >> "${CUSTOMIZE}"
        echo "bash /root/cleanup-airootfs.sh" >> "${CUSTOMIZE}"
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

# ---------------------------------------------------------------------------
# mkinitcpio.conf — NÃO sobrescrever
# O archiso usa hooks essenciais (archiso, archiso_loop_mnt) para montar
# o squashfs na ISO live. Sobrescrever causa travamento no boot.
# ---------------------------------------------------------------------------
_log_ok "mkinitcpio.conf — mantendo configuração original do archiso."

# ---------------------------------------------------------------------------
# Patch util-iso.sh — corrige mv hardcoded "cachyos-DATE.iso"
# ---------------------------------------------------------------------------
_log_step "Verificando patch do util-iso.sh..."
[[ -r "${UTIL_ISO}" ]] || _log_fail "util-iso.sh não encontrado."

# Patch 1: corrige nome do arquivo ISO ("cachyos-" → nome customizado)
if grep -q '"cachyos-' "${UTIL_ISO}"; then
    cp "${UTIL_ISO}" "${UTIL_ISO}.bak"
    sed -i "s|\"cachyos-\$(date|\"${ISO_NAME_SAFE}-\$(date|g" "${UTIL_ISO}"
    grep -q "\"${ISO_NAME_SAFE}-\$(date" "${UTIL_ISO}" \
        && _log_ok "util-iso.sh: nome da ISO corrigido para '${ISO_NAME_SAFE}-'." \
        || { cp "${UTIL_ISO}.bak" "${UTIL_ISO}"; _log_warn "Patch de nome falhou — restaurado."; }
else
    _log_ok "util-iso.sh: nome da ISO não precisa de correção."
fi

# ---------------------------------------------------------------------------
# Patch 2: SigLevel — abordagem direta no /usr/bin/mkarchiso
#
# O mkarchiso chama pacman com -C <pacman.conf> onde <pacman.conf> é o
# arquivo copiado para ${work_dir}/archiso/pacman.conf.
# A forma mais confiável de forçar SigLevel=Never é patchar o próprio
# mkarchiso para adicionar --config com SigLevel correto, OU simplesmente
# fazer sed no pacman.conf DENTRO do work_dir após o cp -r.
#
# O util-iso.sh já tem modify_mkarchiso() — aproveitamos o mesmo mecanismo
# para adicionar nosso patch via append na função modify_mkarchiso.
# ---------------------------------------------------------------------------

# Verifica se o patch já foi aplicado
if ! grep -q 'Covenant.*SigLevel' "${UTIL_ISO}"; then

    # Append dentro de modify_mkarchiso() para reaplicar SigLevel após o
    # cp -r archiso ${work_dir}/archiso já ter sido executado.
    # Fazemos isso substituindo a linha do cp -r por ela mesma + nosso patch.
    python3 << PYEOF
import re

with open('${UTIL_ISO}', 'r') as f:
    content = f.read()

old = '    cp -r archiso \${work_dir}/archiso'
new = '''    cp -r archiso \${work_dir}/archiso

    # Covenant: força SigLevel=Never no pacman.conf do work_dir
    # Resolve 404 nos .db.sig do mirror archlinux.cachyos.org
    _wdir_pacman="\${work_dir}/archiso/pacman.conf"
    if [[ -f "\${_wdir_pacman}" ]]; then
        sed -i 's/^SigLevel\\s*=.*/SigLevel = Never/' "\${_wdir_pacman}"
        grep -q '^LocalFileSigLevel' "\${_wdir_pacman}" \\
            || echo 'LocalFileSigLevel = Never' >> "\${_wdir_pacman}"
        echo "==> [Covenant] SigLevel=Never aplicado em \${_wdir_pacman}"
    fi'''

if old in content:
    content = content.replace(old, new)
    with open('${UTIL_ISO}', 'w') as f:
        f.write(content)
    print('OK: SigLevel patch aplicado no util-iso.sh')
else:
    print('WARN: linha cp -r nao encontrada — patch nao aplicado')
PYEOF

    grep -q 'Covenant.*SigLevel' "${UTIL_ISO}" \
        && _log_ok "util-iso.sh: patch SigLevel=Never adicionado após cp -r." \
        || _log_warn "util-iso.sh: patch SigLevel não aplicado — tentativa alternativa..."

    # Alternativa: patcha diretamente o /usr/bin/mkarchiso para ignorar sig
    # Adiciona --config inline substituindo a chamada do pacman dentro do mkarchiso
    if ! grep -q 'Covenant.*SigLevel' "${UTIL_ISO}"; then
        _log_warn "Aplicando SigLevel diretamente no /usr/bin/mkarchiso..."
        if grep -q 'SigLevel' /usr/bin/mkarchiso 2>/dev/null; then
            sudo sed -i 's/SigLevel = Required DatabaseOptional/SigLevel = Never/g' \
                /usr/bin/mkarchiso 2>/dev/null \
                && _log_ok "/usr/bin/mkarchiso: SigLevel=Never aplicado." \
                || _log_warn "Falha ao patchar /usr/bin/mkarchiso."
        fi
        # Força via pacman.conf da archiso (última linha de defesa)
        if [[ -f "${PACMAN_CONF}" ]]; then
            sed -i 's/^SigLevel\s*=.*/SigLevel = Never/'       "${PACMAN_CONF}"
            sed -i 's/^LocalFileSigLevel\s*=.*/LocalFileSigLevel = Never/' "${PACMAN_CONF}"
            grep -q '^LocalFileSigLevel' "${PACMAN_CONF}" \
                || echo 'LocalFileSigLevel = Never' >> "${PACMAN_CONF}"
            _log_ok "pacman.conf da archiso: SigLevel=Never (fallback)."
        fi
    fi
else
    _log_ok "util-iso.sh: patch SigLevel já aplicado."
fi

# Patch 3: fetch_cachyos_mirrorlist — usa mirrorlist local do host
if grep -q 'fetch_cachyos_mirrorlist' "${UTIL_ISO}" \
&& ! grep -q 'Covenant.*mirrorlist local' "${UTIL_ISO}"; then

    python3 << PYEOF2
with open('${UTIL_ISO}', 'r') as f:
    content = f.read()

# Substitui o corpo da função fetch_cachyos_mirrorlist
import re
old_func = re.search(
    r'(fetch_cachyos_mirrorlist\(\)\s*\{)(.*?)(\n\})',
    content, re.DOTALL
)
if old_func:
    new_func = '''fetch_cachyos_mirrorlist() {
    # Covenant: usa mirrorlist local do host (já atualizado pela sanitização)
    mkdir -p "\${src_dir}/archiso/airootfs/etc/pacman.d"
    if [[ -f /etc/pacman.d/cachyos-mirrorlist ]]; then
        cp /etc/pacman.d/cachyos-mirrorlist \\
            "\${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist"
        echo "==> [Covenant] cachyos-mirrorlist: usando versão local do host."
    fi
    [[ -f /etc/pacman.d/mirrorlist ]] && \\
        cp /etc/pacman.d/mirrorlist \\
            "\${src_dir}/archiso/airootfs/etc/pacman.d/mirrorlist"
}'''
    content = content[:old_func.start()] + new_func + content[old_func.end():]
    with open('${UTIL_ISO}', 'w') as f:
        f.write(content)
    print('OK: fetch_cachyos_mirrorlist substituído')
else:
    print('WARN: função não encontrada')
PYEOF2

    grep -q 'Covenant.*mirrorlist local' "${UTIL_ISO}" \
        && _log_ok "util-iso.sh: fetch_cachyos_mirrorlist usa mirrorlist local." \
        || _log_warn "util-iso.sh: substituição de fetch_cachyos_mirrorlist falhou."
fi

# ---------------------------------------------------------------------------
# Carregar utilitários do repositório
# ---------------------------------------------------------------------------
_log_step "Carregando utilitários..."
src_dir="${REPO_DIR}"
cd "${src_dir}" || _log_fail "Não foi possível acessar '${src_dir}'."

[[ -r "${src_dir}/util-msg.sh" ]] \
    && { source "${src_dir}/util-msg.sh"; _log_ok "util-msg.sh carregado."; } \
    || _log_warn "util-msg.sh não encontrado."

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
# Build em RAM
# ---------------------------------------------------------------------------
_log_step "Modo de build..."
if [[ "$build_in_ram" == "true" ]]; then
    local_ram_gb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
    if [[ $local_ram_gb -gt 23 ]]; then
        work_dir="$(mktemp -d --suffix="-cachyos-iso")"
        _log_ok "Build em RAM (${local_ram_gb}GB): ${work_dir}"
    else
        _log_warn "RAM insuficiente (${local_ram_gb}GB). Usando disco."
    fi
else
    _log_ok "Build em disco: ${work_dir}"
    _log_warn "Dica: use -r para build em RAM (64GB disponíveis)."
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
# Traps
# ---------------------------------------------------------------------------
for sig in TERM HUP QUIT; do
    trap "trap_exit $sig \"$(gettext "%s signal caught. Exiting...")\" \"$sig\"" "$sig"
done
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
echo "    Performance : gamemode, irqbalance, zram, f2fs"
echo "    Limpeza     : locales, docs, fontes CJK, ícones"
echo "    Otimizações : sysctl/BBR, ananicy-cpp, earlyoom,"
echo "                  I/O scheduler, RADV/Mesa, CPU gov,"
echo "                  makepkg native, DNS cache, /tmp RAM"
echo "    Gaming apps : instalar pós-setup"
echo "    ================================================"
echo ""

timer_start=$(get_timer)
run_build "${build_list_iso}"
