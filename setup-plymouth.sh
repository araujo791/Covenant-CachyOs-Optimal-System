#!/bin/bash
# Configura Plymouth (tema Covenant) na ISO CachyOS
# Execute a partir de qualquer lugar — detecta o repo automaticamente

_log_step() { echo ""; echo "===> [PASSO] $*"; }
_log_ok()   { echo "    [OK] $*"; }
_log_warn() { echo "    [AVISO] $*"; }
_log_fail() { echo ""; echo "    [ERRO] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Detecta o repositório
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tenta localizar cachyos-live-iso relativo ao script ou ao diretório atual
for candidate in \
    "${SCRIPT_DIR}/cachyos-live-iso" \
    "${SCRIPT_DIR}" \
    "$(pwd)/cachyos-live-iso" \
    "$(pwd)"; do
    if [[ -f "${candidate}/archiso/profiledef.sh" ]]; then
        REPO_DIR="${candidate}"
        break
    fi
done

[[ -n "${REPO_DIR}" ]] \
    || _log_fail "Repositório cachyos-live-iso não encontrado. Execute o script dentro de CachyOs-Stock/ ou cachyos-live-iso/."

ARCHISO="${REPO_DIR}/archiso"
GRUB_CFG="${ARCHISO}/grub/grub.cfg"
MKINIT="${ARCHISO}/airootfs/etc/mkinitcpio.conf"
PACKAGES="${ARCHISO}/packages.x86_64"
PLYMOUTHD="${ARCHISO}/airootfs/etc/plymouth/plymouthd.conf"

echo ""
echo "========================================"
echo "  Configuração Plymouth — Covenant ISO"
echo "========================================"
echo "  Repositório : ${REPO_DIR}"
echo "  grub.cfg    : ${GRUB_CFG}"
echo "  packages    : ${PACKAGES}"
echo "  mkinitcpio  : ${MKINIT}"
echo "========================================"

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || _log_fail "Execute com sudo: sudo bash ${0##*/}"

# ---------------------------------------------------------------------------
# 1. Adicionar plymouth ao packages.x86_64
# ---------------------------------------------------------------------------
_log_step "1/3 — Verificando pacote plymouth em packages.x86_64..."

[[ -f "${PACKAGES}" ]] || _log_fail "Arquivo não encontrado: ${PACKAGES}"

if grep -q '^plymouth$' "${PACKAGES}"; then
    _log_ok "plymouth já está em packages.x86_64"
else
    echo "plymouth" >> "${PACKAGES}"
    _log_ok "plymouth adicionado em packages.x86_64"
fi

# ---------------------------------------------------------------------------
# 2. Adicionar sd-plymouth nos HOOKS do mkinitcpio.conf
# O sistema usa systemd (sd-*), então o hook correto é sd-plymouth
# Posição: depois de 'kms', antes de 'block'
# ---------------------------------------------------------------------------
_log_step "2/3 — Verificando HOOKS do mkinitcpio.conf..."

# O mkinitcpio.conf pode não existir ainda no airootfs (é gerado no build)
# Criamos/editamos o arquivo de override em airootfs/etc/
mkdir -p "${ARCHISO}/airootfs/etc"

if [[ ! -f "${MKINIT}" ]]; then
    _log_warn "mkinitcpio.conf não encontrado no airootfs — criando override..."
    cat > "${MKINIT}" << 'MKINITEOF'
# Gerado pelo setup-plymouth.sh — Covenant CachyOS
[COMPRESSION]
COMPRESSION="zstd"

# HOOKS
HOOKS=(base systemd autodetect microcode modconf kms sd-plymouth keyboard sd-vconsole block filesystems fsck)
MKINITEOF
    _log_ok "mkinitcpio.conf criado com sd-plymouth nos HOOKS."
else
    if grep -q 'sd-plymouth\|plymouth' "${MKINIT}"; then
        _log_ok "plymouth já está nos HOOKS."
    else
        # Insere sd-plymouth depois de kms, antes de keyboard
        sed -i 's/\bkms\b/kms sd-plymouth/' "${MKINIT}"

        if grep -q 'sd-plymouth' "${MKINIT}"; then
            _log_ok "sd-plymouth adicionado nos HOOKS (após kms)."
        else
            # Fallback: insere antes de block
            sed -i 's/\bblock\b/sd-plymouth block/' "${MKINIT}"
            _log_ok "sd-plymouth adicionado nos HOOKS (antes de block)."
        fi
    fi
fi

echo ""
echo "    HOOKS atual:"
grep '^HOOKS=' "${MKINIT}" | sed 's/^/      /'

# ---------------------------------------------------------------------------
# 3. Adicionar quiet splash no grub.cfg — todas as entradas linux
# ---------------------------------------------------------------------------
_log_step "3/3 — Verificando parâmetros quiet splash no grub.cfg..."

[[ -f "${GRUB_CFG}" ]] || _log_fail "grub.cfg não encontrado: ${GRUB_CFG}"

# Backup
cp "${GRUB_CFG}" "${GRUB_CFG}.bak"
_log_ok "Backup criado: ${GRUB_CFG}.bak"

if grep -q 'quiet splash' "${GRUB_CFG}"; then
    _log_ok "quiet splash já está no grub.cfg."
else
    # Adiciona quiet splash no final de cada linha linux (exceto memtest/fallback nomodeset)
    # Para a entrada fallback (nomodeset) NÃO adicionamos splash — não faz sentido
    sed -i '/^\s*linux .*vmlinuz.*cachyos[^-]/{/nomodeset/!s/$/ quiet splash/}' "${GRUB_CFG}"
    sed -i '/^\s*linux .*vmlinuz.*cachyos-lts/{/nomodeset/!s/$/ quiet splash/}' "${GRUB_CFG}"

    if grep -q 'quiet splash' "${GRUB_CFG}"; then
        _log_ok "quiet splash adicionado nas entradas do kernel."
    else
        _log_warn "Não foi possível adicionar quiet splash automaticamente."
        _log_warn "Edite manualmente: ${GRUB_CFG}"
        _log_warn "Adicione 'quiet splash' ao final das linhas que começam com 'linux /'"
    fi
fi

echo ""
echo "    Linhas linux do grub.cfg:"
grep '^\s*linux ' "${GRUB_CFG}" | sed 's/^/      /'

# ---------------------------------------------------------------------------
# 4. Verificar plymouthd.conf
# ---------------------------------------------------------------------------
_log_step "Verificando plymouthd.conf..."

if [[ -f "${PLYMOUTHD}" ]]; then
    THEME_SET=$(grep '^Theme=' "${PLYMOUTHD}" | cut -d= -f2)
    _log_ok "plymouthd.conf encontrado — Theme=${THEME_SET}"
else
    mkdir -p "$(dirname "${PLYMOUTHD}")"
    cat > "${PLYMOUTHD}" << 'PLYEOF'
[Daemon]
Theme=covenant
ShowDelay=0
DeviceTimeout=8
PLYEOF
    _log_ok "plymouthd.conf criado com Theme=covenant."
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Configuração Plymouth concluída!"
echo "========================================"
echo "  ✓ plymouth em packages.x86_64"
echo "  ✓ sd-plymouth nos HOOKS do mkinitcpio"
echo "  ✓ quiet splash no grub.cfg"
echo "  ✓ plymouthd.conf com Theme=covenant"
echo ""
echo "  Próximo passo: sudo bash build-stock-iso.sh"
echo "========================================"
echo ""
