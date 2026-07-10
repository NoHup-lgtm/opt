# OPT — Otimizador

Painel de otimização de PC para jogos competitivos, com medição real de antes/depois e
tudo 100% reversível. Contexto completo do produto e regras em [CLAUDE.md](CLAUDE.md).

## Rodar o MVP (PowerShell)

Painel (WPF — pede elevação, os tweaks de sistema precisam de admin):

```powershell
powershell -ExecutionPolicy Bypass -File mvp-powershell\OptimizerApp.ps1
```

CLI:

```powershell
.\mvp-powershell\Optimizer.ps1 list          # catálogo
.\mvp-powershell\Optimizer.ps1 status        # o que está aplicado
.\mvp-powershell\Optimizer.ps1 apply -All    # aplica Seguro+Moderado (cria ponto de restauração antes)
.\mvp-powershell\Optimizer.ps1 apply HAGS    # Avançado só por id explícito
.\mvp-powershell\Optimizer.ps1 revert-all    # desfaz TUDO
```

## Garantias

- Antes de qualquer mudança, o valor original vai para `%LOCALAPPDATA%\Optimizer\backup.json`.
- Todo apply tenta criar um ponto de restauração do Windows primeiro.
- Tudo que o app faz fica em `%LOCALAPPDATA%\Optimizer\optimizer.log`.
- `revert-all` / botão "DESFAZER TUDO" restaura cada valor ao estado original.

## Gerar .exe

```powershell
Install-Module ps2exe -Scope CurrentUser   # uma vez
.\mvp-powershell\build.ps1                 # gera mvp-powershell\dist\Optimizer.exe
```

## Estrutura

- `mvp-powershell/OptimizerCore.ps1` — motor: catálogo de tweaks, backup, log
- `mvp-powershell/Optimizer.ps1` — CLI
- `mvp-powershell/OptimizerApp.ps1` — painel WPF
- `mvp-powershell/build.ps1` — merge + ps2exe
- `docs/tweaks.md` — cada tweak documentado com fonte e risco
