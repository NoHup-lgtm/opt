# Catálogo de tweaks — documentação e fontes

Convenção (CLAUDE.md): todo tweak novo entra aqui com fonte comprovando o impacto e
classificação honesta de risco. Tweak sem fonte ou marcado como placebo não entra no catálogo.

Risco: **Seguro** (efeito conhecido, sem colateral) · **Moderado** (efeito real mas debatível ou com colateral visível) · **Avançado** (depende do hardware; medir antes/depois; requer reinício).

---

## GameDVR — Desativar Game DVR (Seguro)

- **O que faz:** `HKCU\System\GameConfigStore\GameDVR_Enabled = 0` e `HKCU\...\GameDVR\AppCaptureEnabled = 0`.
- **Impacto:** remove a captura de gameplay em segundo plano do Xbox Game Bar. Ganho pequeno mas real de frametime, principalmente em PCs fracos.
- **Fonte:** documentação da Microsoft sobre Game DVR/Game Bar (support.xbox.com — "Game DVR can affect gaming performance"); amplamente reproduzido em benchmarks da comunidade.

## GameMode — Ativar Modo de Jogo (Seguro)

- **O que faz:** `HKCU\SOFTWARE\Microsoft\GameBar\AutoGameModeEnabled = 1`.
- **Impacto:** o Windows prioriza o processo do jogo e suspende Windows Update/notificações durante a partida.
- **Fonte:** Microsoft Learn — "Game Mode" (recurso oficial, ativo por padrão no Win10/11 recente; aqui só garantimos que está ligado).

## Power — Plano Alto Desempenho (Seguro)

- **O que faz:** `powercfg /setactive 8c5e7fda-...` (High Performance). O GUID do plano anterior fica no backup.
- **Impacto:** impede downclock agressivo da CPU em cargas variáveis; melhora consistência de frametime (não FPS máximo).
- **Fonte:** Microsoft Learn — power plans / processor power management.

## MouseAccel — Desativar aceleração do mouse (Seguro)

- **O que faz:** `HKCU\Control Panel\Mouse`: `MouseSpeed=0`, `MouseThreshold1=0`, `MouseThreshold2=0`. Vale a partir do próximo logon.
- **Impacto:** consistência de mira (input 1:1). Não afeta FPS — vendido como consistência, nunca como desempenho.
- **Fonte:** comportamento documentado do "Enhance pointer precision"; recomendação padrão em todo guia competitivo (Valorant/CS).

## VisualFX — Efeitos visuais: melhor desempenho (Moderado)

- **O que faz:** `HKCU\...\Explorer\VisualEffects\VisualFXSetting = 2` ("Adjust for best performance").
- **Impacto:** libera CPU/GPU de animações/transparências do Windows. Perceptível em PCs fracos; colateral: o Windows fica visivelmente mais "cru".
- **Fonte:** configuração oficial do Windows (Sysdm.cpl → Performance Options).

## GpuPref — Prioridade GPU/CPU para jogos (Moderado)

- **O que faz:** `HKLM\...\Multimedia\SystemProfile\Tasks\Games`: `GPU Priority=8`, `Priority=6`, `Scheduling Category=High`.
- **Impacto:** o MMCSS agenda a task "Games" com prioridade mais alta. Debatível — vários benchmarks mostram ganho nulo em PCs sem contenção; sem risco conhecido.
- **Fonte:** Microsoft Learn — Multimedia Class Scheduler Service (MMCSS).

## NetThrottle — Network Throttling / SystemResponsiveness (Moderado)

- **O que faz:** `HKLM\...\Multimedia\SystemProfile`: `NetworkThrottlingIndex=0xFFFFFFFF` (desativa), `SystemResponsiveness=10` (padrão 20).
- **Impacto:** o Windows limita pacotes de rede (~10/ms) quando há multimídia rodando; desativar pode reduzir lag em jogo online. Debatível em hardware moderno — medir.
- **Fonte:** Microsoft — MMCSS/NetworkThrottlingIndex (documentado no MSDN); requer reinício.

## Nagle — Desativar algoritmo de Nagle (Moderado)

