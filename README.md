# OPT — Otimizador

Painel de otimização de PC para jogos competitivos, com medição real de antes/depois e
tudo 100% reversível. Contexto completo do produto e regras em [CLAUDE.md](CLAUDE.md).

## Rodar o MVP (PowerShell)

**Na máquina do cliente (validação) — um comando, sem clonar nada:**

```powershell
irm https://raw.githubusercontent.com/NoHup-lgtm/opt/main/get.ps1 | iex
```

Baixa motor + painel para `%LOCALAPPDATA%\Optimizer\app` e abre o painel (UAC).
Requer este repo público no GitHub. Para o produto vendido, o caminho continua
sendo o .exe assinado (`docs/distribuicao.md`).

**Localmente (dev):**

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

- Antes de qualquer mudança, o valor original vai para `%LOCALAPPDATA%\Optimizer\backup.json` (escrita atômica — crash não corrompe).
- Todo apply cria um ponto de restauração do Windows antes — e se o System Restore estiver desligado, o app avisa e pergunta em vez de falhar em silêncio.
- Cada tweak é **verificado depois de aplicado**: se GPO/antivírus rejeitou o valor, o app reporta falha em vez de sucesso falso.
- Uma trava entre instâncias impede CLI e painel de escreverem no backup ao mesmo tempo.
- Tudo que o app faz fica em `%LOCALAPPDATA%\Optimizer\optimizer.log`.
- `revert-all` / botão "DESFAZER TUDO" restaura cada valor ao estado original.

## Testes

```powershell
.\tests\run-tests.ps1                          # testes do motor (seguros, não aplicam nada real)
.\tests\vm-roundtrip.ps1 -EuSeiQueEstouNumaVM  # SÓ EM VM: aplica tudo, reverte tudo, faz diff
```

O CI (GitHub Actions, `windows-latest`) roda parse + testes + build a cada push.

## Suporte

Painel → "[ exportar diagnóstico ]" (ou `.\mvp-powershell\Optimizer.ps1 diag`) gera um .zip
local com log, backup e estado do sistema. Nada é enviado automaticamente.

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
