# Protocolo Sony MDR v2 — referência consolidada para o WH-1000XM5

Documento de trabalho do SonyCtl. Cada item cita a origem:

| Sigla | Referência | Commit estudado | Licença |
|---|---|---|---|
| **[M]** | `github.com/mos9527/SonyHeadphonesClient` (`libmdr`) | `68dfced0` (2026-10-27) | MIT |
| **[L]** | `github.com/vyomjain6904/sony-headphones-linux` (`docs/COMPATIBILITY.md`, backend) | `f6144b3c` (2026-08-21) | MIT |
| **[G]** | Gadgetbridge (`SonyProtocolImplV2`, testes) | `86703c80` (2026-10-27) | AGPL — **só leitura**, nenhum código copiado |
| **[C]** | Capturas reais em `[M] tests/WF-1000XM5-6.1.0/` (RX de um WF-1000XM5, MDR v2) | idem [M] | MIT |

Regra de desempate: quando divergem, vale o que tem evidência de teste em XM5. [L] testou
WH-1000XM5 fw 2.5.1 sobre o `libmdr` de [M]; [C] é tráfego real de MDR v2 (mesma família de protocolo).

## 1. Transporte

- Bluetooth Classic, RFCOMM. Nada de BLE. [M][L]
- UUID do serviço SPP Sony MDR v2: **`956C7B26-D49A-4BA8-B03F-B17D393CB6E2`**. [M `mdr-c/Base.h:49`][L `mdr_backend.cpp:29`]
- UUID legado (v1, XM4 e anteriores): `96CC203E-5068-46AD-B32D-E316F5E069BA`. Não usado no v1 do SonyCtl. [M][L]
- O canal RFCOMM vem do registro SDP desse UUID (`getRFCOMMChannelID`). [M `ConnectionMacOS.mm`]
- Tamanho máximo de pacote: 2048 bytes; escrita limitada ao MTU do canal. [M `Command.hpp`]

## 2. Framing

```
0x3E | ESCAPE( type:u8 | seq:u8 | len:u32be | payload[len] | checksum:u8 ) | 0x3C
```

- `checksum` = soma (mod 256) de `type`, `seq`, os 4 bytes de `len` e o payload, **antes** do escape. [M `Command.cpp`]
- `len` é o tamanho do payload **sem** escape. [M]
- Escape (aplicado a tudo entre os marcadores, inclusive checksum): [M `Command.hpp`]

  | Byte original | Vira |
  |---|---|
  | `0x3C` `<` | `0x3D 0x2C` |
  | `0x3D` `=` | `0x3D 0x2D` |
  | `0x3E` `>` | `0x3D 0x2E` |

  Como `0x3C`/`0x3E` nunca aparecem dentro do frame, o fim de frame é o primeiro `0x3C` depois de um `0x3E`.

### Tipos de dado (`type`)

| Valor | Nome | Uso |
|---|---|---|
| `0x00` | DATA | — |
| `0x01` | ACK | confirmação, payload vazio |
| `0x0C` | DATA_MDR | **Tabela 1** (quase todos os comandos) |
| `0x0E` | DATA_MDR_NO2 | **Tabela 2** (periféricos, voice guidance, safe listening) |

Fonte: [M `Protocol.hpp:37`]. Demais valores (`0x02`, `0x09`, `0x0A`, `0x0D`, `0x10+`) não são usados pelo XM5 nas referências.

### Sequência e ACK

- `seq` alterna entre 0 e 1. [M `Headphones.cpp`]
- Ao receber DATA_MDR/DATA_MDR_NO2 com `seq = s`, responde-se ACK com `seq = 1 - s`. [M `SendACK`][C: o fone manda ACK `seq 01` em resposta ao nosso frame `seq 00`]
- Ao enviar com `seq = s`, espera-se ACK com `seq = 1 - s`; recebido, o próximo envio usa `1 - s`. ACK com seq inesperado é descartado (ACK atrasado). [M `HandleAck`]
- Vetor real de ACK: `3E 01 01 00 00 00 00 02 3C` (type 1, seq 1, len 0, checksum 2). [C]
- Um comando por vez: só se envia o próximo depois do ACK do anterior. [M `SendCommandACK`]
- Timeout/retry: [M] usa timeout padrão por awaiter; o SonyCtl usa 1 s × 3 tentativas com backoff (ver `DECISIONS.md`).

