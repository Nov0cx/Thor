#!/bin/sh
# Thin wrapper around build.odin, which does the real work (see its header).
odin run build.odin -file -- run "$@"
