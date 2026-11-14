function vessels = aisReceive(options)
%aisReceive Receive and decode all AIS traffic with an RTL-SDR (NESDR SMArt v5).
%   aisReceive() listens to both AIS channels at once (A = 161.975 MHz,
%   B = 162.025 MHz), decodes every message type, shows a live map and
%   vessel table, and logs everything. Close the map window to stop.
%
%   VESSELS = aisReceive(Name=Value) returns a table with the latest known
%   state of every station heard.
%
%   Options:
%     Duration             Seconds of radio time to run (default Inf)
%     RadioAddress         RTL-SDR address (default '0')
%     Gain                 'auto' or tuner gain in dB (default 32.8, best for the
%                          AIS antenna in the 2026-10-31 aisGainSweep; AGC overloads)
%     FrequencyCorrection  Tuner correction in ppm (default 0)
%     InputFile            Baseband .bb file to decode instead of the radio
%     OutputFolder         Where logs go (default <project>\logs)
%     ShowMap              Live map and vessel table (default true)
%     Verbose              Print each decoded message (default true)
%     Watchlist            CSV (or table) with columns Operator, Name, MMSI, Status.
%                          Announces each listed vessel the first time it is heard,
%                          flags broadcast names that differ from the list, counts
%                          watched vessels in the status line and rings them in red
%                          on the map (default '' = no watchlist)
%
%   Files written to OutputFolder for each run:
%     ais_<time>.nmea      Raw !AIVDM sentences, readable by any AIS tool
%     ais_<time>.jsonl     Every decoded message with all fields, one per line
%     vessels_<time>.csv   Latest state of each station heard
%
%   Example:
%     aisReceive                               % run until the map is closed
%     v = aisReceive(Duration=600, ShowMap=false);

arguments
    options.Duration (1,1) double {mustBePositive} = Inf
    options.RadioAddress (1,:) char = '0'
    options.Gain = 32.8
    options.FrequencyCorrection (1,1) double = 0
    options.InputFile (1,:) char = ''
    options.OutputFolder (1,:) char = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'logs')
    options.ShowMap (1,1) logical = true
    options.Verbose (1,1) logical = true
    options.Watchlist = ''
end

watch = loadWatchlist(options.Watchlist);
watchHeard = containers.Map('KeyType', 'double', 'ValueType', 'logical');
watchNameChecked = containers.Map('KeyType', 'double', 'ValueType', 'logical');

symbolRate = 9600;
sps = 5;                                            % samples per symbol per channel
fsChan = symbolRate*sps;
channelFreqs = [161.975e6 162.025e6];
channelNames = ['A' 'B'];
keepLen = 1300*sps;                                 % longest packet, in channel samples

% Signal source
isFile = ~isempty(options.InputFile);
if isFile
    src = comm.BasebandFileReader(options.InputFile);
    fsIn = src.SampleRate;
    fc = src.CenterFrequency;
else
    fsIn = 288e3;                                   % covers both channels
    fc = 162.0e6;
    src = comm.SDRRTLReceiver(options.RadioAddress, ...
        'CenterFrequency', fc, ...
        'SampleRate', fsIn, ...
        'OutputDataType', 'single', ...
        'FrequencyCorrection', options.FrequencyCorrection);
    if isnumeric(options.Gain)
        src.EnableTunerAGC = false;
        src.TunerGain = options.Gain;
    else
        src.EnableTunerAGC = true;
    end
end
[L, M] = rat(fsChan/fsIn);
frameLen = M*round(0.5*fsIn/M);                     % ~0.5 s, multiple of M
src.SamplesPerFrame = frameLen;
cleanupSource = onCleanup(@() release(src));

% One demodulator per AIS channel within the captured bandwidth
chanFilter = fir1(48, 9e3/(fsChan/2));
ch = struct('name', {}, 'offset', {}, 'resampler', {}, 'filter', {}, ...
    'lastSample', {}, 'disc', {}, 'power', {}, 'bufStart', {}, ...
    'packets', {}, 'noiseDb', {});
for k = 1:numel(channelFreqs)
    offset = channelFreqs(k) - fc;
    if abs(offset) > fsIn/2 - 12.5e3
        warning('aisReceive:channelOutOfBand', ...
            'Channel %s is outside the input bandwidth and will be skipped.', channelNames(k));
        continue
    end
    ch(end+1) = struct('name', channelNames(k), 'offset', offset, ...
        'resampler', dsp.FIRRateConverter(L, M), ...
        'filter', dsp.FIRFilter('Numerator', chanFilter), ...
        'lastSample', complex(0), 'disc', zeros(0, 1), 'power', zeros(0, 1), ...
        'bufStart', 1, 'packets', 0, 'noiseDb', NaN); %#ok<AGROW>
