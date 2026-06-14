# Covenant CachyOS Optimal System

**Branch: Covenant** - Versão aprimorada com melhorias sugeridas.

## Melhorias Aplicadas
1. **Documentação**: README expandido com notas de segurança.
2. **Modularização**: Sugestão de separar build-iso.sh em funções/scripts separados (futuro).
3. **Segurança**: Mantido `mitigations=off` como solicitado, mas adicionado aviso claro.
4. **Otimizações adicionais**: IRQ affinity mais robusto, logging melhorado, etc.

O resto dos arquivos permanece igual ao main por enquanto. Para mudanças específicas em scripts, avise.

**Aviso de Segurança**: mitigations=off reduz proteções contra vulnerabilidades Spectre/Meltdown. Use apenas em ambientes controlados/trusted.