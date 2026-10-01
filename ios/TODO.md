# iOS port TODO

Status: engine, ELM327/BLE layer, fault read/clear, whole-vehicle fault scan, named ECU sets and translations work against the simulator (`ElmBleSim`). Nothing has been tried on a real adapter or car yet (adapter on order).

## Vision: a friendly, per-vehicle dashboard

A set of screens that are pleasant to use without knowing EDIABAS, so the app is not just a job runner:

1. **Faults**: see all faults, understand them (English text, which ECU), clear them. *(Done as a generic scan; make it the home screen, add freeze-frame details, history of past scans, share/export a report.)*
2. **Service**: show the Condition Based Service (CBS) items with remaining km/time, and reset them after a service (jobs `CBS_DATEN_LESEN`, `CBS_RESET`, cluster jobs like `STEUERN_CBS_KM_PER_YEAR`). Confirm before writing; read and store the old values first.
3. **Useful information**: vehicle identity (VIN, build date, I-level, ECU list with part/software numbers), battery state, mileage, oil level/temperature, DPF status for diesels, etc.
4. **Settings / control**: the handy things people change: service resets, comfort/coding-light options that are safe, adaptation resets, test functions (actuators). Always read before write, always confirm, log what was changed.

## Per-vehicle pages: plug-in framework

Pages differ a lot per vehicle (E60 N47 diesel vs Mini R56 petrol vs F-series), so the dashboard must be assembled from page definitions, not hard-coded.

Design thoughts to settle:

- **Prefer declarative pages (data), with a Swift escape hatch.** A page definition says *which job on which ECU group with which arguments, and how to show/convert each result* (gauge, value, on/off, list, button with confirm). A vehicle ships a small bundle of such definitions; adding a car = adding a file, no app release.
- **The Android app already has this format**: `*.ccpage` / `*.ccpages` XML (`BmwDeepObd/Xml/E61`, `E90`, `G31`, `Sample`, schema `BmwDeepObd.xsd`, plus `Sample.zip` assets). Importing/understanding that format gives immediate content (live data pages, error pages) and keeps compatibility with the original project. Decide: read the existing XML as-is, or define a slimmer JSON and write a converter.
- **Applicability rules**: a page declares which vehicles/ECU variants it fits (series, ECU variant name from `IDENT`, I-level), so the dashboard only offers pages that will work. Unknown car -> fall back to the generic fault scan + job runner.
- **Safety model for writing pages**: every action that writes needs declared "reads first, restores on failure if possible", a confirmation, and an entry in a change log. Mark pages as *read-only* by default.
- **Where pages live**: bundled starter set + user-imported files (Files app, same folder mechanism as ECU sets) + maybe attached to an ECU set/vehicle profile ("Mini R56", "BMW N47").
- **Vehicle profile**: tie together ECU set, detected vehicle (VIN/FA), chosen pages and notes, so the app opens straight to the right dashboard.

## Engine / protocol

- [ ] Real-adapter bring-up: connect to a real BLE ELM327, collect logs, tune timeouts (probe timeouts, BLE write pacing), handle clone quirks.
- [ ] Vehicle identification: VIN, FA/build data, series, I-level (port `DetectVehicleBmw` essentials) to drive page applicability and ECU lists.
- [ ] Faster ECU scan (about 75 s now): use the vehicle's ECU list, probe in parallel where the bus allows, cache the ECU map per ECU set on disk.
- [ ] Result formatting: port `FormatResult` (units, number formats) for page widgets.
- [ ] Live data: periodic job execution with graphs/gauges (frequent-mode style), start/stop, logging to file.
- [ ] Trace/log export to a file and share sheet.
- [ ] ENET/WiFi adapter (F/G-series), other BLE adapters (profiles for Carly/vLinker/WgSoft are in the BLE table but untested).
- [ ] K-line/KWP2000* cars: not possible with a plain ELM327; document and show a clear message (already reported as "concept not implemented").
- [ ] XCTest target (`VMTests.swift`) runs under Xcode; check it passes there and hook it to CI-style `xcodebuild test`.

## App / UX

- [ ] Home dashboard (the vision above) replacing the Tool tab as the default; keep the job runner as an "Advanced" area.
- [ ] Service screen (CBS) with confirmation and change log.
- [ ] Translation: improve quality for fault location names (cache to disk, bulk pre-translate, user-editable glossary).
- [ ] Recent jobs per ECU; favourites.
- [ ] Reconnect handling: auto-reconnect to the last adapter, resume after the app was backgrounded.
- [ ] Settings: language, units, trace level, ECU-set management polish.
- [ ] App icon/design pass (placeholder icon today); accessibility; iPad layout.

## Housekeeping / project

- [ ] Keep SGBD/ECU data out of git (`/SGBD/` is ignored). Earlier commits contain a few stray `.build` files: squash or rewrite history before contributing upstream.
- [ ] Licence: the repo is GPLv3 and this is a derivative. TestFlight/App Store distribution is **postponed** until the original author agrees (user plans to contribute it back). Do not upload before that is settled.
- [ ] Contribution upstream: split into reviewable commits, write a short design doc, make sure the build instructions in `BmwDeepObdIos/README.md` are accurate.
- [ ] Rename "BMW" in the app name if it is ever distributed (trademark).

## Tools in this folder

- `EdiabasKit/` engine + `EdiabasCheck` CLI (modes: run, simrun, tables, ecumap, scan).
- `ElmBleSim/` Mac BLE adapter simulator replaying `.sim` recordings (`Golden/obd.sim`, `Golden/obd_faults.sim`).
- `BmwDeepObdIos/` SwiftUI library + `App/DeepObd.xcodeproj`.
