# CLAUDE.md — Optimizer

Contexto do projeto para o Claude Code. Leia este arquivo antes de qualquer tarefa.

## O que é

App de desktop para Windows que otimiza o PC para jogos competitivos com um clique, através de um painel. Vendido como produto/serviço para jogadores no Brasil (público com PC mediano que sofre com FPS baixo, stutter e ping alto). O diferencial é medição real de antes/depois e configuração específica por jogo — não é mais um "FPS booster" placebo.

Jogos NÃO são fixos no código. Valorant, CS2, GTA RP/FiveM e Warzone são só os primeiros; o app precisa suportar Fortnite, Apex, Rainbow Six, LoL, Overwatch e qualquer outro sem recompilar. Ver "Arquitetura data-driven" abaixo.

## Estado atual

- `mvp-powershell/OptimizerCore.ps1` — motor compartilhado: catálogo de tweaks, camada de backup (JSON), log e restore point. CLI e GUI carregam este arquivo.  
- `mvp-powershell/OptimizerApp.ps1` — MVP funcional: app WPF em PowerShell, roda direto no Windows, faz as otimizações de verdade (registro, powercfg), com apply/revert e ponto de restauração. Vira .exe com ps2exe (`build.ps1`). É o que está sendo validado com usuários.  
- `mvp-powershell/Optimizer.ps1` — motor de otimização em linha de comando (mesmo catálogo).  
- `docs/tweaks.md` — cada tweak documentado com fonte e risco (convenção obrigatória).  
- `tests/run-tests.ps1` — testes do motor (sem tocar em config real; rodam no CI a cada push).  
- `tests/vm-roundtrip.ps1` — prova de apply→revert completo; rodar em VM descartável antes de release.  
- `docs/distribuicao.md` — plano de code signing e mitigação de antivírus/SmartScreen.

## Direção de arquitetura

Curto prazo: shipar o MVP PowerShell para validar demanda (barato e rápido). Produto final: **C\# / .NET 8 WPF** em `src/`. Motivos: .exe assinável, acesso nativo ao registro (`Microsoft.Win32.Registry`) e WMI, sem depender de shellar PowerShell. Porte o motor primeiro (com testes), UI depois. A lógica toda já está especificada nos arquivos PowerShell — é tradução, não redesenho.

## Regras que NÃO podem ser quebradas

1. **Tudo reversível.** Antes de QUALQUER mudança no sistema, salvar o valor original em backup (JSON). Todo tweak tem `Apply` e `Revert`. Deve existir "desfazer tudo".  
2. **Ponto de restauração** do Windows criado antes de aplicar um perfil.  
3. **Nada de métrica inventada no produto vendido.** O readout de FPS só mostra números reais (capturados via PresentMon) ou claramente rotulados como estimativa. Vender FPS falso destrói a reputação no nicho — é o erro dos concorrentes.  
4. **Só incluir tweaks com impacto real** ou marcados honestamente como debatíveis. Tweaks que quebram PC (desativar serviços essenciais do Windows) ficam de fora.  
5. **Undervolt / overclock** nunca em "um clique automático" — só modo manual/avançado.  
6. **Transparência total** sobre o que o app faz (é o que separa de malware p/ o Defender).  
7. Para distribuir: **assinar o .exe** com certificado de code signing.

## Modelo de dados (mantenha em C\#)

Duas camadas separadas (a maioria dos concorrentes mistura — não misture):

1. **Otimizações de sistema** — valem para QUALQUER jogo (Game DVR, energia, Nagle, prioridade de GPU, efeitos visuais). Vivem no catálogo, em código. Cada uma é um objeto/classe com: `Id`, `Nome`, `Descrição`, `Categoria`, `Risco` (Seguro|Moderado|Avançado), `Efeito`, `Apply()`, `Revert()`.  
     
2. **Otimizações por jogo** — específicas de cada título (autoexec, .ini, streaming de textura, VRAM, config de vídeo). NÃO ficam em código; vêm dos perfis em JSON.

## Arquitetura data-driven (CRÍTICO)

Jogos são carregados de arquivos de perfil externos, um JSON por jogo em `profiles/`. Adicionar um jogo novo \= soltar um JSON, SEM tocar no código nem recompilar.

O app deve:

- Ler todos os `profiles/*.json` no start.  
- Detectar automaticamente o que está instalado (caminho de instalação, nome do processo, chave de registro de Steam/Epic/Riot/Battle.net) e mostrar na lateral só os jogos detectados (mais opção de mostrar todos).  
- Aplicar \= otimizações de sistema selecionadas \+ as ações por-jogo do JSON daquele título.

Formato de cada perfil (exemplo `profiles/fortnite.json`):

{

  "id": "fortnite",

  "nome": "Fortnite",

  "detect": {

    "processo": "FortniteClient-Win64-Shipping.exe",

    "caminhos": \["%ProgramFiles%/Epic Games/Fortnite"\],

    "registro": \["HKLM:/SOFTWARE/Epic Games/..."\]

  },

  "sistema": \["GameDVR", "Power", "VisualFX", "GpuPref"\],

  "porJogo": \[

    { "tipo": "iniEdit", "arquivo": "%LOCALAPPDATA%/FortniteGame/Saved/Config/WindowsClient/GameUserSettings.ini",

      "chave": "...", "valor": "...", "descricao": "modo performance" }

  \],

  "baseline": { "fps": 120, "low": 70, "lag": 15, "temp": 79 },

  "gain":     { "fps": 1.35, "low": 1.6, "lag": 0.7, "temp": \-9 }

}

Ações por-jogo também precisam de backup/revert (guardar o .ini/cfg original antes de editar).

## Design tokens (painel)

Conceito: **instrumento de diagnóstico de precisão** (telemetria), NÃO "gamer RGB".

- Fundo: `#0B0D12` (ink azulado, não preto puro)  
- Superfície: `#12151D` / `#161A24`  · Linhas: `#232838` / `#1C2130`  
- Texto: `#EDEEF4` (primário) · `#8A91A8` (mute) · `#565D73` (dim)  
- Acento (ação/ativo): violeta `#7C6CFF`, em gradiente para azul `#4EA8FF` no CTA e no logo (com glow suave)  
- Semânticos: ganho `#4ADE97` · risco `#F0566A` · aviso/moderado `#FFB454` · frio/temp `#4EC9E8`  
- Tipografia: números/telemetria sempre em MONO (Consolas no WPF). Títulos: Segoe UI SemiBold.  
- Assinatura: readout de telemetria antes→depois no topo (é o argumento de venda).

## Roadmap

- Fase 1 — endurecer MVP PowerShell \+ ps2exe \+ validar com 5 usuários.  
- Fase 2 — integrar PresentMon (medição real de FPS/1% low).  
- Fase 3 — reconstruir em .NET 8 WPF (motor \+ testes, depois UI).  
- Fase 4 — sistema de perfis data-driven (loader de JSON \+ detecção automática de jogos instalados) e depois escrever os perfis: CS2 autoexec, FiveM streaming, Warzone VRAM, Valorant Reflex, Fortnite GameUserSettings, Apex, R6, etc.  
- Fase 5 — confiança: revert testado em VM, code signing, tela de transparência.  
- Fase 6 — instalador \+ auto-update \+ licenciamento (integração com venda no Cakto).

## Convenções

- Toda alteração de sistema passa pela camada de backup — nunca escrever no registro direto.  
- Testar apply→revert em VM Windows limpa antes de considerar um tweak pronto.  
- Documentar cada tweak novo em `docs/` com fonte comprovando o impacto.  
- Logging em arquivo de tudo que é aplicado/revertido, com timestamp.

