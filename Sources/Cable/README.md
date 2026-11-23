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

The decoder follows USB Power Delivery 3.1 tables 6.45 (Passive Cable VDO),
6.47 (Active Cable VDO1) and 6.48 (Active Cable VDO2); PD 3.2/3.3 keep the same
fields. The Cable VDO is the fourth Discover Identity VDO (index 3). IORegistry
stores it as four little-endian bytes, so `<43260a25>` is `0x250A2643`.

| Bits | Field | Codes used by the decoder |
| --- | --- | --- |
| 31..28 | Hardware version | vendor assigned |
| 27..24 | Firmware version | vendor assigned |
| 23..21 | VDO version | `000b` passive, `011b` active SVDM 2.1 v1.3 |
| 19..18 | Plug type | `10b` Type-C, `11b` captive; `00b`/`01b` deprecated Type-A/B |
| 17 | EPR capable | `1b` = safe at 48 V / 5 A |
| 16..13 | Cable latency | `0001b` <10 ns (~1 m) … `1000b` >70 ns; active cables extend to ~300 m |
| 12..11 | Termination | passive `00b` VCONN not required, `01b` required; active `10b`/`11b` |
| 10..9 | Maximum VBUS voltage | `00b` 20 V, `11b` 50 V; `01b`/`10b` deprecated, receiver assumes 20 V |
| 6..5 | VBUS current | `01b` 3 A, `10b` 5 A |
| 2..0 | USB highest speed | `000b` USB2, `001b` 5 Gbps, `010b` 10 Gbps, `011b` 40 Gbps, `100b` 80 Gbps |

Maximum wattage uses the negotiable voltage: 20 V x 3 A = 60 W, 20 V x 5 A = 100 W,
and an EPR 50 V code with 5 A = 240 W (48 V negotiable). When SOP' does not answer
Discover Identity, the tool reports "No e-marker: at most 3 A / 60 W; data rate unknown."

Active cables additionally decode VDO2 for maximum operating and shutdown
temperature, copper/optical construction, re-driver/re-timer, USB4/USB2/USB3
support, lane count and USB4 asymmetric mode.

## Charging findings

`ChargingDiagnosis.evaluate` is a pure function over the typed snapshot. It reports
adapter below the model recommendation, 3 A cable limiting charging to 60 W, missing
e-marker, paused charging with decoded `NotChargingReason` bits, a hub/display sharing
the power path, a hot battery, and a device negotiating USB 2.0 speeds despite a
faster capability. Each finding has a stable `id`, an `info`/`warning`/`problem`
severity, a reason and a suggestion.

A desktop Mac can expose `AppleSmartBattery` with `AdapterDetails.FamilyCode = 0`.
`BatteryInstalled`, design capacity and the machine model are checked first; desktops
get a single "not applicable" finding instead of fabricated charging advice.

## Privacy

Test fixtures in `Tests/CableTests/Fixtures` come from `ioreg -a -l -w0` on the
development Mac, reduced to the fields above. Serial numbers, UUIDs, MAC addresses,
EDID payloads and other identifying data were removed. The CLI prints no serial
number even when IORegistry exposes one.