## 3. Payload (Tabela 1 e 2)

Payload = `cmd:u8` + corpo. O corpo começa quase sempre por um **inquired type** (`u8`), que escolhe o layout.

### 3.1 Padrão dos códigos de comando

Cada grupo ocupa um nibble alto; o nibble baixo é o verbo. [M `ProtocolV2T1.hpp:376`]

| Nibble baixo | Verbo |
|---|---|
| `0` / `1` | GET / RET capability |
| `2` / `3` / `4` / `5` | GET / RET / SET / NTFY status |
| `6` / `7` / `8` / `9` | GET / RET / SET / NTFY param |
| `A` / `B` / `C` / `D` | GET / RET / SET / NTFY ext param (só System) |

| Nibble alto | Grupo (Tabela 1) | Grupo (Tabela 2) |
|---|---|---|
| `0x0_` | CONNECT (layout próprio, ver 3.2) | CONNECT (só `0x06/0x07`) |
| `0x1_` | COMMON | — |
| `0x2_` | POWER | POWER |
| `0x3_` | UPDT (firmware — fora de escopo) | PERI |
| `0x5_` | EQEBB | SAFE_LISTENING |
| `0x6_` | NCASM | LEA |
| `0x9_` | ALERT | — |
| `0xA_` | PLAY | — |
| `0xD_` | GENERAL_SETTING | — |
| `0xE_` | AUDIO | — |
| `0xF_` | SYSTEM | SYSTEM |

O layout de RET, NTFY e SET de um mesmo inquired type é idêntico, salvo onde indicado. [M: structs `*Ret*`/`*Ntfy*`/`*Set*` têm os mesmos campos]

### 3.2 Conexão / identidade (Tabela 1)

| Comando | Bytes | Resposta | Fonte |
|---|---|---|---|
| Protocol info | `00 00` | `01 00 ver:u32be t1:u8 t2:u8` (`00` = suporta) | [M][C `…0100 03003018 00 00`] |
| Capability info | `02 00` | `03 00 counter:u8 str(uniqueId)` — no XM5/WF-XM5 o uniqueId é o MAC em texto | [M][C] |
| Device info | `04 tt` (`01` modelo, `02` fw, `03` série/cor) | `05 01 str` / `05 02 str` / `05 03 série:u8 cor:u8` | [M][C `05 02 05 "6.1.0"`] |
| Support functions | `06 00` (T1 **e** T2) | `07 00 n:u8 (func:u8 prio:u8)×n` | [M][C] |

`str` = `len:u8` + bytes UTF-8. Lista = `count:u8` + elementos. [M `Protocol.hpp` `MDRPrefixedString`/`MDRPodArray`]

**Atenção (V2):** `EnableDisable.ENABLE = 0x00`, `DISABLE = 0x01`; `OnOff.ON = 0x00`, `OFF = 0x01`. Invertido em relação ao intuitivo. [M `ProtocolV2.hpp`][G comenta "this is reversed on V2"]

### 3.3 Funções anunciadas usadas pelo SonyCtl (Tabela 1)

| Código | Função | Habilita |
|---|---|---|
| `0x12` | CODEC_INDICATOR | leitura de codec |
| `0x20` / `0x28` | BATTERY_LEVEL_INDICATOR / BATTERY_LEVEL_WITH_THRESHOLD | bateria (tipo `0x00` / `0x08`) |
| `0x23` | POWER_OFF | desligar |
| `0x24` / `0x25` | AUTO_POWER_OFF / …WITH_WEARING_DETECTION | auto power off (tipo `0x04` / `0x05`) |
| `0x50` `0x52` `0x53` `0x57` | PRESET_EQ e variantes | equalizador |
| `0x67` | AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT | NC/ASM tipo `0x22` |
| `0x68` | MODE_NC_ASM…DUAL_AUTO… | NC/ASM tipo `0x15` |
| `0x69` | AMBIENT_SOUND_CONTROL_MODE_SELECT | função do botão NC/AMB (tipo `0x30`) |
| `0x6B` | MODE_NC_ASM_NOISE_CANCELLING_DUAL_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT | NC/ASM tipo `0x17` |
| `0x6D` | …NOISE_ADAPTATION | NC/ASM tipo `0x19` |
| `0x90` | FIXED_MESSAGE | alertas de confirmação |
| `0xA1`–`0xA4` | PLAYBACK_CONTROLLER* | play/pause/faixa/volume |
| `0xD1`–`0xD4` | GENERAL_SETTING_1..4 | ajustes genéricos (multiponto, touch, sidetone) |
| `0xE1` | CONNECTION_MODE_SOUND_QUALITY_CONNECTION_QUALITY | prioridade de conexão |
| `0xE2` | UPSCALING_AUTO_OFF | DSEE |
| `0xF1` | PLAYBACK_CONTROL_BY_WEARING… | pausa ao tirar o fone |
| `0xF3` / `0xFE` | ASSIGNABLE_SETTING / …WITH_LIMITATION | botão personalizável |
| `0xFC` | SMART_TALKING_MODE_TYPE2 | Speak-to-Chat |

