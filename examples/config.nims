import std/os
import lutra/project # `nimble install -d` in this repository installs it
board "esp32c3_devkitm1"
switch("path", "$projectDir/../src")

# The Wi-Fi network to join, from the environment, so that it is never written here
for (name, variable) in [("network", "LUTRA_WIFI_NETWORK"), ("password", "LUTRA_WIFI_PASSWORD")]:
  if existsEnv(variable): switch("define", name & "=" & getEnv(variable))
