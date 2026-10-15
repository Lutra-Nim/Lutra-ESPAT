## Wi-Fi through an ESP32 running Espressif's AT firmware, over a UART:
##
##   const
##     wifi = espAt(uart1)
##     broker = mqtt(wifi.socket, "test.mosquitto.org")
##
##   uart1.buffer(1024)
##   uart1.init(tx = IO6, rx = IO7, baud = 115_200)
##   if wifi.init() and wifi.join("network", "password") and broker.connect():
##     broker.publish("lutra/hello", "hi")
##
## The module takes commands on its UART1, which the firmware puts on IO6 for
## receiving and IO7 for sending, at 115200 baud. Each call waits for its
## answer, letting the other tasks run meanwhile. Nothing is written to the
## module's flash, so it starts afresh with every `init`.
##
## A socket is a `Socket` of Lutra's, and the module has five. Data that comes
## is held by the module until it is asked for, so nothing is lost while the
## program looks away. A connection is checked after a minute without
## traffic, and one found dead closes about three seconds later.

import std/[macros, macrocache]
import lutra/[at, fmt, tasks, time], lutra/hal/bytelink

type
  EspAt*[L] = object
    link*: L

  EspSocket*[L] = object
    module*: EspAt[L]
    id*: int

  State = object
    waiting: array[5, int] # Bytes the module holds for each socket
    open: array[5, bool]

func espAt*[L](link: L): EspAt[L] =
  ## A module on `link`, a UART brought up at the module's rate
  EspAt[L](link: link)

const sockets = CacheCounter"lutra_espat.sockets"

macro socket*(module: untyped): untyped =
  ## Each use is another of the module's sockets
  let id = sockets.value
  if id >= 5: error "An ESP-AT module has five sockets, and this would be a sixth", module
  sockets.inc
  quote do: EspSocket[typeof(`module`.link)](module: `module`, id: `id`)

proc state[L](module: static EspAt[L]): ptr State =
  var state {.global.}: State
  addr state

proc number(line: openArray[char], at: var int): int =
  ## The digits from `at`, and `at` moved past them and what ends them
  while at < line.len and line[at] in '0'..'9':
    result = 10 * result + ord(line[at]) - ord('0')
    inc at
  inc at

proc notice[L](module: static EspAt[L]) =
  ## Takes note of a line the module sent unasked: data waiting for a
  ## socket, or a connection gone
  template line: untyped = module.link.line
  let s = module.state
  if line.startsWith("+IPD,"):
    var at = 5
    let id = line.number(at)
    if id < 5: s.waiting[id] = line.number(at)
  elif line.len == 8 and line[0] in '0'..'4' and line.toOpenArray(1, 7).startsWith(",CLOSED"):
    let id = ord(line[0]) - ord('0')
    (s.waiting[id], s.open[id]) = (0, false)

proc answer[L](module: static EspAt[L], within: Duration): bool =
  ## Waits for a command's outcome: true for `OK`, `SEND OK` or the prompt for
  ## data, false for an error or for no answer
  template line: untyped = module.link.line
  while module.link.hear(within):
    if line == "OK" or line == "SEND OK" or line == ">": return true
    if line == "ERROR" or line == "FAIL" or line == "SEND FAIL": return false
    module.notice()

proc escaped(link: static ByteLink, text: openArray[char]) =
  ## `text`, with what AT commands take as punctuation escaped
  for c in text:
    if c in {'"', ',', '\\'}: link.put('\\')
    link.put(c)

proc init*[L: ByteLink](module: static EspAt[L]): bool {.discardable.} =
  ## Restarts the module as a Wi-Fi station. False if no module answers.
  const link = module.link
  link.acquire()
  module.state[] = State()
  link.command "+RST"
  result = module.answer(1.sec)
  while result and link.line != "ready": result = link.hear(5.sec)
  for setting in [cstring"E0", "+SYSSTORE=0", "+CWMODE=1", "+CIPMUX=1", "+CIPRECVTYPE=5,1"]:
    if result:
      link.command setting
      result = module.answer(1.sec)
  link.release()

proc join*[L: ByteLink](module: static EspAt[L], network, password: openArray[char]): bool {.discardable.} =
  ## Joins a Wi-Fi network, waiting up to 20 s. False if it could not.
  const link = module.link
  link.acquire()
  link.write "AT+CWJAP=\""
  link.escaped(network)
  link.write "\",\""
  link.escaped(password)
  link.write "\"\r\n"
  result = module.answer(20.sec)
  link.release()

proc connect*[L: ByteLink](socket: static EspSocket[L], host: openArray[char], port: int): bool =
  ## Connects to a server by TCP, waiting up to 10 s
  const (module, link) = (socket.module, socket.module.link)
  let s = module.state
  link.acquire()
  link.command "+CIPSTART=", socket.id, ",\"TCP\",\"", host, "\",", port, ",60"
  result = module.answer(10.sec)
  (s.waiting[socket.id], s.open[socket.id]) = (0, result)
  link.release()

proc send*[L: ByteLink](socket: static EspSocket[L], data: openArray[byte]): bool =
  ## False if the connection is gone
  mixin send
  const (module, link) = (socket.module, socket.module.link)
  link.acquire()
  link.command "+CIPSEND=", socket.id, ",", data.len
  if module.answer(1.sec) and module.answer(1.sec): # `OK`, then the prompt
    for b in data: link.send(b.char)
    result = module.answer(5.sec)
  link.release()

proc ready[L](socket: static EspSocket[L]): bool =
  ## Whether data waits for the socket, or its connection is gone. When no
  ## task is talking to the module, what it has sent unasked is read first.
  const (module, link) = (socket.module, socket.module.link)
  let s = module.state
  if not link.busy:
    while link.heard(): module.notice()
  s.waiting[socket.id] > 0 or not s.open[socket.id]

proc receive*[L: ByteLink](socket: static EspSocket[L], data: var openArray[byte]): int =
  ## Waits for data, and returns how much came; or 0 once the connection is
  ## gone
  mixin receive
  const (module, link) = (socket.module, socket.module.link)
  let s = module.state
  while result == 0:
    wait socket.ready
    if s.waiting[socket.id] == 0: return 0
    link.acquire()
    link.command "+CIPRECVDATA=", socket.id, ",", min(data.len, s.waiting[socket.id])
    while link.hear(1.sec, binary = "+CIPRECVDATA:"):
      if link.line.startsWith("+CIPRECVDATA:"):
        var at = 13
        result = link.line.number(at)
        for i in 0..<result: data[i] = link.receive().byte
      elif link.line == "OK" or link.line == "ERROR": break
      else: module.notice()
    # Nothing came if the module has nothing after all
    s.waiting[socket.id] = if result == 0: 0 else: max(0, s.waiting[socket.id] - result)
    link.release()

proc close*[L: ByteLink](socket: static EspSocket[L]) =
  const (module, link) = (socket.module, socket.module.link)
  let s = module.state
  link.acquire()
  link.command "+CIPCLOSE=", socket.id
  discard module.answer(1.sec)
  (s.waiting[socket.id], s.open[socket.id]) = (0, false)
  link.release()
