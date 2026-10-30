# MDRKit

Swift package that encodes and decodes the Sony MDR v2 protocol. It's the protocol layer of [Quietbar](https://github.com/raphaeltorquat0/Quietbar), and it has no Bluetooth or UI dependency.

Independent project, not affiliated with or endorsed by Sony. Product names belong to their respective owners.

## Install

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

Requires Swift 6 and macOS 14 or later. Only the products you depend on are built, so the app and the CLI don't enter your project.

## Example

```swift
import MDRKit

// Decode a frame captured from a WF-1000XM5.
let bytes: [UInt8] = [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x07,
                      0x67, 0x17, 0x01, 0x00, 0x01, 0x00, 0x14, 0xA8, 0x3C]

let frame = try MDRFrame(decoding: bytes)
if case let (.ret, .noiseControl(state))? = MDRMessage.decode(frame.payload) {
    print(state.soundMode, state.ambientLevel) // off 20
}

// Build a command that switches to ambient sound.
let target = NoiseControl(enabled: true, ambientMode: true, ambientLevel: 10)
let command = MDRMessage.noiseControl(target).command(.set)
let wire = MDRFrame(type: command.table.dataType, seq: 0, payload: command.payload).encoded()
```

MDRKit does no I/O: write `wire` to the RFCOMM channel yourself, or use it with the `MDRTransport` and `MDRSession` products from the same package.

## Scope

MDRKit covers MDR v2. Models such as the WH-1000XM4 and WH-1000XM3 use MDR v1, which is on the roadmap.

The API is young and can change between minor versions.

## Documentation

- DocC catalog: [`Sources/MDRKit/MDRKit.docc`](Sources/MDRKit/MDRKit.docc). In Xcode, use **Product › Build Documentation**.
- Protocol reference, in Portuguese: [`docs/PROTOCOL.md`](../../docs/PROTOCOL.md).

## License

[MIT](../../LICENSE)
