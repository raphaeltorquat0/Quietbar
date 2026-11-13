# Protocolo JBL "Protocol4": referência para o Live Beam 4

Documento de trabalho do Quietbar. Cada item cita a origem:

| Sigla | Referência | Versão | Licença |
|---|---|---|---|
| **[P]** | `github.com/NeoHBz/JBLProtocol4`, `notes/protocol.md` (medido num Tune 780NC) | `main` em 2026-11-12 | MIT |
| **[A]** | App Android "JBL Headphones" (`jbl.stc.com`) 5.38.2, versionCode 260928180 | lido em 2026-11-12 | proprietário: **só como fato**, nenhum código copiado |

[A] foi lido estaticamente (jadx e apktool), sem executar o app. Aqui entram só IDs, layouts e a ordem das
mensagens, que são o necessário para interoperar. Os nomes de classe citados servem para achar o trecho
numa nova versão do app. O APK veio da APKPure; o certificado do APK principal e dos splits é o mesmo
(SHA-256 `DE:7F:E9:DD…:A5:3D`). Não foi conferido contra a Play Store.

Conferido num Live Beam 4 em 2026-11-13 (ProductID `7921`, firmware `0x000c` = `1a0c0a`): conexão no modo 3,
bateria dos fones, leitura e troca de ANC, Ambient Aware e desligado. O que ainda vem só de [A] segue marcado
**(sem captura)**.

## 1. Identificação do modelo

Em [A] `assets/product_list.json`, o Live Beam 4:

| Campo | Valor | Leitura |
|---|---|---|
| `appCmdProtocol` | `4` | Protocol4, o mesmo do 780NC em [P] |
| `connectType` | `BLE` | controle por GATT |
| `bleSecurityMode` | `3` | o 780NC é `2`: muda o começo da conexão (§3) |
| `cmdCtrlList` | `LiveTws4Control` | o mesmo do Live Buds 4 (PID `217b`) |
| `pidS` | `2179` | PID dos fones; `casePid` `217a` é o estojo |
| `platform` | `Bes` | chip BES |

A config de tela (`assets/config/dash4/jbl_live_beam_4.json`) lista ANC, Ambient Aware e TalkThru, ANC
adaptativo, Speak-to-Chat, EQ, áudio espacial e o estojo com tela.

## 2. Transporte

Serviço `65786365-6c70-6f69-6e74-2e636f6d0000` ("excelpoint.com") [P][A `Constants`]:

| Característica | Papel |
|---|---|
| `…0001` | notify, do fone para o host |
| `…0002` | write, do host para o fone |
| `…0003` | "raw", write + notify. Só nos modos de segurança 1 e 3 |

No Mac (macOS 27), o JBL aparece duas vezes em `IOBluetoothDevice.pairedDevices()`, uma por transporte, e
`isConnected()` responde `false` com o fone tocando. O Core Audio tem a saída `38-D5-18-CE-58-59:output`, e o
Quietbar usa isso como segundo sinal de conexão (`BluetoothDevices.audioAddresses`).

O Live Beam 4 anuncia em LE só o nome (`JBL Live Beam 4`), sem o UUID do serviço nem dados de fabricante: o
scan não pode filtrar pelo serviço.

Frame little-endian `00 dd | cmd u16 | count u8 | index u8 | len u16 | payload`. GET `0x0001`, SET `0x0002`,
NOTIFY `0x0003`. TLV `tag u16 | len u16 | valor`; resposta e NOTIFY começam com status `0000` [P].

## 3. Conexão no modo de segurança 3

Em [A] `BleDevice`:

1. Descobre os serviços e pede o MTU.
2. Liga o notify de `…0003`.
3. Escreve por `…0003` um SET do tag `0x0007` (HostNameCRC) com 2 bytes: o CRC do nome Bluetooth do host,
   em little-endian. Exemplo, com o nome `123456789`: `00dd 0200 0100 0600 0700 0200 3dbb`.
4. Espera até 1 s pelo eco, um NOTIFY de 16 bytes `00dd 0300 0100 0800 0000 0700 0200 <crc LE>`. **Segue
   mesmo sem eco.** No Live Beam 4 o eco chega em ~60 ms, logo depois da resposta do SET.
5. Liga o notify de `…0001` e passa aos comandos normais por `…0002`.

O CRC é CRC-16/ARC (polinômio refletido `0xA001`, início `0`), sobre os primeiros 50 bytes do nome em
UTF-8. A tabela do app começa com `0000 C0C1 C181 0140` (`com.harman.utils.c`). O nome é o do adaptador
Bluetooth (no Android, `BluetoothAdapter.getName()`; no Mac, o nome do Mac nos Ajustes de Bluetooth).

O fone anuncia, nos dados de fabricante, o CRC dos hosts com que está pareado. O app só segue com um fone
cujo anúncio traz o CRC do próprio nome (`qi.n`). Isso explica o que [P] viu no 780NC: um Mac que não estava
pareado não recebia resposta, e voltou a receber depois de parear de novo.

