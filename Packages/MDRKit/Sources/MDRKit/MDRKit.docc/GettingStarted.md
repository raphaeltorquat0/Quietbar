# Getting Started

Decode a frame from a headphone and build a command to send back.

## Add the package

Add the repository to your `Package.swift` and depend on the `MDRKit` product:

```swift
dependencies: [
    .package(url: "https://github.com/raphaeltorquat0/Quietbar", from: "1.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "MDRKit", package: "Quietbar"),
    ]),
]
```

## Decode a frame

This frame was captured from a WF-1000XM5 reporting its noise control state:

```swift
import MDRKit

let bytes: [UInt8] = [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x07,
                      0x67, 0x17, 0x01, 0x00, 0x01, 0x00, 0x14, 0xA8, 0x3C]

let frame = try MDRFrame(decoding: bytes)
if case let (.ret, .noiseControl(state))? = MDRMessage.decode(frame.payload) {
    print(state.soundMode, state.ambientLevel) // off 20
}
```

``MDRMessage/decode(_:table:)`` returns `nil` for payloads it doesn't know. Log those instead of treating them as errors, because models send messages this package doesn't model.

## Build a command

Describe the state you want, then wrap it in a frame:

```swift
let target = NoiseControl(enabled: true, ambientMode: true, ambientLevel: 10)
let command = MDRMessage.noiseControl(target).command(.set)
let outgoing = MDRFrame(type: command.table.dataType, seq: 0, payload: command.payload)

let wire = outgoing.encoded() // write these bytes to the RFCOMM channel
```

Send one command at a time, and wait for the ACK before sending the next. The sequence number rules are in <doc:ProtocolOverview>.

## Read from a stream

RFCOMM reads can split or join frames. ``MDRFrameParser`` buffers them and returns each complete frame:

```swift
var parser = MDRFrameParser()

for result in parser.push(received) {
    switch result {
    case .success(let frame): handle(frame)
    case .failure(let error): print("dropped frame:", error)
    }
}
```

Reply to each `DATA_MDR` frame with ``MDRFrame/ack(for:)``.
