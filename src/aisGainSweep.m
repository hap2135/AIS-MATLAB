function results = aisGainSweep(options)
%aisGainSweep Find the RTL-SDR tuner gain that receives the most AIS.
%   RESULTS = aisGainSweep() runs aisReceive briefly at each gain and
%   returns one row per setting with the noise floor, the SNR of a fixed
%   reference station, how traffic splits between channels A and B, and
%   how many stations and messages were heard. Signs of overload at high
%   gain: the noise floor rises, reference SNR stops improving and one
%   channel loses most of its traffic.
%
%   Options:
%     Gains          Tuner gains in dB; 'auto' for AGC (default 7 steps + AGC)
%     Duration       Seconds per setting (default 60)
%     ReferenceMmsi  A fixed station heard on both channels (default the
%                    Astoria shore base station, 003669982)
%     OutputFolder   Where the per-setting logs go (default logs\gainsweep_<time>)
%
%   Example:
%     r = aisGainSweep(Gains={28 33.8 37.2}, Duration=90);

arguments
    options.Gains cell = {22.9, 28.0, 32.8, 37.2, 40.2, 44.5, 49.6, 'auto'}
    options.Duration (1,1) double {mustBePositive} = 60
    options.ReferenceMmsi (1,1) double = 3669982
    options.OutputFolder (1,:) char = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'logs', ...
        ['gainsweep_' char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))])
end

n = numel(options.Gains);
results = table('Size', [n 12], 'VariableTypes', [{'string'} repmat({'double'}, 1, 11)], ...
    'VariableNames', {'gain', 'noiseA', 'noiseB', 'refSnrA', 'refSnrB', 'refCount', ...
    'messagesA', 'messagesB', 'balanceA', 'stations', 'shipSnr', 'farthestKm'});
for k = 1:n
    gain = options.Gains{k};
    folder = fullfile(options.OutputFolder, matlab.lang.makeValidName(string(gain)));
    fprintf('Gain %s dB: listening %.0f s...\n', string(gain), options.Duration);
    output = evalc('aisReceive(Duration=options.Duration, Gain=gain, ShowMap=false, Verbose=false, OutputFolder=folder);');
    results(k, :) = summarizeRun(string(gain), output, folder, options.ReferenceMmsi);
    disp(results(k, :));
end
writetable(results, fullfile(options.OutputFolder, 'gainsweep.csv'));
end

function row = summarizeRun(gain, output, folder, refMmsi)
noise = regexp(output, 'ch (A|B) \d+ pkts \(noise (-?[\d.]+) dB\)', 'tokens');
noise = vertcat(noise{:});
noiseA = mean(str2double(noise(noise(:, 1) == "A", 2)));
noiseB = mean(str2double(noise(noise(:, 1) == "B", 2)));

d = dir(fullfile(folder, 'ais_*.jsonl'));
lines = readlines(fullfile(folder, d(end).name), 'EmptyLineRule', 'skip');
recs = cellfun(@jsondecode, cellstr(lines), 'UniformOutput', false);
if isempty(recs)
    row = {gain, noiseA, noiseB, NaN, NaN, 0, 0, 0, NaN, 0, NaN, NaN};
    return
end
mmsi = cellfun(@(r) r.message.mmsi, recs);
ch = cellfun(@(r) r.channel, recs);
snr = cellfun(@(r) r.snrDb, recs);
isRef = mmsi == refMmsi;
isShip = mmsi >= 2e8;                               % excludes base stations (00...) and AtoNs (99...)

% Distance of each ship from the reference station, as a range indicator
refPos = [NaN NaN];
km = NaN;
for j = find(isRef)'
    m = recs{j}.message;
    if isfield(m, 'latitude'), refPos = [m.latitude m.longitude]; break; end
end
hasPos = isShip & cellfun(@(r) isfield(r.message, 'latitude') && ~isnan(r.message.latitude), recs);
if any(hasPos) && ~any(isnan(refPos))
    lat = cellfun(@(r) r.message.latitude, recs(hasPos));
    lon = cellfun(@(r) r.message.longitude, recs(hasPos));
    km = max(2*6371*asind(sqrt(sind((lat - refPos(1))/2).^2 + ...
        cosd(lat).*cosd(refPos(1)).*sind((lon - refPos(2))/2).^2))*pi/180);
end

row = {gain, noiseA, noiseB, median(snr(isRef & ch == 'A')), median(snr(isRef & ch == 'B')), ...
    nnz(isRef), nnz(ch == 'A'), nnz(ch == 'B'), nnz(ch == 'A')/numel(ch), ...
    numel(unique(mmsi)), median(snr(isShip)), km};
end
