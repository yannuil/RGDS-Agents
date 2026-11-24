# Touch

A finger on the bottom window draws a cross at that point. The gamepad is unchanged. A finger does not move the player and does not start the game.

This app has one window, on the bottom panel. Test there. The yellow start control does not see the finger.

## Panels

| Panel | SDL display | Window | Touch |
| --- | --- | --- | --- |
| OS menu | 0 | muos2.bin, DSI-1 top | none |
| RGDS-Agents | 1 | LÖVE window, DSI-2 bottom | GT911, 640×480 |

`gt9xx-0` is on I2C bus 5 (`fe5e0000.i2c`), address `0x14`, input node `/dev/input/event1` (phys `input/ts0`, by-path `platform-fe5e0000.i2c-event`). udev marks it `ID_INPUT_TOUCHSCREEN=1` with `INPUT_PROP_DIRECT`. The GPIO IRQ is `rockchip_gpio_irq 14` (`gt9xx` in `/proc/interrupts`). A rising count means the bottom panel was touched.

`gt9xx-1` on `i2c@fe5c0000` is `status = "disabled"` in the device tree and has no input node. Leave it disabled. Binding it from sysfs fails (`no device tree`), and the kernel has no overlay support. Leave `muos2.bin` and the device tree as they are.

## Where the coordinates come from

Weston holds `event1` and does not send Wayland touch to the LÖVE window. `love.touchpressed` and `SDL_FINGERDOWN` / `SDL_FINGERUP` / `SDL_FINGERMOTION` (`0x700`–`0x702`) do not fire for this panel.

The goodix driver counts the IRQ and does not queue `input_event`s on `event1`. A non-blocking read returns `EAGAIN` after `EVIOCGRAB` (`0x40044590`) as well. `evdev.lua` still opens and grabs `event1`. The cross follows the I2C registers, not those packets.

The chip answers as a GT911: register `0x8140` reads `911`. Config at `0x8047` is version, then little-endian x max, y max. On this panel that is 640×480.

Finger data is register `0x814E`, 16-bit address, big-endian on the wire:

| Byte | Meaning |
| --- | --- |
| 0 | Bit 7 set means the buffer is ready. The low nibble is the finger count. |
| 1 | Track id |
| 2–3 | x, little-endian |
| 4–5 | y, little-endian |

After a ready buffer, write `0` to `0x814E`. The chip keeps the same point until that write. Open `/dev/i2c-5` and use `I2C_RDWR` (`0x0707`): one write of the 16-bit register, then a read. Address `0x14`.

x and y are info-panel pixels, origin top-left. Scale with `640 / xmax` and `480 / ymax` from the config.

## Events

`touchthread.lua` polls the register. A LÖVE thread does not load `love.timer` until the file requires it; without that require the thread exits on the first sleep. Idle poll is 8 ms. While a finger is down the poll is 2 ms. The thread pushes a point only when the position changes, and pushes the release when the buffer is clear.

`touchpoll.pump()` drains channel `rgds-touch` and calls `noteFinger`:

| Phase | When |
| --- | --- |
| `true` | The finger count goes from 0 to at least 1. One log line. |
| `"move"` | The finger stays down and the point changed. |
| `false` | The buffer is clear, or the count is 0. The cross stays. |

`pump` runs at the start of `love.update`, inside the title-screen wait, and at the start of `drawFingerMark` so the cross is the newest point.

## Frame rate

On the title screen, with the mic off and no finger down, `love.update` sleeps in 16 ms slices for up to 150 ms, then draws. A finger down ends that wait. While the finger stays down the sleep stays off, so the cross is drawn every frame. A live mic also skips the sleep.

Sampling on the main thread, or drawing the cross only after the 150 ms sleep, is what makes the mark lag.

## What a finger does

While the finger is down this window draws a gold ring, a gold cross (112 px across), a pink dot, and the label `TOUCH x, y`. After the finger lifts, the same mark stays and turns mint.

Finger down prints one line to `/tmp/RGDS-Agents.log`:

```
touch: info <x>,<y>
```

Moves do not print. A working start also prints `touchpoll: gt911 640x480`. The d-pad, stick, and face buttons are unchanged.
