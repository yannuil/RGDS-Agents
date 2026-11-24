# Agents

Touch, the info panel, or the GT911: follow [TOUCH.md](TOUCH.md). A finger lands on the bottom window. It does not move the player and does not start the game.

Deploy, relaunch, sound, and the gamepad: follow [README.md](README.md) Setup and the header of `run-via-menu.sh`.

`ssh rgds` fails with "Too many authentication failures" when the client offers every key. Connect as `root@rgds.local` with `IdentitiesOnly=yes` and `IdentityFile=~/.ssh/id_ed25519`.
