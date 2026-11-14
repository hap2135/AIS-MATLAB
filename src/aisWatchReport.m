function report = aisWatchReport(jsonFiles, watchlist, options)
%aisWatchReport Check aisReceive logs against a list of vessels to watch for.
%   REPORT = aisWatchReport(JSONFILES, WATCHLIST) reads one or more
%   aisReceive .jsonl logs and returns one row per watchlist vessel: whether
%   it was heard, how often, first and last time, median SNR, last position,
%   and the name it broadcast (Type 5/24) compared with the listed name.
%
%   It also prints "name hits": stations whose broadcast name matches a
%   watchlist vessel but under a different MMSI. This is how vessels with no
%   MMSI, or a doubtful one, get resolved.
%
%   JSONFILES  .jsonl path, string array of paths, or a wildcard such as
%              'logs\ais_20261106_*.jsonl'
%   WATCHLIST  CSV path or table with Operator, Name, MMSI, Status
%              (default data\ferry_watchlist.csv)
%
%   Options:
%     ExportFile  PNG for a map of the watchlist vessels heard ('' = none)
%     CsvFile     CSV to write the report to ('' = none)
%     TimeZone    Time zone for the reported times (default 'America/New_York')
%
%   Example:
%     r = aisWatchReport('logs\ais_20261106_*.jsonl', ...
%         ExportFile='logs\watch_20261106.png', CsvFile='logs\watch_20261106.csv');

arguments
    jsonFiles
    watchlist = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'data', 'ferry_watchlist.csv')
    options.ExportFile (1,:) char = ''
    options.CsvFile (1,:) char = ''
    options.TimeZone (1,:) char = 'America/New_York'
end

if ~istable(watchlist)
    watchlist = readtable(watchlist, 'TextType', 'string', 'Delimiter', ',');
end
watchlist.MMSI = double(watchlist.MMSI);
watchlist.MMSI(isnan(watchlist.MMSI)) = 0;

