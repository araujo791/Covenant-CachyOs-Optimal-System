#!/bin/bash
# Instala o tema Covenant no airootfs do CachyOS-Live-ISO
# Execute a partir da raiz do repositório clonado (cachyos-live-iso/)

set -e

AIROOTFS="archiso/airootfs"
THEME_SRC="$(dirname "$(realpath "$0")")/../theme"
THEME_DEST="${AIROOTFS}/usr/share/plymouth/themes/covenant"
CONF_DEST="${AIROOTFS}/etc/plymouth"

echo "==> Instalando tema Plymouth Covenant..."

if [[ ! -d "${AIROOTFS}" ]]; then
    echo "ERRO: Execute este script a partir da raiz do repositório cachyos-live-iso/"
    echo "      (onde fica a pasta 'archiso/')"
    exit 1
fi

mkdir -p "${THEME_DEST}"
mkdir -p "${CONF_DEST}"

cp "${THEME_SRC}/covenant.plymouth" "${THEME_DEST}/"
cp "${THEME_SRC}/covenant.script"   "${THEME_DEST}/"
cp "${THEME_SRC}/logo.png"          "${THEME_DEST}/"
cp "$(dirname "$(realpath "$0")")/../conf/plymouthd.conf" "${CONF_DEST}/"

echo "    [OK] Arquivos copiados para ${THEME_DEST}"
echo "    [OK] plymouthd.conf copiado para ${CONF_DEST}"
echo ""
echo "==> Verifique se 'plymouth' está em Packages-Root:"
echo "    grep -q '^plymouth$' archiso/Packages-Root || echo 'plymouth' >> archiso/Packages-Root"
echo ""
echo "==> Tema Covenant instalado. Execute sudo bash build-stock-iso.sh normalmente."
