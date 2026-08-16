# Troubleshooting

## The log

Thor writes every warning to `user/thor.log` beside the binary, truncated at
each start, so the file always holds the session that just went wrong. The first
lines are the startup timings, which say what a slow start was waiting for:

```
[INFO ] [startup] load config              3.1 ms
[INFO ] [startup] text_begin_async_load    0.2 ms
[INFO ] [startup] InitWindow           40466.3 ms
```

## Thor takes tens of seconds to show its window (Windows)

The `InitWindow` timing above is the one to look at. raylib asks for the game
controllers while it makes the window, GLFW passes that to DirectInput, and
DirectInput reads a product string out of every HID device on the machine. A
device that does not answer costs about five seconds of timeout, and several
dead reads are half a minute with no window on screen yet.

Thor does not pay that any more: it refuses the DirectInput library for exactly
as long as the window takes to appear, which drops a forty-second start to under
a second. The scan is all Thor loses — it reads no gamepad. What is left of
DirectInput comes back the moment the window stands. Whenever window creation
still takes more than two seconds, Thor writes a warning to the log.

The devices themselves are still slow for everything else: any other GLFW or SDL
program on that machine, games included, pays the same startup cost. To find the
one at fault, unplug USB devices one at a time and start such a program again.
The usual offenders are wireless receivers whose keyboard or mouse is switched
off, virtual HID devices from gaming software (Logitech G HUB, Razer Synapse,
Corsair iCUE), and headset dongles.

What helps, in order of preference:

- Switch the wireless device on, or unplug the receiver you are not using.
- Update or remove the vendor software that adds the virtual device.
- Disable the individual HID collection in Device Manager. Mouse and keyboard
  input keeps working when you disable only the vendor-defined collections of a
  receiver, but the vendor software loses control of the device, and media keys
  go with the consumer-control collection.

## A language server does not answer

`user/thor.log` names a server that failed to start, and **Settings > Language
Servers** shows the same state with the error beside the entry. See
[Configuration](configuration.md) for the `lsp.json` layers and the `install`
command each entry can carry.

## A plugin does not load

A plugin that wants a permission stays unloaded until you allow it, in the
prompt at startup or under **Settings > Plugin Permissions**. A plugin whose Lua
fails reports the error in the log with the line that broke. See
[Plugins](plugins.md).
