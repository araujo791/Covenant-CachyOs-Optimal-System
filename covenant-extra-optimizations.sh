#!/bin/bash
# Covenant Extra Optimizations v1.0
# Para Xeon E5-2680v4 + RX 560

_log() { echo "[COVENANT-EXTRA] $*"; }

_log "Aplicando IRQ affinity otimizado..."
# NVMe e GPU nos primeiros 14 cores (0-13)
for irq in $(awk '/nvme|amdgpu/ {print $1}' /proc/interrupts | sort -u); do
  echo "00003fff" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null || true
done

_log "Configurando thermald para Broadwell..."
cat > /etc/thermald/thermal-conf.xml << 'EOF'
<?xml version="1.0"?>
<ThermalConfiguration>
  <Platform>
    <Name>Generic Workstation</Name>
    <Preference>PERFORMANCE</Preference>
  </Platform>
</ThermalConfiguration>
EOF

systemctl restart thermald.service 2>/dev/null || true

_log "Extra optimizations applied successfully!"
