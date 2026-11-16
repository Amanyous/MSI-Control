# EC profile support

Common controls use the ten-character firmware families published by
BeardOverflow/msi-ec, rather than an exact local firmware version whitelist.
The reviewed source is identified by SHA256:

`54f8c30d18f9687e637ee135a254089513209370d4bb0631d86e51f56b5b4bb8`

Source: https://github.com/BeardOverflow/msi-ec/blob/master/msi-ec.c

Upstream is GPL-2.0-or-later. The generated tables record factual firmware
identifiers, register addresses and mode numbers; they do not copy the Linux
driver implementation. Regenerate both tables together with
`python3 Tools/GenerateECProfiles.py /path/to/reviewed/msi-ec.c`.

API 10 / MSIECBridge 0.3.7 supports charge limit, fan mode and Cooler Boost
for matching families. Profiles without charging support remain unsupported
for that feature. The legacy fan mode encoding only exposes 0D/1D/8D modes;
the G1_10 0C/4C/8C fan modes are not exposed by this application.

Existing API 9 remains supported for the previously supported local controls.
New families require the new driver. Unknown families remain read-only.
Fan curves, tachometer counters, mute LEDs, Fn-lock and combined performance
presets retain their independent local compatibility checks.

Mappings are theoretical compatibility, not evidence of physical testing on
178 machines. Hardware writes still require authorization, expected-value
checks, locking and readback verification. Building does not install a kext.

EC firmware is read using the bridge identity method independently of charge
telemetry. OpenCore version is read only from an exposed `opencore-version`
device-tree property. When absent, the application cannot establish the running
version; it does not guess from files, change ExposeSensitiveData or write EFI.