end

% Log files
if ~isfolder(options.OutputFolder)
    mkdir(options.OutputFolder);
end
stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
nmeaFile = fullfile(options.OutputFolder, ['ais_' stamp '.nmea']);
jsonFile = fullfile(options.OutputFolder, ['ais_' stamp '.jsonl']);
csvFile = fullfile(options.OutputFolder, ['vessels_' stamp '.csv']);
nmeaFid = fopen(nmeaFile, 'w');
jsonFid = fopen(jsonFile, 'w');
cleanupFiles = onCleanup(@() fclose('all'));

db = containers.Map('KeyType', 'double', 'ValueType', 'any');
recent = containers.Map('KeyType', 'char', 'ValueType', 'double');
view = [];
if options.ShowMap
    view = createView();
end

fprintf('AIS receiver: %s, channels %s, logging to %s\n', ...
    sourceText(isFile, options), strjoin(cellstr([ch.name]'), '+'), options.OutputFolder);
startTime = datetime('now', 'TimeZone', 'UTC');
inCount = 0;
lostFrames = 0;
sequenceId = 0;
nextStatus = 10;
nextView = 0;

while inCount/fsIn < options.Duration
    if isFile
        if isDone(src), break; end
        x = src();
        lost = 0;
    else
        [x, ~, lost] = src();
    end
    lostFrames = lostFrames + double(lost > 0);
    x = double(x);
    n = inCount + (0:numel(x) - 1)';
    inCount = inCount + numel(x);
    frameEnd = startTime + seconds(inCount/fsIn);
    if ~isFile
        frameEnd = datetime('now', 'TimeZone', 'UTC');
    end

    for k = 1:numel(ch)
        lo = exp(-2j*pi*mod(ch(k).offset*n/fsIn, 1));
        y = ch(k).filter(ch(k).resampler(x .* lo));
        prev = [ch(k).lastSample; y(1:end-1)];
        ch(k).lastSample = y(end);
        ch(k).disc = [ch(k).disc; angle(y .* conj(prev))];
        ch(k).power = [ch(k).power; abs(y).^2];
        ch(k).noiseDb = 10*log10(median(abs(y).^2) + eps);

        bufEndAbs = ch(k).bufStart + numel(ch(k).disc) - 1;
        for p = aisDetectPackets(ch(k).disc, sps)
            absSample = ch(k).bufStart + p.startSample - 1;
            key = [ch(k).name char('0' + p.bits)];
            tPacket = absSample/fsChan;
            if isKey(recent, key) && abs(recent(key) - tPacket) < 1
                continue                            % seen in the previous overlap
            end
            recent(key) = tPacket;
            ch(k).packets = ch(k).packets + 1;

            span = p.startSample:min(p.endSample, numel(ch(k).power));
            level = 10*log10(mean(ch(k).power(span)) + eps);
            when = frameEnd - seconds((bufEndAbs - absSample)/fsChan);

            msg = aisDecodeMessage(p.bits);
            sentences = aisToNmea(p.bits, ch(k).name, sequenceId);
            if numel(sentences) > 1
                sequenceId = mod(sequenceId + 1, 10);
            end
            fprintf(nmeaFid, '%s\n', sentences{:});
            record = struct('time', char(when, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''), ...
                'channel', ch(k).name, 'signalLevelDb', round(level, 1), ...
                'snrDb', round(level - ch(k).noiseDb, 1), ...
                'nmea', {sentences}, 'message', msg);
            fprintf(jsonFid, '%s\n', jsonencode(record));
            updateVessel(db, msg, when, level);
            checkWatchlist(watch, watchHeard, watchNameChecked, msg, db, when, ...
                ch(k).name, level - ch(k).noiseDb);
            if options.Verbose
                fprintf('%s %s %5.1f dB  %s\n', char(when, 'HH:mm:ss'), ch(k).name, ...
                    level - ch(k).noiseDb, summarize(msg, db));
            end
        end

        if numel(ch(k).disc) > keepLen
            drop = numel(ch(k).disc) - keepLen;
            ch(k).disc(1:drop) = [];
            ch(k).power(1:drop) = [];
            ch(k).bufStart = ch(k).bufStart + drop;
        end
    end

    % Forget duplicates older than a few seconds
    if recent.Count > 500
        keys = recent.keys;
        old = cellfun(@(c) recent(c) < inCount/fsIn - 5, keys);
        remove(recent, keys(old));
    end

    elapsed = inCount/fsIn;
    if elapsed >= nextStatus
        nextStatus = nextStatus + 30;
        watchText = '';
        if ~isempty(watch)
            watchText = sprintf(' | watchlist %d/%d', watchHeard.Count, nnz(watch.MMSI > 0));
        end
        fprintf('-- %4.0f s: %s | stations %d%s | lost frames %d\n', elapsed, ...
            strjoin(arrayfun(@(c) sprintf('ch %s %d pkts (noise %.1f dB)', ...
            c.name, c.packets, c.noiseDb), ch, 'UniformOutput', false), ', '), ...
            db.Count, watchText, lostFrames);
        flushLogs(nmeaFid, jsonFid);
    end
    if ~isempty(view)
        if ~isvalid(view.figure)
            break                                   % user closed the window
        end
        if elapsed >= nextView
            nextView = elapsed + 2;
            refreshView(view, db, watch);
        end
    end
end

if ~isempty(view) && isvalid(view.figure)
    refreshView(view, db, watch);
end
vessels = vesselTable(db);
if ~isempty(vessels)
    writetable(vessels, csvFile);
end
fprintf('Done: %.0f s, %d packets, %d stations.\n  %s\n  %s\n', inCount/fsIn, ...
    sum([ch.packets]), db.Count, nmeaFile, jsonFile);
if ~isempty(vessels)
    fprintf('  %s\n', csvFile);
end
if ~isempty(watch)
    fprintf('Watchlist: heard %d of %d listed vessels with an MMSI.\n', ...
        watchHeard.Count, nnz(watch.MMSI > 0));
end
end

%% Watchlist

function watch = loadWatchlist(source)
watch = table();
if istable(source)
    watch = source;
elseif strlength(string(source)) > 0
    watch = readtable(source, 'TextType', 'string', 'Delimiter', ',');
end
if isempty(watch), return; end
watch.MMSI = double(watch.MMSI);
watch.MMSI(isnan(watch.MMSI)) = 0;
end

function checkWatchlist(watch, heard, nameChecked, msg, db, when, channel, snr)
if isempty(watch), return; end
row = find(watch.MMSI == msg.mmsi, 1);
if isempty(row), return; end
w = watch(row, :);
if ~isKey(heard, msg.mmsi)
    heard(msg.mmsi) = true;
    fprintf('** WATCH %s  first heard: %s / %s (%d, list status %s), ch %s, SNR %.1f dB\n', ...
        char(when, 'HH:mm:ss'), w.Operator, w.Name, msg.mmsi, w.Status, channel, snr);
end
v = db(msg.mmsi);
if v.name ~= "" && ~isKey(nameChecked, msg.mmsi)
    nameChecked(msg.mmsi) = true;
    if aisNamesMatch(v.name, w.Name)
        fprintf('** WATCH %s  name confirmed: %d broadcasts "%s"\n', ...
            char(when, 'HH:mm:ss'), msg.mmsi, v.name);
    else
        fprintf('** WATCH %s  NAME MISMATCH: %d broadcasts "%s", list says "%s"\n', ...
            char(when, 'HH:mm:ss'), msg.mmsi, v.name, w.Name);
    end
end
end


%% Vessel database

function v = newVessel(mmsi)
v = struct('mmsi', mmsi, 'name', "", 'callsign', "", 'imo', NaN, ...
    'category', "", 'shipType', "", 'length', NaN, 'beam', NaN, ...
    'draught', NaN, 'destination', "", 'eta', "", 'navStatus', "", ...
    'latitude', NaN, 'longitude', NaN, 'speed', NaN, 'course', NaN, ...
    'heading', NaN, 'lastSeen', NaT('TimeZone', 'UTC'), 'messages', 0, ...
    'signalLevelDb', NaN);
end

function updateVessel(db, msg, when, level)
if isKey(db, msg.mmsi)
    v = db(msg.mmsi);
else
    v = newVessel(msg.mmsi);
end
v.messages = v.messages + 1;
v.lastSeen = when;
v.signalLevelDb = round(level, 1);

switch msg.type
    case {1, 2, 3}
        v.category = "Class A";
    case 18
        v.category = "Class B";
    case 19
        v.category = "Class B";
    case 4
        v.category = "Base station";
    case 9
        v.category = "SAR aircraft";
    case 21
        v.category = "Aid to navigation";
    case 24
        if v.category == "", v.category = "Class B"; end
    case 5
        if v.category == "", v.category = "Class A"; end
end

if isfield(msg, 'latitude') && isfield(msg, 'longitude') && ...
        ~isnan(msg.latitude) && ~isnan(msg.longitude) && ~ismember(msg.type, [17 22 23])
    v.latitude = msg.latitude;
    v.longitude = msg.longitude;
end
v = copyIfPresent(v, msg, 'speedOverGround', 'speed');
v = copyIfPresent(v, msg, 'courseOverGround', 'course');
v = copyIfPresent(v, msg, 'trueHeading', 'heading');
v = copyIfPresent(v, msg, 'navStatusText', 'navStatus');
v = copyIfPresent(v, msg, 'shipName', 'name');
v = copyIfPresent(v, msg, 'name', 'name');
v = copyIfPresent(v, msg, 'callsign', 'callsign');
v = copyIfPresent(v, msg, 'shipTypeText', 'shipType');
v = copyIfPresent(v, msg, 'aidTypeText', 'shipType');
v = copyIfPresent(v, msg, 'destination', 'destination');
v = copyIfPresent(v, msg, 'etaText', 'eta');
if isfield(msg, 'imo') && msg.imo > 0, v.imo = msg.imo; end
if isfield(msg, 'length') && msg.length > 0, v.length = msg.length; end
if isfield(msg, 'beam') && msg.beam > 0, v.beam = msg.beam; end
if isfield(msg, 'draught') && msg.draught > 0, v.draught = msg.draught; end
db(msg.mmsi) = v;
end

function v = copyIfPresent(v, msg, from, to)
if ~isfield(msg, from), return; end
value = msg.(from);
if (ischar(value) || isstring(value)) && strlength(value) > 0
    v.(to) = string(value);
elseif isnumeric(value) && ~isnan(value)
    v.(to) = value;
end
end

function t = vesselTable(db)
t = table();
if db.Count == 0, return; end
t = struct2table(cell2mat(db.values'));
t = sortrows(t, 'lastSeen', 'descend');
end

function str = summarize(msg, db)
v = db(msg.mmsi);
who = sprintf('%9d', msg.mmsi);
if v.name ~= ""
    who = sprintf('%s %-20s', who, v.name);
end
str = sprintf('T%-2d %s %s', msg.type, who, msg.typeName);
if isfield(msg, 'latitude') && ~isnan(msg.latitude) && ~ismember(msg.type, [17 22 23])
    str = sprintf('%s  %.5f, %.5f', str, msg.latitude, msg.longitude);
end
if isfield(msg, 'speedOverGround') && ~isnan(msg.speedOverGround)
    str = sprintf('%s  %.1f kn', str, msg.speedOverGround);
end
if isfield(msg, 'destination') && ~isempty(msg.destination)
    str = sprintf('%s  -> %s', str, msg.destination);
end
if isfield(msg, 'text') && ~isempty(msg.text)
    str = sprintf('%s  "%s"', str, msg.text);
end
end

%% Live view

function view = createView()
view.figure = uifigure('Name', 'AIS - NYC Harbor', 'Position', [100 100 1200 650]);
grid = uigridlayout(view.figure, [1 2], 'ColumnWidth', {'1x', '1.2x'});
view.map = geoaxes(grid);
try
    geobasemap(view.map, 'streets-light');
catch
    geobasemap(view.map, 'darkwater');              % offline fallback
end
geolimits(view.map, [40.62 40.84], [-74.10 -73.90]);  % Upper Bay, Hudson, East River
hold(view.map, 'on');
title(view.map, 'Waiting for AIS...');
view.table = uitable(grid, 'ColumnSortable', true);
end

function refreshView(view, db, watch)
if db.Count == 0, return; end
t = vesselTable(db);
cla(view.map);
hasPos = ~isnan(t.latitude);
if any(hasPos)
    tp = t(hasPos, :);
    geoscatter(view.map, tp.latitude, tp.longitude, 40, categorical(tp.category), 'filled');
    if ~isempty(watch)
        isWatched = ismember(tp.mmsi, watch.MMSI(watch.MMSI > 0));
        if any(isWatched)
            geoscatter(view.map, tp.latitude(isWatched), tp.longitude(isWatched), ...
                160, 'r', 'LineWidth', 1.5);
        end
    end
    labels = tp.name;
    labels(labels == "") = string(tp.mmsi(labels == ""));
    text(view.map, tp.latitude, tp.longitude, "  " + labels, 'FontSize', 8);
end
title(view.map, sprintf('%d stations, %d with position (%s UTC)', height(t), ...
    nnz(hasPos), char(datetime('now', 'TimeZone', 'UTC'), 'HH:mm:ss')));
shown = t(:, {'mmsi', 'name', 'category', 'shipType', 'navStatus', 'speed', ...
    'course', 'destination', 'messages', 'signalLevelDb'});
shown.mmsi = uint32(shown.mmsi);
shown.lastSeen = string(t.lastSeen, 'HH:mm:ss');
view.table.Data = shown;
drawnow limitrate
end

function str = sourceText(isFile, options)
if isFile
    str = ['file ' options.InputFile];
else
    str = ['RTL-SDR ' options.RadioAddress];
end
end

function flushLogs(varargin)
% Push buffered log lines to disk so other programs can tail the files.
for fid = [varargin{:}]
    fseek(fid, 0, 'cof');
end
end
