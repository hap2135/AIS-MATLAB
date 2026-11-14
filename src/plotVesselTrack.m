function track = plotVesselTrack(jsonFile, mmsi, options)
%plotVesselTrack Map one vessel's AIS messages and how often they arrived.
%   plotVesselTrack(JSONFILE, MMSI) reads a log written by aisReceive and
%   shows one figure with five views of that vessel's position reports:
%     - the track on a basemap, one dot per message, coloured by time, with
%       speed labelled once a minute and dotted lines where nothing was
%       heard for GapThreshold seconds
%     - seconds between consecutive messages (log scale) against the
%       10 s ITU-R M.1371 Class A reporting interval
%     - speed over ground reported in each message
%     - signal-to-noise ratio of each message, with a 2-minute average
%     - messages heard per minute
%   Hover over a dot for its time, message type, channel, speed and SNR.
%
%   TRACK = plotVesselTrack(...) returns the messages as a timetable.
%
%   Options:
%     GapThreshold   Seconds of silence drawn as a gap (default 30)
%     TimeZone       Time zone for the axes (default 'America/New_York')
%     ExportFile     Also save the figure, e.g. 'track.png' (default '')
%
%   Example:
%     plotVesselTrack('logs\ais_20261030_104912.jsonl', 367313240, ...
%         ExportFile='logs\track_367313240.png');

arguments
    jsonFile (1,:) char {mustBeFile}
    mmsi (1,1) double
    options.GapThreshold (1,1) double {mustBePositive} = 30
    options.TimeZone (1,:) char = 'America/New_York'
    options.ExportFile (1,:) char = ''
end

track = readTrack(jsonFile, mmsi, options.TimeZone);
if isempty(track)
    error('plotVesselTrack:noMessages', 'No position reports from %d in %s.', mmsi, jsonFile);
end
elapsedMin = minutes(track.Time - track.Time(1));
isGap = track.gap >= options.GapThreshold;
zoneText = char(track.Time(1), 'zzz');

fig = figure('Name', sprintf('AIS track %d', mmsi), 'Color', 'w', 'Position', [80 40 1400 1000]);
theme(fig, 'light');
layout = tiledlayout(fig, 4, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, sprintf('MMSI %d: %d messages heard, %s to %s %s', mmsi, height(track), ...
    char(track.Time(1), 'HH:mm:ss'), char(track.Time(end), 'HH:mm:ss'), zoneText), ...
    'FontWeight', 'bold');
subtitle(layout, sprintf(['Median %.1f s between messages, longest silence %.0f s. ' ...
    'Counts are a lower bound: only messages this receiver decoded.'], ...
    median(track.gap, 'omitnan'), max(track.gap)));

% Track on the map
gx = geoaxes(layout);
gx.Layout.Tile = 1;
gx.Layout.TileSpan = [4 1];
try
    geobasemap(gx, 'streets-light');
catch
    geobasemap(gx, 'darkwater');                    % offline fallback
end
hold(gx, 'on');
for k = 2:height(track)
    segment = track([k-1 k], :);
    if isGap(k)
        geoplot(gx, segment.latitude, segment.longitude, ':', 'Color', [0.45 0.45 0.45], 'LineWidth', 1.5);
    else
        geoplot(gx, segment.latitude, segment.longitude, '-', 'Color', [0.55 0.65 0.8], 'LineWidth', 1.5);
    end
end
for k = find(track.gap >= 90)'
    text(gx, mean(track.latitude(k-1:k)), mean(track.longitude(k-1:k)), ...
        sprintf('  %.0f s silent', track.gap(k)), 'FontSize', 9, 'Color', [0.3 0.3 0.3], ...
        'VerticalAlignment', 'top');
end
dots = geoscatter(gx, track.latitude, track.longitude, 36, elapsedMin, 'filled', ...
    'MarkerEdgeColor', 'w', 'LineWidth', 0.5);
addTips(dots, track, zoneText);
% Speed at the first message of each minute
[~, firstOfMinute] = unique(floor(elapsedMin));
firstOfMinute = firstOfMinute(2:end);               % the start label covers minute 0
keep = true(size(firstOfMinute));
lastLabel = 1;
for k = 1:numel(firstOfMinute)                      % skip labels within ~450 m of the previous one
    j = firstOfMinute(k);
    north = (track.latitude(j) - track.latitude(lastLabel))*111e3;
    east = (track.longitude(j) - track.longitude(lastLabel))*111e3*cosd(track.latitude(j));
    keep(k) = hypot(north, east) > 450;
    if keep(k), lastLabel = j; end
