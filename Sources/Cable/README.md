# Cable diagnostics

`machelper cable` reads the IORegistry and CoreGraphics display modes without administrator
rights. It never writes hardware properties or changes PD contracts.

```sh
machelper cable                 # status: ports, cable, displays, charging findings
machelper cable ports --json
machelper cable devices --json
machelper cable displays --json
machelper cable charging --json
```

Every JSON response has `"schemaVersion": 1`. The full `status` response is the
`CableSnapshot` object with `generatedAt`, `machineModel`, `ports`, `cables`,
`usbDevices`, `thunderboltDevices`, `displays`, `power` and `findings`.

## VDO bit layout

The decoder follows USB Power Delivery 3.1/3.2/3.3 tables 6.45 (Passive Cable VDO),
6.47 (Active Cable VDO1) and 6.48 (Active Cable VDO2). IORegistry stores every VDO
as four little-endian bytes, so `<43260a25>` is `0x250A2643`.

SOP' answers Discover Identity in this order:

| VDO | Passive cable | Active cable |
| --- | --- | --- |
| 0 | ID Header | ID Header |
| 1 | Cert Stat | Cert Stat |
| 2 | Product | Product |
| 3 | Cable VDO | Active Cable VDO1 |
| 4 | — | Active Cable VDO2 |

Index 3 therefore always carries the speed, current and voltage fields; an active
cable appends VDO2 at index 4.

| Bits | Field | Codes used by the decoder |
| --- | --- | --- |
| 31..28 | Hardware version | vendor assigned |
| 27..24 | Firmware version | vendor assigned |
| 23..21 | VDO version | `000b` passive, `011b` active SVDM 2.1 v1.3 |
| 19..18 | Plug type | `10b` Type-C, `11b` captive; `00b`/`01b` deprecated Type-A/B |
| 17 | EPR capable | `1b` = safe at 48 V / 5 A |
| 16..13 | Cable latency | `0001b` <10 ns (~1 m) … `1000b` >70 ns (>~7 m); active cables extend to ~300 m |
| 12..11 | Termination | passive `00b` VCONN not required, `01b` required; active `10b`/`11b` |
| 10..9 | Maximum VBUS voltage | `00b` 20 V, `11b` 50 V; `01b`/`10b` deprecated, receiver assumes 20 V |
| 8..7 | Reserved (passive) / SBU supported + SBU type (active) | `0b` SBU supported, passive or active |
| 6..5 | VBUS current | `01b` 3 A, `10b` 5 A |
| 4 | VBUS through cable | active cables only |
| 3 | SOP'' controller present | active cables only |
| 2..0 | USB highest speed | `000b` USB2, `001b` 5 Gbps, `010b` 10 Gbps, `011b` USB4 Gen3 40 Gbps, `100b` USB4 Gen4 80 Gbps |

Maximum wattage uses the negotiable voltage: 20 V x 3 A = 60 W, 20 V x 5 A = 100 W,
and an EPR 50 V code with 5 A = 240 W (48 V negotiable). When SOP' does not answer
Discover Identity, the tool reports "No e-marker: at most 3 A / 60 W; data rate unknown."

Active cables additionally decode VDO2 (PD 3.3 table 6.48): maximum operating and
shutdown temperature in °C, bit 10 copper/optical, bit 9 re-driver/re-timer, bit 8
USB4 supported, bits 7..6 USB 2.0 hub hops, bit 5 USB 2.0 supported, bit 4 USB 3.2
supported, bit 3 lane count, bit 2 optically isolated, bit 1 USB4 asymmetric mode
supported (reserved in PD 3.0) and bit 0 Gen 2 or higher.

## USB devices and their USB-C port

`IOUSBHostDevice` carries no port property, so the port is resolved from the
`IOPortTransportStateUSB2`/`USB3` of each USB-C port, which names the device plugged
into it (`Vendor ID`, `Product ID`, `Product`). VID+PID decides the match; when several
devices share both identifiers the reported product name separates them, and a
remaining ambiguity leaves `portNumber` nil instead of guessing. Devices under a
matched hub inherit its port. Roots that match no port — the Mac's own hubs — keep
`portNumber` nil and are flagged `isBuiltIn`.

## USB speed reporting

IORegistry has no BOS Device Capability descriptor, so `bcdUSB` only tells which USB
protocol version a device speaks, not how fast it can run:

- `bcdUSB` 2.x or below: `maxSpeedMbps` is nil (unknown). A `0x200` device is not
  necessarily a 480 Mbps device.
- `bcdUSB` 3.x: `maxSpeedMbps` is `max(negotiated, 5000)`. A `0x320` device is not
  necessarily a 10 Gbps device (a Gen1 hub reports 5 Gbps).

The "running at USB 2.0 speed" finding therefore only fires when the descriptors prove
a USB 3 link; a device whose ceiling is unknown never gets a bottleneck warning. The
CLI text prints `max …` only when that maximum is known.

## Charging findings

`ChargingDiagnosis.evaluate` is a pure function over the typed snapshot. It reports
adapter below the model recommendation, 3 A cable limiting charging to 60 W, missing
e-marker, paused charging with decoded `NotChargingReason` bits, a dock or display
sharing the power path, a hot battery, and a device negotiating USB 2.0 speeds despite
a faster capability. Each finding has a stable `id`, an `info`/`warning`/`problem`
severity, a reason and a suggestion.

A possible charging port is connected, answers Discover Identity as SOP
(`Vendor ID (SOP)` in the CC transport state) and carries no USB2, USB3, CIO or
DisplayPort traffic. The cable rules (3 A, no e-marker) only look at that port, so a
keyboard cable on another port cannot raise a charging warning. When no port looks like
the charger, the rules fall back to every connected port, drop to `info` and name the
port they inspected ("If the charger is connected to Port-USB-C@N"). The dock/display
rule needs a PD partner plus DisplayPort, Thunderbolt/USB4, a USB hub or a USB-C
display on the same port.

A desktop Mac can expose `AppleSmartBattery` with `AdapterDetails.FamilyCode = 0`.
`BatteryInstalled`, design capacity and the machine model are checked first; desktops
get a single "not applicable" finding instead of fabricated charging advice.

## Thunderbolt/USB4 links

`IOPortTransportStateCIO` exposes link codes, not rates: `Generation`, `CableSpeed`
and `CableGeneration`. No published mapping turns those codes into a Thunderbolt
generation or Gb/s, so the tool prints them as codes ("Thunderbolt/USB4 link active
(generation code 2, cable speed code 3)") rather than guessing. A "Gen2" label would
read like USB 10 Gbps, which is a different link.

## Privacy

Test fixtures in `Tests/CableTests/Fixtures` come from `ioreg -a -l -w0` on the
development Mac, reduced to the fields above. Serial numbers, UUIDs, MAC addresses,
EDID payloads and other identifying data were removed. The CLI prints no serial
number even when IORegistry exposes one.
