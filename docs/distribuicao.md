# Distribuição — plano contra antivírus e SmartScreen

O maior risco de o produto "não funcionar" na máquina do cliente não é bug: é o
Defender/SmartScreen bloqueando ou deletando o .exe. Um binário ps2exe sem assinatura,
que mexe no registro, é exatamente o perfil que os AVs caçam. Este é o plano, em ordem.

## 1. Certificado de code signing (regra 7 — obrigatório para vender)

| Tipo | Efeito | Custo aprox. |
|------|--------|--------------|
| **OV** (Organization Validation) | Assina o .exe; SmartScreen ainda avisa até o binário construir reputação (semanas/milhares de downloads) | US$ 100–250/ano (Certum, Sectigo) |
| **EV** (Extended Validation) | Reputação SmartScreen imediata — sem tela azul de aviso | US$ 250–400/ano + token físico/HSM |

- Para pessoa física no Brasil, o caminho mais barato é o **Certum Open Source /
  Standard Code Signing** (aceita CPF/documentos pessoais).
- Como usar no build: instalar o certificado em `Cert:\CurrentUser\My` e definir
  `OPT_CODESIGN_THUMBPRINT` antes de rodar `build.ps1` — a assinatura + timestamp
  são automáticos, e o build falha se a assinatura não validar.

## 2. Falso positivo no Defender

Mesmo assinado, submeter o binário para análise ANTES de distribuir:

- **Microsoft (Defender/SmartScreen):** https://www.microsoft.com/en-us/wdsi/filesubmission
  — submeter como desenvolvedor ("software developer") com conta Microsoft. Resposta típica em 24–72h.
- **VirusTotal:** rodar o .exe e tratar QUALQUER detecção antes de mandar para cliente.
- Repetir a cada release (o hash muda, a reputação parcialmente também).

## 3. Publicar o hash

`build.ps1` gera `Optimizer.exe.sha256.txt`. Publicar o hash na página de venda/entrega
para o cliente conferir a integridade — e para o suporte confirmar que o arquivo do
cliente não foi corrompido/adulterado.

## 4. Por que a Fase 3 (.NET) resolve isso de vez

ps2exe embute um host PowerShell num stub genérico — os AVs conhecem o stub e
desconfiam por padrão (dezenas de FPs históricos). Um .exe .NET 8 compilado de verdade,
assinado, tem taxa de FP drasticamente menor. **Se a validação com usuários mostrar
que AV é dor recorrente, antecipar a Fase 3 em vez de brigar com o ps2exe.**

## 5. O que NUNCA fazer

- Ofuscar/compactar o binário para "escapar" do AV — isso AUMENTA a detecção e,
  pior, é técnica de malware. Viola a regra 6 (transparência total).
- Pedir para o cliente desativar o Defender/adicionar exclusão global. No máximo,
  instruir exclusão do arquivo específico ENQUANTO o certificado não chega, com o
  hash publicado para conferência.
