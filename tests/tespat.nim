## The driver against a module that is not there, which answers each command
## as the real one was seen to.

import lutra_espat, lutra/mqtt

type Fake = object

var
  script: seq[(string, string)] # What the driver should send, and the module's answer
  sent: string # Since the last answer
  coming: string # What the module has said, not yet read
  now: uint64

proc micros(): uint64 =
  now += 1000 # A millisecond goes by each time anyone looks
  now

proc send(link: static Fake, c: char) =
  sent.add c
  if script.len > 0 and sent == script[0][0]:
    coming.add script[0][1]
    script.delete(0)
    sent = ""

proc poll(link: static Fake): bool = coming.len > 0

proc receive(link: static Fake): char =
  result = coming[0]
  coming = coming[1..^1]

proc finished(): bool = script.len == 0 and sent == "" and coming == ""

const
  wifi = espAt(Fake())
  first = wifi.socket
  second = wifi.socket

doAssert (first.id, second.id) == (0, 1)

# Nothing there
doAssert not wifi.init()
doAssert sent == "AT+RST\r\n", sent.repr
sent = ""

script = @[
  ("AT+RST\r\n", "AT+RST\r\n\r\nOK\r\n\r\nready\r\n"), # Echoed, until echoing is turned off
  ("ATE0\r\n", "ATE0\r\n\r\nOK\r\n"),
  ("AT+SYSSTORE=0\r\n", "\r\nOK\r\n"),
  ("AT+CWMODE=1\r\n", "\r\nOK\r\n"),
  ("AT+CIPMUX=1\r\n", "\r\nOK\r\n"),
  ("AT+CIPRECVTYPE=5,1\r\n", "\r\nOK\r\n")]
doAssert wifi.init()
doAssert finished()

# Joining, with what AT commands take as punctuation escaped
script = @[("AT+CWJAP=\"my \\\"net\\\"\",\"a\\,b\\\\c\"\r\n", "WIFI CONNECTED\r\nWIFI GOT IP\r\n\r\nOK\r\n")]
doAssert wifi.join("my \"net\"", "a,b\\c")
script = @[("AT+CWJAP=\"net\",\"wrong\"\r\n", "+CWJAP:1\r\n\r\nERROR\r\n")]
doAssert not wifi.join("net", "wrong")
doAssert finished()

# A connection, data sent, and data received in two goes, with what looks
# like line endings and commas among it
script = @[
  ("AT+CIPSTART=0,\"TCP\",\"test.mosquitto.org\",1883,60\r\n", "0,CONNECT\r\n\r\nOK\r\n"),
  ("AT+CIPSEND=0,4\r\n", "\r\nOK\r\n\r\n>"),
  ("\x10\x02\x00\x00", "\r\nRecv 4 bytes\r\n\r\nSEND OK\r\n\r\n+IPD,0,6\r\n"),
  ("AT+CIPRECVDATA=0,4\r\n", "+CIPRECVDATA:4,\r\n\x00,\r\nOK\r\n\r\n+IPD,0,2\r\n"),
  ("AT+CIPRECVDATA=0,2\r\n", "+CIPRECVDATA:2,ab\r\nOK\r\n")]
doAssert first.connect("test.mosquitto.org", 1883)
doAssert first.send([0x10'u8, 2, 0, 0])
var data: array[4, byte]
doAssert first.receive(data) == 4 and data == [13'u8, 10, 0, 44]
doAssert first.receive(data) == 2 and data[0..1] == [97'u8, 98]
doAssert finished()

# The connection closing
coming = "0,CLOSED\r\n"
doAssert first.receive(data) == 0
script = @[("AT+CIPSEND=0,1\r\n", "\r\nERROR\r\n")]
doAssert not first.send([1'u8])
doAssert finished()

# Data the module turns out not to have, and then the connection closing
script = @[
  ("AT+CIPSTART=1,\"TCP\",\"host\",80,60\r\n", "1,CONNECT\r\n\r\nOK\r\n"),
  ("AT+CIPRECVDATA=1,4\r\n", "\r\nERROR\r\n1,CLOSED\r\n")]
doAssert second.connect("host", 80)
coming = "+IPD,1,9\r\n"
doAssert second.receive(data) == 0
doAssert finished()

# A socket is a Socket that MQTT can use, and there are five
const broker = mqtt(wifi.socket, "test.mosquitto.org")
doAssert compiles(broker.connect())
const (fourth, fifth) = (wifi.socket, wifi.socket)
doAssert fifth.id == 4
doAssert not compiles(wifi.socket)
