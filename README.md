# Flight Monitor

An Omarchy shell bar widget that tracks one flight by its number.

Click the plane icon in the bar, type a flight number such as `LA3195`
(or an ICAO callsign such as `TAM3195`) and press Enter. The popup shows:

- the route: origin and destination airports, the scheduled departure and
  arrival in each airport's local time, and what actually happened to them
  ("Departed 19:05", "Arriving 21:57", "Landed 21:56", delays)
- a status line: "Sep 4 · Departed 19:05 · arriving 21:57 · on time"
- a rail between the airports with the aircraft's progress: by position
  when one is known, by the clock (real departure → ETA) when nobody can
  see the aircraft, marked "estimated"
- a globe card: the Earth seen from above the route (orthographic
  projection, zoomed to the route), with continents, a graticule, the
  great-circle track, the path already flown drawn solid, and the aircraft
  at its live position pointing along its heading
- altitude, ground speed, heading, distance to go, and the ETA
- how fresh the position is, and a warning when the aircraft is not on the
  leg listed for that flight number

The tracked flight is stored in `~/.config/omarchy/shell.json`, so it
survives shell restarts. Clear it with the ✕ next to the field.

## Bar icon

| Click  | Action                                   |
|--------|------------------------------------------|
| Left   | Open / close the popup                   |
| Middle | Open the popup with the field focused    |
| Right  | Refresh the position now                 |

The icon is dimmed while nothing is tracked. While the flight is in the
air the percentage of the trip done sits next to it (horizontal bars).

## Keyboard (popup open)

| Key         | Action                     |
|-------------|----------------------------|
| Enter, `/`  | Focus the flight field     |
| `r`         | Refresh                    |
| Esc         | Leave the field / close    |
| Tab         | Switch to the next panel   |

## IPC

```bash
omarchy-shell flight.monitor toggle
omarchy-shell flight.monitor edit             # open with the field focused
omarchy-shell flight.monitor track LA3195     # start tracking a flight
omarchy-shell flight.monitor clear
omarchy-shell flight.monitor refresh
```

## Settings (inline in the bar layout entry)

| Key              | Default | Meaning                                  |
|------------------|---------|------------------------------------------|
| `flight`         | `""`    | Flight number being tracked              |
| `refreshSeconds` | `60`    | Background poll interval (15–600). While the popup is open it polls every 15 s. |

## Data sources

All public, none needs an API key:

- [Flightradar24](https://www.flightradar24.com/) (unofficial endpoints,
  fetched with a browser user agent) gives the schedule: scheduled,
  estimated and actual times, status, the aircraft's hex and registration,
  the airports with coordinates and time zones, and, as a fallback for the
  position, the path flown so far. The list mixes future and past dates;
  the panel picks the instance that is live, else the next one still to
  arrive, else the most recent landed one.
- [adsb.lol](https://api.adsb.lol/) provides the live ADS-B position,
  altitude, speed and track, looked up by hex first and then by callsign.
- [adsbdb.com](https://www.adsbdb.com/) supplies the airline name, and the
  route when Flightradar24 does not answer.

A flight number is an IATA code (`LA3195`) while the aircraft broadcasts an
ICAO callsign (`TAM3195`). Airline groups use several callsign prefixes for
one IATA code, so the callsign lookup walks a short candidate list (see
`CALLSIGN_PREFIXES` in `Model.js`) and remembers whichever answered.

## Files

- `BarWidget.qml` — the bar icon and IPC target; hosts the panel
- `Panel.qml` — the popup, fetching and all rendering
- `Model.js` — Qt-free parsing, great-circle math, the globe projection and
  formatting (`node -e 'require("./Model.js")'` works for quick checks)
- `World.js` — land outlines for the globe: Natural Earth 1:110m land
  (public domain), outer rings simplified to ~2,000 points. Regenerate by
  fetching `ne_110m_land.geojson` from github.com/nvkelso/natural-earth-vector
  and running Douglas-Peucker at 0.35° on each outer ring

## License

MIT, see `LICENSE`. Land outlines in `World.js` are derived from Natural
Earth, which is in the public domain.
