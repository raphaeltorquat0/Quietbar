# ``MDRKit``

Encode and decode the Sony MDR v2 protocol, with no Bluetooth or UI dependency.

## Overview

MDRKit is the pure protocol layer of [Quietbar](https://github.com/raphaeltorquat0/Quietbar). It turns bytes into frames, frames into typed messages, and messages back into bytes. It does no I/O: you supply the transport through ``MDRChannel`` or feed bytes to ``MDRFrameParser`` yourself.

MDRKit covers MDR v2 only. The WH-1000XM4, WH-1000XM3 and older models use MDR v1, which it doesn't implement yet.

MDRKit is an independent project, not affiliated with or endorsed by Sony. Product names belong to their respective owners.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ProtocolOverview>

### Frames

- ``MDRFrame``
- ``MDRFrameParser``
- ``MDRFrameError``
- ``MDRDataType``
- ``MDRTable``

### Messages

- ``MDRMessage``
- ``MDRCommand``
- ``MDRVerb``

### Transport

- ``MDRChannel``
