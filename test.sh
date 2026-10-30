#!/bin/sh
# ponytail: Command Line Tools ship Swift Testing outside the default search path and with a broken
# _Testing_Foundation overlay. With full Xcode installed, plain `swift test` works and this file can go.
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" "$@"