- **O que faz:** em cada interface com IP ativo: `TcpAckFrequency=1`, `TCPNoDelay=1`.
- **Impacto:** desliga o agrupamento de pacotes TCP. Só afeta jogos/tráfego TCP (LoL, alguns MMOs). **Não afeta** CS2/Valorant (UDP) — o app deixa isso claro na descrição.
- **Fonte:** RFC 896 (Nagle); artigos KB da Microsoft sobre TcpAckFrequency.

## PowerThrottle — Desativar Power Throttling (Moderado)

- **O que faz:** `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling\PowerThrottlingOff = 1`.
- **Impacto:** o Windows deixa de reduzir clock de processos "em segundo plano" (overlays, anti-cheat, Discord). Colateral: maior consumo de energia (relevante em notebook).
- **Fonte:** Microsoft Learn — Power Throttling (Windows 10 1709+); requer reinício.

## WindowedOpt — Otimizações para jogos em janela (Seguro · GPU · só Win11)

- **O que faz:** `HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings = "SwapEffectUpgradeEnable=1;"`.
- **Impacto:** habilita o modelo de apresentação moderno (flip) para jogos DX10/11 em janela/borderless — menor latência para quem joga em janela sem borda. Recurso oficial do Windows 11; o app o marca como indisponível no Windows 10.
- **Colateral:** se o valor já contém outras flags (ex.: VRR), o original fica preservado no backup.
- **Fonte:** Microsoft DirectX Developer Blog — "Optimizations for windowed games" (2022).

## HAGS — Agendamento de GPU por hardware (Avançado · GPU)

- **O que faz:** `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode = 2`. Requer GPU dedicada com driver compatível (NVIDIA GTX 10xx+/RTX, AMD RX 5000+) e reinício.
- **Impacto:** move o agendamento de GPU para o hardware. Em algumas GPUs melhora latência de frame; em outras piora ou causa stutter. Por isso é Avançado e NUNCA entra em lote/um-clique.
- **Detecção:** o app detecta a GPU via `Win32_VideoController` e desabilita este tweak em máquinas só com GPU integrada.
- **Fonte:** Microsoft DirectX Developer Blog — "Hardware Accelerated GPU Scheduling" (2020).

## MPO — Desativar Multi-Plane Overlay (Avançado · GPU)

- **O que faz:** `HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode = 5`. Requer reinício.
- **Impacto:** desliga o MPO do compositor. Correção conhecida para stutter, flicker e tela preta em setups NVIDIA/AMD com G-Sync/FreeSync e overlays. **Só faz sentido para quem tem os sintomas** — a descrição no app diz isso explicitamente.
- **Fonte:** NVIDIA KB 5157 ("flickering/stuttering — disable MPO") e relatos equivalentes no suporte da AMD; a própria Microsoft usou esse valor de teste.

---

## Sobre otimizações específicas de NVIDIA/AMD

O que tem impacto real por fabricante (NVIDIA Reflex, "prefer maximum performance", Radeon Anti-Lag, sharpening) vive no **perfil do driver**, não no registro do Windows — e será exposto via perfis por jogo (Fase 4) ou instruções de modo manual, nunca via hack de registro não documentado. GPU integrada se beneficia principalmente de: plano de energia, VisualFX e GameDVR — que já estão no catálogo.

---

## Excluídos de propósito

- Desativar serviços essenciais do Windows (SysMain, Defender, etc.) — quebra PC, viola a regra 4.
- "Limpeza de RAM" / ISLC-like — placebo na maioria dos casos, viola a regra de honestidade.
- Undervolt/overclock — nunca em um clique (regra 5); entra só em modo manual/avançado no futuro.
- ULPS off (`EnableUlps=0`, AMD) — mexe em chave de classe do driver, é resetado a cada update de driver e o benefício é restrito a CrossFire; risco > ganho.
- `TdrDelay`/`TdrLevel` — não é otimização: só mascara crash de driver e piora o diagnóstico.
- Tweaks via nvidiaProfileInspector — exige baixar binário de terceiro e escreve no banco DRS sem API documentada; fora do produto até existir caminho suportado.