Fonte: [M `ProtocolV2.hpp` `t1::FunctionType`; mapeamento função→inquired type em `HeadphonesV2.cpp` `RequestInitV2`].

### 3.4 Tabela de comandos por funcionalidade (Tabela 1)

Notação: `GET` = bytes enviados; `RET/NTFY/SET` = layout do corpo após `cmd`.

| Funcionalidade | GET | Layout RET / NTFY / SET | Fonte |
|---|---|---|---|
| **Codec** | `12 02` | `13|15 02 codec` — `01` SBC, `02` AAC, `10` LDAC, `20` aptX, `21` aptX HD, `30` LC3, `00` indefinido | [M][C `13 02 02` = AAC] |
| **Bateria** | `22 00` (ou `22 08`) | `23|25 00 nível:u8 carga:u8` · `23|25 08 nível carga limiar` · carga: `00` não, `01` carregando, `03` carregado | [M][G] |
| **Desligar** | — | SET `24 03 01` | [M `PowerSetStatusPowerOff`] |
| **Auto power off** | `26 04` / `26 05` | `27|28|29 tt atual:u8 último:u8` · `00` 5 min, `01` 30, `02` 60, `03` 180, `04` 15, `10` ao tirar, `11` desativado. SET usa `último = 00` [M] (Gadgetbridge usa pares fixos para XM5 [G]) | [M][G][C `27 05 10 00`] |
| Auto power off — opções | `20 04` / `20 05` | `21 tt n:u8 elem×n` | [M] |
| **NC / Ambiente / Off** | `66 17` (ou `15`/`19`/`22`) | tipos `15`/`17`: `67|68|69 tt mudança:u8 efeito:u8 modo:u8 voz:u8 nível:u8` — `mudança` `00` arrastando / `01` final; `efeito` `00` off / `01` on; `modo` `00` NC / `01` ambiente; `voz` `00` normal / `01` Focus on Voice; `nível` 0–20. Tipo `19` acrescenta `autoASM:u8 sensibilidade:u8`. Tipo `22` (só ambiente): `tt mudança efeito voz nível` | [M][G][C `67 17 01 00 01 00 14`] |
| **Botão NC/AMB** | `66 30` | `67|68|69 30 função` — `01` NC↔AMB↔Off, `02` NC↔AMB, `03` NC↔Off, `04` AMB↔Off | [M] |
| **EQ disponível** | `52 00` | `53|55 00 enable` | [M][C] |
| **EQ (preset + bandas)** | `56 00` | `57|58|59 00 preset:u8 n:u8 passo×n` · com 6 bandas: `[Clear Bass, 400, 1k, 2.5k, 6.3k, 16k]`, valor = dB + 10 (−10…+10). Com 10 bandas, offset 6. SET só com preset envia `n = 0` | [M `HandleEqEbbParamT1`][C `57 00 A0 06 14 0B 0A 0D 09 0C`][G `58 00 10 00`] |
| EQ — presets | `50 00 idioma` | `51 00 bandas:u8 passos:u8 n:u8 (id:u8 str(nome))×n` | [M] |
| IDs de preset | — | `00` Off, `10` Bright, `11` Excited, `12` Mellow, `13` Relaxed, `14` Vocal, `15` Treble Boost, `16` Bass Boost, `17` Speech, `A0` Custom, `A1`–`A5` User 1–5 | [M `EqPresetId`][G] |
| **DSEE disponível** | `E2 01` | `E3|E5 01 enable` | [M][C] |
| **DSEE on/off** | `E6 01` | `E7|E8|E9 01 v` — `00` off, `01` auto (on) | [M][C][G] |
| DSEE — tipo | `E0 01` | `E1 01 tipo` (`00` HX, `01` DSEE, `02` HX AI, `03` Extreme/Ultimate) | [M][C] |
| **Prioridade de conexão** | `E6 00` | `E7|E8|E9 00 v` — `00` qualidade de som, `01` estabilidade | [M][L patch][G] |
| **Speak-to-Chat** | `F6 0C` | `F7|F8|F9 0C on:u8 preview:u8` (`00` on, `01` off) | [M][C `F7 0C 01 01`] |
| **STC — sensibilidade e tempo** | `FA 0C` | `FB|FC|FD 0C sens:u8 tempo:u8` — sens `00` auto, `01` alta, `02` baixa; tempo `00` curto, `01` médio, `02` longo, `03` não voltar sozinho (durações em segundos não constam nas referências) | [M][C `FB 0C 00 00`][G] |
| **Pausa ao tirar** | `F6 01` | `F7|F8|F9 01 v` (`00` on) | [M][C `F7 01 00`] |
| **Botão personalizável** | `F6 03` (ou `F6 0E`) | `F7|F8|F9 tt n:u8 preset×n` — `00` controle de som ambiente, `20` playback, `35` ambiente + quick access, `36` quick access, `FF` sem função | [M][C `F7 03 02 35 20`] |
| Botão — capacidades | `F0 03` | estrutura aninhada (ver `[M] ProtocolV2T1CustomSerialization.cpp`); não usada no v1 | [M] |
| **General settings** | `D0 Dn idioma`, `D6 Dn` | cap: `D1 Dn tipo:u8 formato:u8 str(assunto) str(resumo)` · param: `D7|D8|D9 Dn tipo:u8 v` (`00` on, `01` off) · assuntos conhecidos: `MULTIPOINT_SETTING`, `TOUCH_PANEL_SETTING`, `SIDETONE_SETTING` | [M `Client.cpp:2021`][C] |
| **Volume** | `A6 20` | `A7|A8|A9 20 v:u8` (XM5: 0–30) | [M][C `A7 20 0C`][L: raw 6 = 20%] |
| **Playback — estado** | `A2 01` | `A3|A5 01 enable st:u8 musicaOuChamada:u8` — st `01` play, `02` pause, `03` stop | [M][C] |
| **Playback — controle** | — | SET `A4 01 00 ctrl` — `01` pause, `02` próxima, `03` anterior, `07` play | [M] |
| **Alertas** | — | SET `94 00 00` habilita; NTFY `99 00 msg:u8 ação:u8`; resposta SET `98 00 msg:u8 ação:u8` (`01` positivo) | [M][G `98 00 06 01` ao alternar multiponto] |

