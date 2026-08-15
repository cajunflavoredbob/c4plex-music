# c4plex

A native Control4 streaming music source for Plex Media Server.

Browse and search your Plex music library from any Control4 Navigator under
Listen; playback streams straight from the Plex server through the Control4
Digital Audio engine, the same model as the built-in streaming services.
Configuration is a server address plus a plex.tv/link account pairing (or a
pasted X-Plex-Token): no extra player hardware, and the only cloud contact
is the one-time plex.tv link, plus an optional GitHub update check that is
off by default.

## Layout

- `src/plex_music/` - the driver: manifest (`driver.xml`), MSP/service logic
  (`driver.lua`), Plex HTTP client (`plex.lua`), docs and Navigator icons
  (`www/`), Composer device icons (`icons/`)
- `common/c4plex/` - shared Lua framework packed into the c4z (dispatch,
  timers, logging)
- `build.py` - packs `src/*` into `dist/c4plex_<name>.c4z`

## Build

```
python3 build.py
```

Requires Python 3.9+. The version stamped into the driver comes from
`VERSION`.

## Install (Composer Pro)

1. Driver > Add or Update Driver, pick `dist/c4plex_plex_music.c4z`.
2. Add "Plex Music (c4plex)" to a room; Digital Audio connections autobind.
3. Set Plex Server Address / Port in driver properties, then run the Link
   Plex Account action and follow the plex.tv/link code (or paste a token
   into Plex Token); confirm Server Status shows Connected.
4. The service appears under Listen in rooms with Digital Audio.

Testing targets Control4 OS 3.4.3; the manifest floor is 3.0.0.

## License

MIT. See LICENSE.
