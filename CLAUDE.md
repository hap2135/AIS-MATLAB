# DOT Ferry Automation: AIS receiver

MATLAB tools that receive, decode, log and map AIS (ship position) traffic in New York Harbor
with an RTL-SDR, to compare our own ground-truth reception against what public AIS websites show.

## Working preferences

- Do everything in MATLAB through the MATLAB MCP tools. The user prefers MATLAB figures
  (especially `geoaxes` maps) over Claude artifacts / HTML pages.
- Export figures as PNG into `logs\` and look at the image before reporting.
- Python and Node are not installed. Mapping Toolbox is not installed (no `wgs84Ellipsoid`,
  `distance`); use the haversine formula for distances.
- Call `theme(fig, 'light')` on new figures; MATLAB's dark theme otherwise makes exported
  charts black with grey titles.
- `evaluate_matlab_code` moves to the background after 120 s. For runs longer than that, start
  them and wait for the completion notification instead of polling.
- If MATLAB is closed and reopened, the MCP connection drops; rerun the command.

## Hardware and operating conditions

- Radio: Nooelec NESDR SMArt v5 (RTL2832U + R820T tuner, 28.8 MHz TCXO), address `'0'`.
  Datasheet: `docs/nesdr_smart_rtl_sdr_v5_datasheet_revision_1.pdf`.
- Antenna: AIS-tuned 162 MHz antenna (connected 2026-10-31). The earlier 433 MHz antenna also
  works but reached only ~7 km against ~24 km for the AIS antenna.
- **Tuner gain: 32.8 dB** (now the `aisReceive` default). `aisGainSweep` on 2026-10-31 showed
  28-33.8 dB is the clean range: lowest noise, A/B traffic split ~50/50, every base-station
  message received. At 37 dB and above, and with AGC, the front end overloads: noise rises
  5-10 dB and channel A loses most of its traffic. Rerun the sweep if antenna or site changes.
- Capture: 288 kS/s centred on 162.000 MHz, covering channel A (161.975 MHz) and channel B
  (162.025 MHz) at once.
- Channel A has a persistent noise floor a few dB above B, plus a narrowband spur at
  ~161.971 MHz. Harmless at 32.8 dB; centre-frequency shifting would tell whether it is
  external or generated in the radio.
- Antenna placement matters most. Indoors near laptops, chargers and power strips the noise
  floor rose ~10 dB and nothing was decoded (2026-11-01). Healthy noise floor at 32.8 dB is
  about -52 to -56 dB on both channels in the `aisReceive` status lines.
- Reference station: shore base station MMSI 003669982 at 40.78897 N, 73.92980 W (Astoria /
  Hell Gate). It sends a Type 20 + Type 4 pair on both channels every 20 s, so it is a fixed
  benchmark for SNR comparisons. Its reported UTC date is wrong (2007-03-16, exactly 1024
  weeks ago: a GPS week-rollover bug in that station), so never use it as a clock.

## Tools

Layout: code in `src/`, tests in `tests/`, watchlist in `data/`, datasheet and README images in
`docs/`, recordings in `logs/`. Run `setup` from the project root first to add
`src/` and `tests/` to the path. Default output (`logs/`) and watchlist paths resolve from the
project root, not from `src/`.

### aisReceive.m: receive and log

```matlab
aisReceive                                         % run until the map window is closed
v = aisReceive(Duration=120, ShowMap=false, Verbose=false);
v = aisReceive(InputFile='capture.bb');            % decode a recorded baseband file
```

Options: `Duration` (s, default Inf), `RadioAddress` ('0'), `Gain` (32.8 dB or 'auto'),
`FrequencyCorrection` (ppm, 0), `InputFile`, `OutputFolder` (`logs\`), `ShowMap` (true),
`Verbose` (true). Returns a table with the latest state of each station.

Prints a status line every 30 s: packets and noise floor per channel, stations, lost frames.
Writes three files per run to `logs\`:
- `ais_<yyyyMMdd_HHmmss>.nmea`: raw `!AIVDM` sentences for any AIS tool (OpenCPN, pyais...).
- `ais_<stamp>.jsonl`: one decoded message per line: `time` (UTC ISO), `channel`,
  `signalLevelDb`, `snrDb`, `nmea`, and `message` (all fields from `aisDecodeMessage`).
- `vessels_<stamp>.csv`: latest state of each station.

The file stamp is local time; the `time` field inside the jsonl is UTC.

### plotVesselTrack.m: one vessel over time

```matlab
track = plotVesselTrack('logs\ais_20261030_104912.jsonl', 367313240, ...
    ExportFile='logs\track_367313240.png');