% Collect files
files = strings(0, 1);
jsonFiles = string(jsonFiles);
for p = jsonFiles(:)'
    d = dir(p);
    d = d(~[d.isdir]);
    files = [files; string(fullfile({d.folder}, {d.name}))']; %#ok<AGROW>
end
if isempty(files)
    error('aisWatchReport:noFiles', 'No log files match %s.', strjoin(string(jsonFiles), ', '));
end

% Read every message: mmsi, time, snr, position, name
noPosition = [5 17 20 22 23 24];
mmsi = []; t = datetime.empty(0, 1); t.TimeZone = 'UTC';
snr = []; lat = []; lon = []; names = containers.Map('KeyType', 'double', 'ValueType', 'char');
for f = files'
    lines = readlines(f, 'EmptyLineRule', 'skip');
    for k = 1:numel(lines)
        r = jsondecode(lines(k));
        m = r.message;
        mmsi(end+1, 1) = m.mmsi; %#ok<AGROW>
        t(end+1, 1) = datetime(r.time, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', ...
            'TimeZone', 'UTC'); %#ok<AGROW>
        snr(end+1, 1) = r.snrDb; %#ok<AGROW>
        [la, lo] = deal(NaN);
        if ~ismember(m.type, noPosition) && isfield(m, 'latitude') && isnumeric(m.latitude) ...
                && ~isempty(m.latitude) && abs(m.latitude) <= 90 && abs(m.longitude) <= 180
            la = m.latitude; lo = m.longitude;
        end
        lat(end+1, 1) = la; lon(end+1, 1) = lo; %#ok<AGROW>
        for nf = ["shipName", "name"]
            if isfield(m, nf) && strlength(string(m.(nf))) > 0
                names(m.mmsi) = char(strtrim(string(m.(nf))));
            end
        end
    end
end
fprintf('%d messages from %d stations in %d file(s).\n', numel(mmsi), numel(unique(mmsi)), numel(files));

% One row per watchlist vessel
n = height(watchlist);
report = watchlist;
report.Heard = false(n, 1);
report.Messages = zeros(n, 1);
report.FirstHeard = NaT(n, 1, 'TimeZone', options.TimeZone);
report.LastHeard = NaT(n, 1, 'TimeZone', options.TimeZone);
report.MedianSnrDb = NaN(n, 1);
report.LastLatitude = NaN(n, 1);
report.LastLongitude = NaN(n, 1);
report.BroadcastName = strings(n, 1);
report.NameCheck = strings(n, 1);
for i = 1:n
    if watchlist.MMSI(i) == 0
        report.NameCheck(i) = "no MMSI";
        continue
    end
    sel = mmsi == watchlist.MMSI(i);
    if isKey(names, watchlist.MMSI(i))
        report.BroadcastName(i) = names(watchlist.MMSI(i));
        if aisNamesMatch(report.BroadcastName(i), watchlist.Name(i))
            report.NameCheck(i) = "match";
        else
            report.NameCheck(i) = "MISMATCH";
        end
    elseif any(sel)
        report.NameCheck(i) = "no name heard";
    end
    if ~any(sel), continue; end
    report.Heard(i) = true;
    report.Messages(i) = nnz(sel);
    report.FirstHeard(i) = min(t(sel));
    report.LastHeard(i) = max(t(sel));
    report.MedianSnrDb(i) = median(snr(sel));
    pos = find(sel & ~isnan(lat));
    if ~isempty(pos)
        [~, j] = max(t(pos));
        report.LastLatitude(i) = lat(pos(j));
        report.LastLongitude(i) = lon(pos(j));
    end
end

% Summary
listed = watchlist.MMSI > 0;
fprintf('\nWatchlist: heard %d of %d vessels with an MMSI.\n', nnz(report.Heard), nnz(listed));
g = groupsummary(report(listed, :), 'Operator', @(x) sum(x), 'Heard');
for i = 1:height(g)
    fprintf('  %-28s %2d of %2d\n', g.Operator(i), g.fun1_Heard(i), g.GroupCount(i));
end
for s = ["confident", "candidate"]
    rows = report(report.Status == s, :);
    if isempty(rows), continue; end
    fprintf('\nList status "%s":\n', s);
    for i = 1:height(rows)
        fprintf('  %-34s %9d  %-5s %s\n', rows.Name(i), rows.MMSI(i), ...
            heardText(rows.Heard(i)), ...
            describeName(rows.BroadcastName(i), rows.NameCheck(i)));
    end
end
mism = report(report.NameCheck == "MISMATCH", :);
if ~isempty(mism)
    fprintf('\nName mismatches (list name vs broadcast):\n');
    for i = 1:height(mism)
        fprintf('  %9d  "%s" vs "%s"\n', mism.MMSI(i), mism.Name(i), mism.BroadcastName(i));
    end
end

% Name hits under other MMSIs
heardMmsi = cell2mat(names.keys);
hits = 0;
for i = 1:n
    for m = heardMmsi
        if m == watchlist.MMSI(i), continue; end
        if aisNamesMatch(names(m), watchlist.Name(i))
            if hits == 0, fprintf('\nName hits under a different MMSI:\n'); end
            hits = hits + 1;
            fprintf('  %-34s listed %-9s  heard %9d "%s" (%d messages)\n', watchlist.Name(i), ...
                string(watchlist.MMSI(i) * (watchlist.MMSI(i) > 0)), m, names(m), nnz(mmsi == m));
        end
    end
end

if ~isempty(options.CsvFile)
    out = report;
    out.MMSI = uint32(out.MMSI);
    writetable(out, options.CsvFile);
    fprintf('\nReport: %s\n', options.CsvFile);
end
if ~isempty(options.ExportFile)
    plotReport(report, files, options.ExportFile);
end
end

function str = heardText(tf)
str = "-";
if tf, str = "heard"; end
end

function str = describeName(name, check)
if name == ""
    str = check;
else
    str = sprintf('"%s" (%s)', name, check);
end
end

function plotReport(report, files, exportFile)
fig = figure('Position', [100 100 1100 800], 'Visible', 'off');
theme(fig, 'light');
gx = geoaxes(fig);
try
    geobasemap(gx, 'streets-light');
catch
    geobasemap(gx, 'darkwater');
end
hold(gx, 'on');
h = report(report.Heard & ~isnan(report.LastLatitude), :);
ops = unique(report.Operator, 'stable');
colors = lines(numel(ops));
for k = 1:numel(ops)
    s = h(h.Operator == ops(k), :);
    if isempty(s)
        geoscatter(gx, NaN, NaN, 60, colors(k, :), 'filled', 'DisplayName', ops(k) + " (0)");
        continue
    end
    geoscatter(gx, s.LastLatitude, s.LastLongitude, 60, colors(k, :), 'filled', ...
        'MarkerEdgeColor', 'k', 'DisplayName', sprintf('%s (%d)', ops(k), height(s)));
    text(gx, s.LastLatitude, s.LastLongitude, "  " + s.Name, 'FontSize', 8, 'Color', colors(k, :)*0.7);
end
legend(gx, 'Location', 'northwest');
[~, f1] = fileparts(files(1));
more = "";
if numel(files) > 1, more = sprintf(' + %d more logs', numel(files) - 1); end
title(gx, sprintf('Watchlist vessels heard: %d of %d (%s%s)', nnz(report.Heard), ...
    nnz(report.MMSI > 0), f1, more), 'Interpreter', 'none');
if ~isempty(h)
    pad = 0.015;
    geolimits(gx, [min(h.LastLatitude) max(h.LastLatitude)] + [-pad pad], ...
        [min(h.LastLongitude) max(h.LastLongitude)] + [-pad pad]);
else
    geolimits(gx, [40.62 40.84], [-74.10 -73.90]);
end
exportgraphics(fig, exportFile, 'Resolution', 130);
close(fig);
fprintf('Map: %s\n', exportFile);
end
