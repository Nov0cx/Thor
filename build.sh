#!/bin/sh
# On Windows (incl. git-bash) vendor:lua links against lua54.dll, which must sit
# next to the executable; copy it once from Odin's vendor tree. On Linux the
# vendor package links Lua statically, so the copy is skipped.
if [ ! -f lua54.dll ]; then
    ODIN_DIR=$(dirname "$(command -v odin)")
    LUA_DLL="$ODIN_DIR/vendor/lua/5.4/windows/lua54.dll"
    [ -f "$LUA_DLL" ] && cp -f "$LUA_DLL" lua54.dll
fi
odin run . -debug
