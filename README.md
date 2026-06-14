# Covenant CachyOS Optimal System

**Branch: Covenant** — Versão aprimorada e mantida com otimizações agressivas de performance para hardware específico:
- **CPU**: Xeon E5-2680v4 (14c/28t Broadwell)
- **GPU**: AMD RX 560 Polaris
- **RAM**: 64GB ECC
- **Storage**: NVMe principal

## Principais Otimizações

- Kernel cmdline agressivo (`mitigations=off` mantido)
- CPU Governor `performance` fixo + IRQ affinity
- I/O Scheduler otimizado (NVMe=none, etc.)
- Hugepages reservadas + zram zstd
- makepkg com `-march=native -O2` + ccache
- Rede: TCP BBR + buffers grandes + DoT
- Remoção inteligente de pacotes (WiFi, NVIDIA, gaming pesado)
- Serviços: earlyoom, ananicy-cpp, thermald, fstrim

## ⚠️ Aviso de Segurança Crítico

**`mitigations=off`** está **mantido** conforme sua solicitação. Isso desabilita mitigações Spectre/Meltdown e outras proteções de CPU. Recomendado apenas para workstations isoladas/offline ou ambientes altamente controlados. Considere o risco de exploração.

## Melhorias Implementadas na Branch Covenant

- README mais profissional e completo
- Estrutura de logs e error handling reforçada
- Comentários explicativos em pontos chave
- Preparação para modularização futura do build-iso.sh
- Versão atualizada do post-install.sh

**Sempre trabalhe na branch `Covenant`**.

Para mais otimizações ou ajustes, me avise!