end
firstOfMinute = firstOfMinute(keep);
text(gx, track.latitude(firstOfMinute), track.longitude(firstOfMinute), ...
    compose("%.1f kn  ", track.speed(firstOfMinute)), 'FontSize', 8, ...
    'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'Color', [0.15 0.15 0.15]);
text(gx, track.latitude(1), track.longitude(1), ['  start ' char(track.Time(1), 'HH:mm:ss')], 'FontSize', 9);
text(gx, track.latitude(end), track.longitude(end), ['end ' char(track.Time(end), 'HH:mm:ss') '  '], ...
    'FontSize', 9, 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top');
colormap(gx, parula);
cb = colorbar(gx, 'southoutside');
cb.Label.String = sprintf('Minutes since first message (%s %s)', char(track.Time(1), 'HH:mm'), zoneText);
title(gx, {'Position reported in each message', ...
    'Speed labelled once a minute; dotted: nothing heard for 30 s or more'});

% Seconds between messages
ax = nexttile(layout, 2);
hold(ax, 'on');
gapDots = scatter(ax, track.Time, track.gap, 30, elapsedMin, 'filled', 'MarkerEdgeColor', 'w');
addTips(gapDots, track, zoneText);
colormap(ax, parula);
yline(ax, 10, '--', '10 s: Class A at 0-14 kn, holding course', 'Color', [0.85 0.33 0.1], ...
    'LineWidth', 1.5, 'LabelHorizontalAlignment', 'right', 'LabelVerticalAlignment', 'bottom');
ax.YScale = 'log';
ax.YLim = [0.3 400];
ax.YTick = [1 3 10 30 100 300];
ylabel(ax, 'Seconds since previous');
grid(ax, 'on');
title(ax, 'Seconds between messages');

% Speed over ground reported in each message
sx = nexttile(layout, 4);
hold(sx, 'on');
plot(sx, track.Time, track.speed, '-', 'Color', [0.75 0.75 0.75]);
speedDots = scatter(sx, track.Time, track.speed, 30, elapsedMin, 'filled', 'MarkerEdgeColor', 'w');
addTips(speedDots, track, zoneText);
colormap(sx, parula);
ylim(sx, [0 max(track.speed)*1.15 + 0.5]);
ylabel(sx, 'Speed (kn)');
grid(sx, 'on');
title(sx, 'Speed over ground reported in each message');

% Signal-to-noise ratio of each decoded message
nx = nexttile(layout, 6);
hold(nx, 'on');
snrDots = scatter(nx, track.Time, track.snrDb, 30, elapsedMin, 'filled', 'MarkerEdgeColor', 'w');
addTips(snrDots, track, zoneText);
colormap(nx, parula);
plot(nx, track.Time, movmean(track.snrDb, minutes(2), 'SamplePoints', track.Time), ...
    'Color', [0.2 0.2 0.2], 'LineWidth', 2);
yline(nx, min(track.snrDb), ':', sprintf('weakest decoded: %.1f dB', min(track.snrDb)), ...
    'Color', [0.85 0.33 0.1], 'LineWidth', 1.5, 'LabelHorizontalAlignment', 'right', ...
    'LabelVerticalAlignment', 'bottom');
ylim(nx, [0 max(track.snrDb) + 5]);
ylabel(nx, 'SNR (dB)');
grid(nx, 'on');
title(nx, 'Signal-to-noise ratio of each message (line: 2-minute average)');

% Messages per minute
bx = nexttile(layout, 8);
edges = track.Time(1) + minutes(0:ceil(minutes(track.Time(end) - track.Time(1)) + eps));
counts = histcounts(track.Time, edges);
b = bar(bx, edges(1:end-1) + seconds(30), counts, 1, 'FaceColor', [0.16 0.47 0.84], 'EdgeColor', 'w');
b.Labels = string(counts);
ylabel(bx, 'Messages');
xlabel(bx, zoneText);
grid(bx, 'on');
title(bx, 'Messages heard per minute');
linkaxes([ax sx nx bx], 'x');

if ~isempty(options.ExportFile)
    exportgraphics(fig, options.ExportFile, 'Resolution', 200);
    fprintf('Saved %s\n', options.ExportFile);
end
end

function track = readTrack(jsonFile, mmsi, timeZone)
% Position reports from one MMSI, sorted by time, with the gap before each.
positionTypes = [1 2 3 18 19 27];
lines = readlines(jsonFile, 'EmptyLineRule', 'skip');
rows = cell(numel(lines), 1);
for k = 1:numel(lines)
    r = jsondecode(lines(k));
    m = r.message;
    if m.mmsi ~= mmsi || ~ismember(m.type, positionTypes) || isnan(m.latitude)
        continue
    end
    rows{k} = {datetime(r.time, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'TimeZone', 'UTC'), ...
        m.type, string(r.channel), m.latitude, m.longitude, field(m, 'speedOverGround'), ...
        field(m, 'courseOverGround'), field(m, 'trueHeading'), r.snrDb};
end
rows = vertcat(rows{:});
if isempty(rows)
    track = timetable();
    return
end
track = cell2table(rows, 'VariableNames', {'Time', 'type', 'channel', 'latitude', 'longitude', ...
    'speed', 'course', 'heading', 'snrDb'});
track = sortrows(table2timetable(track), 'Time');
track.Time.TimeZone = timeZone;
track.gap = [NaN; seconds(diff(track.Time))];
end

function value = field(msg, name)
value = NaN;
if isfield(msg, name) && isnumeric(msg.(name)) && isscalar(msg.(name))
    value = msg.(name);
end
end

function addTips(h, track, zoneText)
rows = h.DataTipTemplate.DataTipRows;
h.DataTipTemplate.DataTipRows = [
    dataTipTextRow(['Time ' zoneText], string(track.Time, 'HH:mm:ss.SSS'))
    dataTipTextRow('Type', track.type)
    dataTipTextRow('Channel', track.channel)
    dataTipTextRow('Speed (kn)', track.speed)
    dataTipTextRow('Course', track.course)
    dataTipTextRow('SNR (dB)', track.snrDb)
    dataTipTextRow('Gap (s)', track.gap)
    rows(1:min(2, end))];
end
