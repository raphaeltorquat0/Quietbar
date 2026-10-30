# How a Mac app talks to Sony headphones

Sony's headphones have a companion app for phones, and that's where you change noise canceling, EQ and most other settings. I wanted the same controls in the macOS menu bar, so I built [Quietbar](https://github.com/raphaeltorquat0/Quietbar). This post covers how it works: opening the Bluetooth channel, the MDR v2 protocol, who owns the connection, how the app handles events it didn't ask for, how the tests work without headphones, and why the 3D model is generated in code.

None of the protocol work is original research. I studied [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) and [sony-headphones-linux](https://github.com/vyomjain6904/sony-headphones-linux), both MIT licensed, and used [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), which is AGPL, only as a reference for behavior. No code was copied from it. `docs/PROTOCOL.md` in the repository cites the source of each item, and where the references disagree, it records which one I followed and why.

## Opening a channel with IOBluetooth

The headphones expose a serial port profile over Bluetooth Classic. MDR v2 doesn't use BLE. The service is identified by the UUID `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`, and the RFCOMM channel number comes from that service's SDP record.

On macOS, this goes through IOBluetooth, an Objective-C framework built around delegates and the run loop. It predates Swift concurrency by many years, and a few things follow from that.

First, callbacks arrive on the main thread, and they only arrive if a run loop is running. The app has one, but a command line tool has to call `RunLoop.main.run()` or nothing ever happens.

Second, I use `openRFCOMMChannelAsync` and never the synchronous variant, which blocks the run loop thread that has to deliver the result.

Third, the rest of the code shouldn't know about any of this. So I defined a small protocol:

```swift
public protocol MDRChannel: AnyObject, Sendable {
    func open() async throws -> AsyncStream<[UInt8]>
    func write(_ bytes: [UInt8]) async throws
    func close() async
}
```

The real implementation is a `@MainActor` class that wraps the delegate callbacks. Each incoming block of data is yielded to an `AsyncStream`, and when the channel closes, the stream finishes. Everything above this line sees async functions and a stream of bytes, and that boundary is also what makes the code testable.

## Framing

MDR is a framed binary protocol. Every message has the same envelope:

```
0x3E | ESCAPE( type | seq | len (u32 big endian) | payload | checksum ) | 0x3C
```

The checksum is the sum of the bytes modulo 256, calculated before escaping. Escaping uses `0x3D` to protect the three special bytes, so `0x3C`, `0x3D` and `0x3E` become `0x3D 0x2C`, `0x3D 0x2D` and `0x3D 0x2E`.

This makes framing simple: the start and end markers can never appear inside a frame, so the end of a frame is the first `0x3C` after a `0x3E`.

The catch is that RFCOMM is a stream. One read can hold half a frame or three frames at once, so a decoder that works on a whole frame isn't enough. Quietbar has a small parser that buffers bytes and returns whatever is complete. A corrupt frame comes back as a failure and gets dropped, without taking the stream down.

## Commands and verbs

Inside the frame, the payload is a command byte followed by a body. The command byte is more regular than it first looks. The high nibble is the feature group, such as `0x6_` for noise control or `0x5_` for the equalizer. The low nibble is the verb:

| Low nibble | Meaning |
|---|---|
| `6` | GET param |
| `7` | RET param, the answer |
| `8` | SET param |
| `9` | NTFY param, an unprompted update |

So `0x66` asks for noise control state, `0x67` is the reply, `0x68` changes it and `0x69` reports a change you didn't ask for. The body usually starts with an inquired type, which picks the layout. RET, NTFY and SET of the same inquired type share one layout, so one decoder covers all three.

Each message has a case in a Swift enum, `MDRMessage`, with a function that encodes it and a static function that decodes it. Anything unknown decodes to `nil`, and the caller logs it. Headphones send plenty of messages the app doesn't model, and those can't be treated as errors.

There's one trap worth mentioning. In MDR v2, most booleans are inverted: `0x00` means on and `0x01` means off. Some fields don't follow that rule, so each one has to be checked.

## An actor owns the channel

MDR has one rule that shapes the whole session: only one command may be in flight. You send a frame with sequence number `s`, wait for an ACK with `1 - s`, and only then send the next one. If you receive a data frame, you owe the headphones an ACK as well.

Meanwhile, the UI, global shortcuts and automatic profiles can all ask for changes at any moment. That's a shared mutable state problem, and a Swift actor is a good fit. `MDRSession` is the only owner of the channel, the sequence number and the device state.

Writes go through a small FIFO queue held by the actor. Actors are reentrant, so awaiting an ACK would otherwise let a second command start in the middle of the first. `send` acquires the queue, writes the frame, and waits for the ACK with a one second timeout, retrying up to three times with backoff.

One detail matters here. The waiter for an ACK has to be registered before the write:

```swift
ackWaiter = AckWaiter(id: id, expected: 1 &- seq)
try await write(frame)
if await waitAck(id) {
    seq = 1 &- seq
    return
}
```

If you write first, the ACK can arrive during the suspension, before anyone is listening for it. `request`, which sends a command and waits for the matching reply, has the same rule for the same reason.

## Handling notifications

Most of the interesting traffic is unprompted. When you press the button on the headphones, take them off or a battery level changes, a notification arrives. So the session has a reader task that runs for the life of the connection and feeds each chunk through the parser. For each complete frame, it does this:

1. If it's an ACK with the expected sequence, resolve the pending send.
2. If it's data, send an ACK.
3. Decode the message, apply it to the state and publish a snapshot.
4. Resolve any request waiting for that message.

There's no separate path for replies and notifications. A RET to our GET and an NTFY from a button press go through the same code and update the same state.

It also leads to an important rule: the UI never assumes a command worked. A SET is followed by a read of the same value, and the state changes only when the headphones say so. If a setting doesn't apply, the toggle goes back to where it was, rather than showing something the device isn't doing.

The headphones also tell you what they can do. At connection, the app asks for the list of supported functions and builds its requests from that list, so the panel shows only what the device reports. This turned out to matter when I added other models: a set of earbuds with no noise canceling just doesn't get the sound mode module.

## Testing without headphones

Bluetooth code is painful to test by hand, and I don't own most of these models. So the tests have two layers.

The first is recorded traffic. `MDRKit` has no Bluetooth dependency, so its tests are plain functions over bytes. They use frames from real devices: my WH-1000XM5, plus WF-1000XM5 and LinkBuds Clip captures published with SonyHeadphonesClient. A test feeds a captured frame to the decoder and asserts on the result. The layout of earbud batteries, for example, was checked byte by byte against those captures.

The second is a fake headphone. Because `MDRSession` only knows about `MDRChannel`, the session tests use an in-memory implementation that answers like a device. That covers what's hard to reproduce on purpose: a lost ACK, a device that never answers, a device that disconnects, and commands issued at the same time.

Adding support for other models also raised a risk: changing how the app talks to the headphones I actually own. To guard against that, I ran the code from before the change and saved the exact sequence of commands it sends to a WH-1000XM5. A regression test now asserts that the sequence stays the same, byte by byte. If it changes, the test fails, and I have to decide whether I meant it.

These tests have limits. A fake only proves that the code matches my understanding of the protocol. Reading state is confirmed on real hardware, but the write commands are still going through a manual checklist in `docs/HARDWARE_TEST.md`.

## A 3D model from code

The app shows a 3D model of the headphones in its connection popup. The repository doesn't ship a mesh of someone else's product. The model is generated in Swift.

The main tool is what I call an oval lathe. A regular lathe spins a profile around an axis to make a round object. Ear cups aren't round, so instead of a circle, each point of the profile `(r, y)` scales a closed superellipse outline that's slightly wider at the bottom. Stack those rings and you get a smooth cup. The headband, cushions and other parts use similar generators, and they all produce a neutral mesh type that can be built for RealityKit or SceneKit.

Being procedural has a few advantages. The app bundle holds no mesh files, and the parts stay separate so a small rig can animate them: the cups swing in when the popup appears, and springs settle the headband. Tests can also render each state offscreen and check the result. Even the app icon is generated from the model by the command line tool. The model is a generic shape with no logos.

## Where it stands

Quietbar works with MDR v2 devices, and `MDRKit` is available as a standalone Swift package. The WH-1000XM5 is the only model I've tested in person. The next big step is MDR v1 for the XM4 and XM3, which use a different service UUID, a different codec and different boolean rules.

If you own a Sony model marked as experimental, a report helps more than anything else. And if you want to build something else with the protocol, the code is MIT licensed.

Quietbar is an independent project, not affiliated with or endorsed by Sony.
