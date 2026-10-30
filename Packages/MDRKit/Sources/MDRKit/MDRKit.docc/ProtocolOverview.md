# MDR v2 Protocol Overview

How a Sony headphone exchanges commands and state over Bluetooth.

## Transport

MDR v2 runs over Bluetooth Classic RFCOMM. Find the channel through the SDP record of service UUID `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`.

## Framing

Every message uses the same envelope:

```
0x3E | ESCAPE( type:u8 | seq:u8 | len:u32be | payload | checksum:u8 ) | 0x3C
```

- `len` is the payload size before escaping.
- `checksum` is the sum modulo 256 of `type`, `seq`, the four `len` bytes and the payload, before escaping.
- Everything between the markers is escaped, so `0x3C` and `0x3E` never appear inside a frame:

| Byte | Escaped as |
|---|---|
| `0x3C` | `0x3D 0x2C` |
| `0x3D` | `0x3D 0x2D` |
| `0x3E` | `0x3D 0x2E` |

## Frame types

| Value | Name | Use |
|---|---|---|
| `0x01` | ACK | Empty confirmation |
| `0x0C` | DATA_MDR | Table 1, which holds almost every command |
| `0x0E` | DATA_MDR_NO2 | Table 2 |

## Sequence numbers

`seq` alternates between 0 and 1. A received data frame with `seq = s` is answered by an ACK with `seq = 1 - s`. After sending with `seq = s`, wait for an ACK with `seq = 1 - s`, then use `1 - s` for the next command. Only one command may be in flight.

## Payload

A payload is a command byte followed by a body. The body usually starts with an inquired type, which selects its layout.

The high nibble of the command byte is the group, and the low nibble is the verb:

| Low nibble | Verb |
|---|---|
| `0` / `1` | GET / RET capability |
| `2` / `3` / `4` / `5` | GET / RET / SET / NTFY status |
| `6` / `7` / `8` / `9` | GET / RET / SET / NTFY param |

| High nibble | Table 1 group |
|---|---|
| `0x1_` | COMMON |
| `0x2_` | POWER |
| `0x5_` | EQEBB |
| `0x6_` | NCASM |
| `0x9_` | ALERT |
| `0xA_` | PLAY |
| `0xD_` | GENERAL_SETTING |
| `0xE_` | AUDIO |
| `0xF_` | SYSTEM |

`0x0_` holds the connection commands, which have their own layout. For example, in the capture from <doc:GettingStarted>, `0x67` is RET param in group NCASM, and `0x17` is the inquired type.

## Booleans

Booleans in MDR v2 are inverted: `0x00` means on or enabled, and `0x01` means off or disabled. Noise control fields are an exception, so rely on ``MDRMessage/decode(_:table:)`` rather than on this rule alone.

## Capabilities

A headphone lists what it supports in the support functions response (`06 00`), on Table 1 and Table 2. Query this list and adapt to it rather than assuming features from the model name.

## Full reference

[`docs/PROTOCOL.md`](https://github.com/raphaeltorquat0/Quietbar/blob/main/docs/PROTOCOL.md) documents each command, in Portuguese, with the source of every item.