### 3.5 Tabela 2

| Funcionalidade | Bytes | Fonte |
|---|---|---|
| Support functions | GET `06 00` → `07 00 n (func prio)×n` | [M][C] |

Periféricos (lista de pareados, troca de fonte), voice guidance e safe listening ficam fora do v1.

## 4. Sequência de inicialização

Mesma ordem de `RequestInitV2` [M]:

1. `00 00` → aguarda `01` (protocol info). Sem Tabela 1 → aborta.
2. `02 00`, `04 02`, `04 01`, `04 03`.
3. `06 00` na T1 → aguarda `07`; se a T2 existir, `06 00` na T2 → aguarda `07`.
4. Se `FIXED_MESSAGE` (`0x90`): `94 00 00` para receber alertas.
5. GETs de estado conforme as funções anunciadas (seção 3.4).

## 5. Divergências entre as referências

| Ponto | [M] | [G] | Escolha do SonyCtl |
|---|---|---|---|
| Inquired type de NC/ASM do WH-1000XM5 | escolhe pela função anunciada (`0x6B` → `0x17`) | fixo `0x15` (ou `0x17` com "AmbientSoundControl2") | pela função anunciada; perfil XM5 de fallback usa `0x17` (evidência de teste em XM5 por [L], que usa [M]) |
| Auto power off SET | `último = 00` | pares fixos (`01 01`, `02 02`…) | [M], que tem evidência em hardware via [L]; marcado para conferência no `HARDWARE_TEST.md` |
| Multiponto | General Setting com assunto `MULTIPOINT_SETTING` | GS + confirmação `98 00 06 01` | GS genérico + resposta automática positiva ao alerta que o próprio usuário disparou |
