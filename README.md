# Covenant CachyOS

ISO customizada do CachyOS otimizada para hardware específico de workstation.

**Hardware alvo:** Xeon E5-2680v4 (14c/28t, 56 threads) · AMD RX 560 · 64GB ECC RAM · NVMe · Ethernet r8169

---

## Estrutura do repositório

```
Covenant-CachyOs-Optimal-System/
├── build-iso.sh              # Script principal de build
├── post-install.sh           # Script de pós-instalação standalone
├── packages.x86_64           # Lista de pacotes customizada
├── packages_desktop.x86_64   # Pacotes KDE extras
└── wallpapers/               # Wallpapers customizados (png, jpg, jpeg, webp)
```

---

## Build

### Requisitos do host
- Arch Linux ou CachyOS
- `archiso`, `mkinitcpio-archiso`, `git`, `squashfs-tools`, `grub`

### Clonar e buildar

```bash
git clone https://github.com/araujo791/Covenant-CachyOs-Optimal-System.git
cd Covenant-CachyOs-Optimal-System
sudo bash build-iso.sh
```

Para build em RAM (requer ~30GB livres):
```bash
sudo bash build-iso.sh -r
```

A ISO é gerada em `cachyos-live-iso/out/desktop/`.

---

## Instalação

1. Grave a ISO em um pendrive
2. Boot pela ISO
3. Instale normalmente pelo Calamares (online ou offline)
4. Reinicie — o `covenant-first-boot.service` aplica todas as otimizações automaticamente no primeiro boot

Para verificar após o primeiro boot:
```bash
covenant-check.sh
```

Ou rode manualmente a qualquer momento:
```bash
sudo bash /usr/local/bin/covenant-post-install.sh
```

---

## O que é aplicado automaticamente

### Kernel (cmdline)
- `mitigations=off` — desabilita mitigações Spectre/Meltdown para máximo desempenho
- `nvme_core.default_ps_max_latency_us=0` — sem power saving no NVMe
- `nvme_core.io_timeout=4294967295` — timeout máximo para evitar reset sob carga
- `processor.max_cstate=1` + `intel_idle.max_cstate=1` — CPU nunca dorme profundamente
- `transparent_hugepage=madvise` — hugepages sob demanda
- `amdgpu.ppfeaturemask=0xffffffff` — controle total do clock/fan da RX 560
- `pcie_aspm=off` — sem power saving PCIe
- `nowatchdog` + `nmi_watchdog=0` — sem watchdog timers

### CPU
- Governor `performance` via `cpupower` (compatível com `acpi-cpufreq` do Xeon E5)
- `acpi_cpufreq` carregado via `modules-load.d`
- Regra udev para hotplug de CPU

### Memória
- zram 1GB zstd
- 1024 hugepages de 2MB (2GB reservados)
- `/tmp` em tmpfs de 16GB

### Rede
- TCP BBR + FQ
- Buffers de rede 128MB
- DNS-over-TLS (Cloudflare + Quad9)

### GPU (AMD RX 560)
- DPM level `manual` para clock máximo
- VA-API e VDPAU configurados
- Auto-detecção do slot PCIe (`card0`/`card1`)

### I/O
- NVMe: scheduler `none`, nr_requests 1024
- SSD: scheduler `mq-deadline`
- HDD: scheduler `bfq`

### Serviços habilitados
- `earlyoom` — kill de processos em <3% RAM
- `irqbalance` — distribuição de IRQs nos 14 cores físicos
- `ananicy-cpp` — prioridades de processos
- `thermald` — gerenciamento térmico
- `cpupower` — governor de performance
- `profile-sync-daemon` — perfis de browser em RAM

### Compilação
- `makepkg` com `-march=native -O2`, threads automático
- `ccache` 10GB

### Sistema
- Coredumps desabilitados
- Journald limitado a 512MB / 1 semana
- fstrim semanal
- IRQ affinity para NVMe e GPU nos cores físicos

---

## Wallpapers customizados

Coloque imagens (`.png`, `.jpg`, `.jpeg`, `.webp`) na pasta `wallpapers/` do repositório. O build as copia automaticamente para `/usr/share/wallpapers/cachyos-wallpapers/` na ISO e no sistema instalado.

---

## Verificação pós-instalação

```
=== Covenant CachyOS — Verificação de Otimizações ===
TCP Congestion:     bbr
CPU Governor:       performance
NVMe Scheduler:     [none]
zram:               /dev/zram0  1G zstd
Huge Pages:         1024 x 2MB
Mitigations:        OFF (intencional — mitigations=off)
GPU DPM Level:      manual
earlyoom:           active
irqbalance:         active
ananicy-cpp:        active
DNS-over-TLS:       DNSOverTLS
```

---

## ISO name customizado

Para nomear a ISO diferente do padrão `cachyos`:

```bash
export ISO_NAME_OVERRIDE="Covenant-CachyOS"
sudo bash build-iso.sh
```

Ou edite `iso_name=` no `profiledef.sh` do CachyOS-Live-ISO antes de buildar.
