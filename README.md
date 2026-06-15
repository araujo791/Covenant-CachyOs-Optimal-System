# Covenant CachyOS Optimal System

**Branch: Covenant** — Versão aprimorada com otimizações agressivas de performance para hardware específico:
- **CPU**: Xeon E5-2680v4 (14c/28t Broadwell)
- **GPU**: AMD RX 560 Polaris
- **RAM**: 64GB ECC
- **Storage**: NVMe principal

## Principais Otimizações

- Kernel cmdline agressivo (`mitigations=off` mantido)
- CPU Governor `performance` fixo + IRQ affinity otimizado
- I/O Scheduler otimizado (NVMe=none, etc.)
- Hugepages reservadas + zram zstd
- makepkg com `-march=native -O2` + ccache
- Rede: TCP BBR + buffers grandes + DNS-over-TLS
- Remoção inteligente de pacotes
- Serviços: earlyoom, ananicy-cpp, thermald, fstrim
- Extra otimizações integradas automaticamente no post-install

## ⚠️ Aviso de Segurança Crítico

**`mitigations=off`** está **mantido**. Isso desabilita várias mitigações de CPU. Use apenas em ambientes controlados.

## Como Usar

1. Clone a branch `Covenant`
2. Execute `./build-iso.sh` para gerar a ISO customizada
3. Instale a ISO gerada
4. No primeiro boot, o `post-install.sh` é executado automaticamente e aplica **todas** as otimizações, incluindo as extras.
5. Rode `covenant-check.sh` para verificar tudo.

Tudo é aplicado de forma automática e verificável.
