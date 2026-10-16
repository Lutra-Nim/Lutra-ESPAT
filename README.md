# lutra_espat
### Wi-Fi through an ESP32 running Espressif's AT firmware, for Lutra

A driver for [Espressif's AT firmware](https://docs.espressif.com/projects/esp-at/), which turns an ESP32 into a Wi-Fi module that another board drives over a UART. It is written against [Lutra](https://github.com/Lutra-Nim/Lutra)'s `ByteLink` interface, and its sockets are Lutra `Socket`s, so Lutra's MQTT client runs over them.

```nim
import lutra, lutra/mqtt, lutra_espat

const
  wifi = espAt(uart1)
  broker = mqtt(wifi.socket, "test.mosquitto.org")

uart1.buffer(1024)
uart1.init(tx = IO6, rx = IO7, baud = 115_200)

if wifi.init() and wifi.join("network", "password") and broker.connect():
  broker.publish("lutra/hello", "hi")
```

| | |
|---|---|
| `espAt(link)` | A module on a UART, brought up at the module's rate |
| `wifi.init()` | Restarts the module as a Wi-Fi station. False if no module answers |
| `wifi.join(network, password)` | Joins a network, waiting up to 20 s. False if it could not |
| `wifi.socket` | Another of the module's five sockets, each a Lutra `Socket`. A sixth does not compile |

Each call waits for the module's answer, letting Lutra's other tasks run meanwhile. Nothing is written to the module's flash, so it starts afresh with every `init`. Data that comes is held by the module until it is asked for, so nothing is lost while the program looks away. A connection is checked after a minute without traffic, and one found dead closes about three seconds later.

The module was an ESP32-C3-DevKitM-1 with version 4.1.1.0 of the firmware for the ESP32-C3-MINI-1, from [Espressif's list](https://docs.espressif.com/projects/esp-at/en/latest/esp32c3/AT_Binary_Lists/esp_at_binaries.html), written with:

```
esptool --chip esp32c3 --port /dev/ttyUSB1 write-flash -z --flash-mode dio --flash-freq 40m --flash-size 4MB 0x0 factory/factory_MINI-1_unfilled.bin
```

That firmware takes commands on IO6 and answers on IO7, at 115200 baud. Wire the module's IO6 to the board's transmit pin, its IO7 to the board's receive pin, and ground to ground. The module needs power of its own, from its USB socket.

The example in [examples/](examples) publishes the time each second to test.mosquitto.org and lights the LED on a message. It is run from that folder, with Lutra checked out beside this repository in a folder named `lutra`, and the network in `LUTRA_WIFI_NETWORK` and `LUTRA_WIFI_PASSWORD`:

```
nim flash mqtt.nim
```

`nim r tespat.nim` in [tests/](tests) checks the driver on the host, against a stand-in module that answers as the real one was seen to. Lutra's `nim wifi` check runs it on the boards.
