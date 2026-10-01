# ElmBleSim

Mac command line tool that pretends to be a BLE ELM327 adapter (service FFE0 / characteristic FFE1) with a simulated BMW ECU behind it, so the iOS app can be tried without a car or adapter.

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if Xcode is not selected
swift build
.build/debug/ElmBleSim ../EdiabasKit/Tests/EdiabasKitTests/Golden/obd.sim      # replay a recorded car
.build/debug/ElmBleSim                                                          # built-in test ECU 0x12
```

* Options: `--name OBDII` changes the advertised name.
* First run: macOS asks the terminal app for Bluetooth access.
* Then in the iPhone app: Adapter tab > Scan > tap "OBDII".
* `.sim` files are the recordings EDIABAS/the Android app use (`obd.sim` is the sample from `BmwDeepObd/Assets/Sample.zip`). Only exact request matches are replayed; unknown requests get no answer, which the app shows as "no response from control unit". The terminal prints each request so you can see what an SGBD asks for.
* Pick an SGBD that matches the recorded car's ECUs (the recording contains addresses 0x00, 0x01, 0x02, 0x12 ...).