```

One figure, five views: track on a basemap coloured by time (speed labelled about once a
minute, dotted lines for silences of `GapThreshold` s, default 30); seconds between messages
(log scale, with the 10 s Class A reporting interval); speed over ground; SNR per message with a
2-minute moving average and the weakest decoded level; messages per minute. Datatips show
time, type, channel, speed, course, SNR and gap. Options: `GapThreshold`, `TimeZone`
(default 'America/New_York'), `ExportFile`. Returns a timetable of the vessel's position reports.

### plotAisMap.m: every station in a run

```matlab
plotAisMap('logs\ais_20261031_120822.jsonl', ExportFile='logs\map_20261031_120822.png');
```

Track and last position of each station, coloured by category (Class A, Class B, base station,
AtoN, SAR), labelled with name or MMSI. Errors clearly if the log has no position reports.

### aisGainSweep.m: find the best tuner gain

```matlab
r = aisGainSweep();                                % 7 gains + AGC, 60 s each (~8 min)
r = aisGainSweep(Gains={28 33.8 37.2}, Duration=90);
```

Per gain: noise floor A/B, reference-station SNR A/B and count, messages A/B, share on A,
stations, median ship SNR, farthest ship from the reference station. Saves per-setting logs and
`gainsweep.csv` under `logs\gainsweep_<stamp>\`. Choose the gain with the lowest noise, a ~50%
A share and a full reference count; rising noise with a falling A share means overload.

### Ferry watchlist: aisReceive Watchlist option + aisWatchReport.m

`data/ferry_watchlist.csv` (Operator, Name, MMSI, Status) holds 79 vessels of Seastreak, NYC Ferry,
NY Water Taxi/Circle Line and NY Waterway, from `Operator Vessels.xlsx` (2026-11-06). Status
comes from the sheet's cell colours: `seen` (already in our recordings), `confident` (public
sites), `candidate` (doubtful MMSI), `none` (no MMSI; MMSI column NaN).

```matlab
aisReceive(Watchlist="data/ferry_watchlist.csv");       % live: alerts on first hearing + name check
r = aisWatchReport('logs\ais_20261106_*.jsonl', ExportFile='logs\watch_20261106.png', ...
    CsvFile='logs\watch_20261106.csv');
```

`aisWatchReport` gives one row per listed vessel (heard, messages, first/last heard, median
SNR, last position, broadcast name vs list name), and lists "name hits": stations broadcasting
a listed name under a different MMSI (how `none`/`candidate` vessels get resolved).
`aisNamesMatch` compares names allowing AIS abbreviations ("ADM", "GOV") and the 20-character
truncation. Names only arrive in Type 5/24 messages (every 6 min), so run at least 15 min.

### Decoder building blocks

- `aisDetectPackets(disc, sps)`: finds CRC-valid HDLC frames in an FM discriminator signal
  (NRZI, bit unstuffing, CRC-16).
- `aisDecodeMessage(bits)`: decodes all 27 ITU-R M.1371 message types into a struct. Missing
  values are NaN or "". Binary payloads (types 6, 8, 17, 25, 26) come back as hex.
- `aisNmeaToBits(sentences)`: `!AIVDM` sentences to bits, checking checksums. Use it to decode
  logs from other receivers or websites.
- `aisToNmea(bits, channel, sequenceId)`: bits to `!AIVDM` sentences.

### Tests

```matlab
setup; runtests('testAis')
```

Covers position and static/voyage decoding against gpsd reference sentences, the NMEA round
trip, a synthetic two-channel radio capture through `aisReceive`, and (if downloaded) the
MathWorks `ShipTrackingUsingAISSignalsExample` over-the-air capture. Run it after changing any
decoder file.

## Interpreting results

- Message counts are a lower bound: only what this receiver decoded. Gaps in a vessel's
  messages while its reported position keeps advancing are reception gaps, not the ship
  going silent.
- Class A reporting interval (ITU-R M.1371): 10 s at 0-14 kn holding course, 3.3 s when
  changing course, 6 s at 14-23 kn, 2 s above 23 kn. Type 3 reports are sent on a schedule
  set by a shore station or in reply to a poll, often faster than the default.
- Static/voyage data (Type 5: name, size, destination) is sent only every 6 minutes and is twice
  as long as a position report, so short runs often have MMSIs without names.
- Status, ETA and destination fields are often stale; trust position, speed and course.
- SNR on a weak link is biased upward: missed messages were weaker than the weakest decoded one.

## Reference results

- 2026-10-30, 433 MHz antenna, 49.6 dB, 20 min: 8 stations, 440 messages, farthest ship ~7 km
  from the reference. MMSI 367313240 through Hell Gate: 87 messages, median 4.3 s apart, SNR
  falling from ~23 to ~17 dB as messages thinned (`logs\track_367313240.png`).
- 2026-10-31, AIS antenna, 32.8 dB, 2 min: 30 stations, 110 messages/min, 47% on channel A,
  reference SNR 41-42 dB, ships up to ~24 km (Kill Van Kull, George Washington Bridge).
- 2026-11-01, new site further south: indoors near electronics, 0 packets; after moving the
  antenna, 7 stations on the lower Hudson in 2 min (Sunday evening).
