function plotAisMap(jsonFile, options)
%plotAisMap Map every station heard in an aisReceive log.
%   plotAisMap(JSONFILE) draws each station's track and last position on a
%   basemap, coloured by category and labelled with its name or MMSI.
%   Hover over a last-position marker for its details.
%
%   Options:
%     ExportFile   Also save the figure, e.g. 'map.png' (default '')
%
%   Example:
%     plotAisMap('logs\ais_20261031_120822.jsonl', ExportFile='logs\map.png');

arguments
    jsonFile (1,:) char {mustBeFile}
    options.ExportFile (1,:) char = ''
end

lines = readlines(jsonFile, 'EmptyLineRule', 'skip');
recs = cellfun(@jsondecode, cellstr(lines), 'UniformOutput', false);
noPosition = [5 17 20 22 23 24];                    % messages without a vessel position
rows = cell(numel(recs), 1);
names = containers.Map('KeyType', 'double', 'ValueType', 'char');
for k = 1:numel(recs)
    m = recs{k}.message;
    for f = ["shipName" "name"]
        if isfield(m, f) && ~isempty(m.(f)), names(m.mmsi) = m.(f); end
    end
    if ismember(m.type, noPosition) || isnan(field(m, 'latitude')) || isnan(field(m, 'longitude'))
        continue                                    % no position (JSON null decodes as [])
    end
    rows{k} = {datetime(recs{k}.time, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'TimeZone', 'UTC'), ...
        m.mmsi, m.type, m.latitude, m.longitude, field(m, 'speedOverGround'), recs{k}.snrDb};
end
rows = vertcat(rows{:});
if isempty(rows)
    error('plotAisMap:noPositions', 'No position reports in %s.', jsonFile);
end
pos = cell2table(rows, 'VariableNames', ...
    {'time', 'mmsi', 'type', 'latitude', 'longitude', 'speed', 'snrDb'});
pos = sortrows(pos, 'time');

categories = ["Class A" "Class B" "Base station" "Aid to navigation" "SAR aircraft"];
colors = [0.16 0.47 0.84; 0.92 0.41 0.20; 0.20 0.20 0.20; 0.11 0.69 0.48; 0.89 0.29 0.28];

fig = figure('Name', 'AIS stations', 'Color', 'w', 'Position', [100 60 1100 950]);
theme(fig, 'light');
gx = geoaxes(fig);
try
    geobasemap(gx, 'streets-light');
catch
    geobasemap(gx, 'darkwater');                    % offline fallback
end
hold(gx, 'on');

ids = unique(pos.mmsi);
last = table();
for k = 1:numel(ids)
    p = pos(pos.mmsi == ids(k), :);
    c = find(categories == category(p.type(end)));
    if height(p) > 1
        geoplot(gx, p.latitude, p.longitude, '-', 'Color', [colors(c, :) 0.6], 'LineWidth', 1.5);
    end
    label = string(ids(k));
    if isKey(names, ids(k)), label = string(names(ids(k))); end
    last = [last; table(ids(k), label, categories(c), p.latitude(end), p.longitude(end), ...
        p.speed(end), height(p), max(p.snrDb), 'VariableNames', ...
        {'mmsi', 'label', 'category', 'latitude', 'longitude', 'speed', 'messages', 'snrDb'})]; %#ok<AGROW>
end

handles = gobjects(0);
for c = 1:numel(categories)
    s = last(last.category == categories(c), :);
    if isempty(s), continue; end
    h = geoscatter(gx, s.latitude, s.longitude, 60, colors(c, :), 'filled', ...
        'MarkerEdgeColor', 'w', 'LineWidth', 1, 'DisplayName', sprintf('%s (%d)', categories(c), height(s)));
    h.DataTipTemplate.DataTipRows = [
        dataTipTextRow('Station', s.label)
        dataTipTextRow('MMSI', compose('%09d', s.mmsi))
        dataTipTextRow('Speed (kn)', s.speed)
        dataTipTextRow('Messages', s.messages)
        dataTipTextRow('Best SNR (dB)', s.snrDb)];
    handles(end+1) = h; %#ok<AGROW>
end
text(gx, last.latitude, last.longitude, "  " + last.label, 'FontSize', 8, 'Color', [0.15 0.15 0.15]);
legend(gx, handles, 'Location', 'northwest');

t = pos.time.TimeZone;
pos.time.TimeZone = 'America/New_York';
title(gx, sprintf('%d stations heard, %s to %s %s', numel(ids), char(pos.time(1), 'MMM d HH:mm'), ...
    char(pos.time(end), 'HH:mm'), char(pos.time(1), 'zzz')));
subtitle(gx, 'Lines: track during the run. Dots: last reported position.');
pos.time.TimeZone = t;

if ~isempty(options.ExportFile)
    exportgraphics(fig, options.ExportFile, 'Resolution', 200);
    fprintf('Saved %s\n', options.ExportFile);
end
end

function name = category(type)
switch type
    case {1, 2, 3, 27}
        name = "Class A";
    case {18, 19}
        name = "Class B";
    case {4, 11}
        name = "Base station";
    case 21
        name = "Aid to navigation";
    case 9
        name = "SAR aircraft";
    otherwise
        name = "Class A";
end
end

function value = field(msg, name)
value = NaN;
if isfield(msg, name) && isnumeric(msg.(name)) && isscalar(msg.(name))
    value = msg.(name);
end
end
