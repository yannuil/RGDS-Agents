# RGDS-Agents

LÖVE game for the Anbernic RG DS. Speech is a small `sv-helper` process (sherpa-onnx SenseVoice) beside the game. Chat goes through `rgds-aid.py`, which calls an OpenAI-compatible chat endpoint. The API key stays on the device.

## Setup

The model, sherpa libraries, and `stt/sv-helper` are not in git. From the repo root:

```sh
./setup-stt.sh
```

That downloads SenseVoice-Small int8 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` (model md5 `0e8e550411d3589be9f0af06f1c8fec3`), the sherpa-onnx v2.0.1 aarch64 shared libraries, and builds `stt/sv-helper`.

On an x86_64 dev machine you need `aarch64-linux-gnu-gcc` (Fedora also needs `sysroot-aarch64-fc*-glibc`; Debian/Ubuntu needs `libc6-dev-arm64-cross`). On the device the script uses the native `gcc`.

The device needs LÖVE 11.5 at `/opt/love/love-11.5`. `deploy.sh` copies that into the app and stops with install commands if it is missing.

```sh
./deploy.sh rgds
```

`rgds` is the SSH host (`rgds.local`). That copies the app to `/mnt/mmc/Roms/APPS/RGDS-Agents/` and writes the menu entry `/mnt/mmc/Roms/APPS/RGDS-Agents.sh`.

Launch it from the device APPS menu. With the menu already up (`muos2.bin` running):

```sh
ssh rgds /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh
```

`run-via-menu.sh` leaves `muos2.bin` running, so the top panel stays the menu. This app's only window is the bottom panel. The script refuses to start when the menu is not running.

Choosing the app in the APPS menu exits `muos2.bin` before this launcher runs. The launcher starts `muos2.bin` again and runs love on the bottom panel. ALSA and `event3` stay with the menu.

To relaunch, `SIGTERM` the `love` process and run the script again once `muos2.bin` is running. The game log is `/tmp/RGDS-Agents.log`.

## API key

`rgds-aid.py` reads `$RGDS_AI_CONFIG` if that variable is set. Otherwise it uses the first file that exists: `/userdata/rgds-ai/config.json`, then `/root/.config/rgds-ai/config.json`. If neither exists, it still tries `/userdata/rgds-ai/config.json`.

Create that file on the device and `chmod 600` it. The program does not set the mode itself. Do not commit the file, and do not commit `minimax.key`.

`$RGDS_AI_KEY`, if set, replaces `api_key` after the file is loaded. The file is still required.

MiniMax, using the built-in URL and model:

```json
{"provider":"minimax","api_key":"PASTE_YOUR_KEY"}
```

`provider` `minimax` fills in `base_url` `https://api.minimax.cn/v1` and `model` `MiniMax-M3` when those fields are omitted.

DeepSeek, or any other OpenAI-compatible API, is the same file with your own `base_url` and `model`. The provider name is not checked except for that MiniMax default. The sidecar POSTs `{base_url}/chat/completions` with `Authorization: Bearer`, `stream: true`, and `max_completion_tokens` (the config field is `max_tokens`, default 800). For `MiniMax-M3` it also sends `thinking: {type: "disabled"}` unless `thinking` is `disabled` or `adaptive`.

```json
{"provider":"deepseek","api_key":"PASTE_YOUR_KEY","base_url":"https://api.deepseek.com","model":"deepseek-chat"}
```

Optional fields: `system`, `max_tokens`, `history_turns` (default 6). Chat fails closed unless `api_key`, `base_url`, and `model` are all set.
