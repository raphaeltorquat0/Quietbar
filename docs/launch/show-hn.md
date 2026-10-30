# Show HN

**Title**

Show HN: Quietbar – Control Sony headphones from the macOS menu bar

**URL**

https://github.com/raphaeltorquat0/Quietbar

**First comment**

Hi HN, I'm Raphael. Quietbar is a native macOS menu bar app for Sony headphones. It lets you change noise canceling, ambient level, EQ, multipoint and similar settings from the Mac, without the phone app.

[One or two sentences on why you built it, in your own words.]

There's no official Mac app for this, so Quietbar speaks Sony's MDR protocol directly. It opens an RFCOMM channel through IOBluetooth and exchanges small framed messages: a start byte, type, sequence, length, payload, checksum and an end byte, with byte escaping in between. A Swift actor owns the channel and sends one command at a time, waiting for each ACK. The headphones also send notifications when you press a physical button, and the UI only changes when the device confirms a new state.

I didn't work out the protocol alone. I studied two MIT projects, SonyHeadphonesClient and sony-headphones-linux, and used Gadgetbridge as a behavior reference. docs/PROTOCOL.md cites the source of each item. The parser tests run against recorded real traffic. The protocol layer is also a standalone Swift package, MDRKit, if you want to build something else with it.

The limits:

- I've only tested on a WH-1000XM5 (firmware 2.5.1). The WF-1000XM5 and LinkBuds Clip are validated against recorded traffic, not physical units.
- Reading state is confirmed on hardware. Write commands were validated against a simulated headphone, and I'm still working through the hardware checklist.
- Other MDR v2 models are experimental. The XM4 and XM3 use the older MDR v1 protocol and don't work yet.
- The app isn't notarized, so macOS asks you to approve it in System Settings on first launch.
- The Liquid Glass panel has only been checked by eye on macOS 27. macOS 14 and 15 build but haven't been checked visually.

It's MIT licensed and needs no account. Its only network use is a daily update check through Sparkle, which you can turn off.

If you own an experimental model, a report would help a lot. The Developer tab has a diagnostics button, and the issue template explains how to remove your Bluetooth address first.
