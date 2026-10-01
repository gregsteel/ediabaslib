# BMW Deep OBD for iOS (work in progress)

Swift/SwiftUI port of the Android app. Layout:

| Folder | Content |
|---|---|
| `../EdiabasKit` | Swift port of the EDIABAS interpreter (BEST/2 VM), ELM327 CAN/ISO-TP layer, BMW-FAST/D-CAN over ELM, CoreBluetooth serial transport. Builds and is tested with plain `swift build` (see below). |
| `Sources/DeepObdUI` | SwiftUI views + `DiagnosticSession` (BLE connect, ECU folder, job list, run jobs, results, trace). |
| `App` | Xcode project `DeepObd.xcodeproj` (bundle id com.gregsteel.deepobd, team HDPPA6WPMT), `@main` file, icon, Info.plist. |

## Create the Xcode app (needs full Xcode)

1. Xcode > File > New > Project > iOS > App (SwiftUI), name `BMW Deep OBD`, iOS 17+.
2. Delete the generated `*App.swift` / `ContentView.swift`; add `AppEntry/BmwDeepObdApp.swift` to the target.
3. File > Add Package Dependencies > Add Local... > select this folder (`BmwDeepObdIos`), add product `DeepObdUI` to the app target (it pulls in `EdiabasKit`).
4. Target > Info: add `NSBluetoothAlwaysUsageDescription` ("Connects to the OBD adapter").
5. Run on a **real iPhone** (the simulator has no Bluetooth).

## Using it

* Adapter tab: choose the folder with your EDIABAS ECU files (`*.prg`, `*.grp`), scan, tap your BLE ELM327.
* Tool tab: pick an SGBD (e.g. `d_motor`), pick a job, optionally give arguments (`;` separated), execute.
* Log tab: ELM/EDIABAS trace, shareable.

## Verifying the engine on a Mac without Xcode

```
cd ../EdiabasKit   # i.e. ios/EdiabasKit
swift build --build-system native && .build/debug/EdiabasCheck
```
Replays the BEST/2 instruction test ECU (`EdiabasLib/Test/Ecu/cmd_test2.prg`) and compares with output recorded from the C# EdiabasLib, then runs a simulated ELM327 + BMW ECU through the BMW-FAST stack.

## Not done yet

Vehicle detection, XML/ccpage live-data pages, coding, actuator tests, service functions, trace file export to disk, Carly/WgSoft transports, ENET/WiFi, K-line. VAG is out of scope.
