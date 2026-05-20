# Covenant CachyOS — Tema Plymouth

## Estrutura
```
covenant-plymouth/
├── theme/
│   ├── covenant.plymouth   ← declaração do tema
│   ├── covenant.script     ← animação (spinner + barra de progresso)
│   └── logo.png            ← logo 120x120px
├── conf/
│   └── plymouthd.conf      ← ativa o tema como padrão
└── scripts/
    └── install-theme.sh    ← copia tudo para o airootfs
```

## Como instalar

1. Copie esta pasta para dentro do seu repositório `cachyos-live-iso/`
2. A partir da raiz do repositório, execute:
   ```bash
   bash covenant-plymouth/scripts/install-theme.sh
   ```
3. Certifique-se de que `plymouth` está em `archiso/Packages-Root`
4. Build normalmente:
   ```bash
   sudo bash build-stock-iso.sh
   ```

## Customizar a logo

Substitua `theme/logo.png` por qualquer PNG 120x120px com fundo transparente.
Para testar sem buildar a ISO completa:
```bash
sudo plymouthd
sudo plymouth --show-splash
sleep 5
sudo killall plymouthd
```

## Cores do tema

| Elemento       | Hex       |
|----------------|-----------|
| Fundo          | `#0a0c10` |
| Anel externo   | `#2a6dd9` |
| Anel interno   | `#1a4fa0` |
| Texto / logo   | `#4a8ff0` |