No modo 2 (780NC), o app espera um NOTIFY de `PairingStatus` (`0x002e` = `01`) antes de seguir [A].

## 4. Tags usadas pelo Quietbar

Tabela completa em [A] `DeviceInfoFeature5`; aqui só o que o app usa.

| Tag | Nome em [A] | Acesso | Valor |
|---|---|---|---|
| `0x0004` | ProductID | r | 2 bytes LE (`7921` = Live Beam 4) |
| `0x0007` | HostNameCRC | rw | 2 bytes LE (§3) |
| `0x000d` | LeftDeviceBatteryStatus | r | bit 7 = carregando, bits 0-6 = % |
| `0x000e` | RightDeviceBatteryStatus | r | idem |
| `0x0018` | ANC | rw | bit 7 = ligado, bits 0-6 = nível |
| `0x0019` | AA (Ambient Aware) | rw | idem |
| `0x001a` | TT (TalkThru) | rw | idem |
| `0x002f` | HostType | r | o app manda SET `01` na conexão [P][A `LiveTws4Control`] |
| `0x0049` | AmbientSoundControl | rw | bit 7 = grupo ligado; o app manda nível `7f`. Lido: `ff` ligado, `7f` desligado |
| `0x1f03` | CaseBatteryStatus | r | como as baterias dos fones. Com os fones fora do estojo veio `00` |

Proibidas, e fora da allowlist do `JBL.swift`: `0x000f` e `0x00ff` (reset), `0x0011` (desligar),
`0x0101`–`0x0104` (OTA), `0x0ba0` (LE Audio, reinicia e pede novo pareamento), `0x0ba5` (modo de pareamento),
e as de autenticação, `0x3e`, `0x4a`, `0x4b`, `0x53` e `0x54` [P][A].

As tags de autenticação são usadas por `jbl.stc.com.auth.advanced.AuthConfigMgr` e `com.jbl.counterfeit`:
é o app conferindo se o fone é original. O fone não exige isso para aceitar comandos [A, inferência: o 780NC
respondeu em [P] sem nenhuma delas].

## 5. Modo de som

**Genérico** (`General4Control`, 780NC): um SET com um tag. `ff` liga o modo e `7f` no `0x0018` desliga os
três [P][A].

**Live Beam 4** (`LiveTws4Control.setAncSetting`): um SET com dois TLVs, primeiro `0x0049`, depois o tag do
modo, sempre com o bit 7 ligado. Os quatro conferidos no fone:

| Modo | Payload |
|---|---|
| ANC | `4900 0100 ff` `1800 0100 ff` |
| Ambient Aware | `4900 0100 ff` `1900 0100 <80 \| nível AA>` |
| TalkThru | `4900 0100 ff` `1a00 0100 ff` |
| Desligado | `4900 0100 7f` + o tag do último modo, ligado |

O app manda o nível de ANC e de TalkThru como `-1`, que vira `7f`. O nível de Ambient Aware é o último lido
do fone. Na leitura, o modo é o tag com o bit 7 ligado, e o `0x0049`, se vier, decide o liga/desliga (`gn.l0`).

Nível de Ambient Aware, medido com `mdr-cli jbl-set 49=ff 19=8N`: o fone guarda de `0x00` a `0x20` e, acima
disso, responde OK e fica em `0x20`. De fábrica vem `07`. **Mas o som não muda:** alternando `0x00` e `0x20` a
cada 4 s no modo Ambient Aware, nada se ouve (conferido de ouvido em 2026-11-13). O Quietbar não escreve o nível
e esconde o controle para o JBL. O ajuste de verdade, se existir, está em outro tag.

TalkThru ligado é lido como `0x1a` = `80`, com `0x18` e `0x19` sem o bit 7 e `0x49` = `ff`.

**Botão do fone.** Ao trocar o modo pelo toque, o fone manda sozinho um NOTIFY com o grupo inteiro:
`49 ff`, `18 07`, `19 87`, `1a 00` (ANC → Ambient Aware), seguidos de `0x0c80` = `00`, `0x0c81` = `32` e
`0x0c82` = `01`, que ainda não têm significado conhecido. O Quietbar converte esse NOTIFY e o painel acompanha.

## 6. Em aberto

- ~~Estado desligado~~: medido. O fone mantém o tag do último modo ligado (`0x18` = `87`) e põe o `0x0049` em
  `7f`. Por isso a leitura inicial pede o `0x0049` junto com os tags de modo.
- Os tags `0x0c80`–`0x0c82`, que vêm junto do NOTIFY do botão (`0x0c81` = `0x32`, 50, pode ser um nível).
- Onde fica o nível audível do som ambiente, se o Live Beam 4 tiver um.
- `0x1f03` com os fones no estojo: fora dele veio `00`; o painel esconde o estojo nesse caso.
- O formato do firmware (`0x000c`, 3 bytes).
- EQ (`0x0e01`/`0x0e02`): blob calculado numa biblioteca nativa.
