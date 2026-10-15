## Joins a Wi-Fi network through an ESP32-C3 running Espressif's AT firmware,
## and through test.mosquitto.org, a public broker, publishes how long the
## board has been up every second, and lights the LED green on `on`. On a
## computer:
##
##   mosquitto_sub -h test.mosquitto.org -t 'lutra/demo/#' -v
##   mosquitto_pub -h test.mosquitto.org -t lutra/demo/led -m on
##
## Wire this board's IO6 to the module's IO6, its IO7 to the module's IO7,
## and ground to ground. The network is taken from LUTRA_WIFI_NETWORK and
## LUTRA_WIFI_PASSWORD when the program is built. A connection lost is not
## made again.

import lutra, lutra/mqtt, lutra_espat

const
  network {.strdefine.} = "my network"
  password {.strdefine.} = "my password"
  wifi = espAt(uart1)
  broker = mqtt(wifi.socket, "test.mosquitto.org")

uart1.buffer(1024)
uart1.init(tx = IO6, rx = IO7, baud = 115_200)

proc listen() {.task.} =
  for message in broker.messages:
    if message.payload == "on": rgbLed.color(green = 20)
    else: rgbLed.color()

if not wifi.init(): print "No ESP-AT module answers\n"
elif not wifi.join(network, password): print "Could not join ", network, "\n"
elif not broker.connect(): print "No broker\n"
else:
  broker.subscribe("lutra/demo/led")
  start listen
  for turn in every(1.sec):
    broker.publish("lutra/demo/up", millis(), " ms")
