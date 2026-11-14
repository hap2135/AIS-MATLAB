function sentences = aisToNmea(bits, channel, sequenceId)
%aisToNmea Encode AIS message bits as !AIVDM NMEA 0183 sentences.
%   SENTENCES = aisToNmea(BITS, CHANNEL, SEQUENCEID) returns a cell array of
%   !AIVDM sentences carrying BITS (logical vector, MSB first) received on
%   CHANNEL ('A' or 'B'). Messages longer than one sentence are split into
%   fragments that share SEQUENCEID (0-9). This is the standard format read
%   by OpenCPN, AIS-catcher, pyais, MarineTraffic feeders and similar tools.

arguments
    bits {mustBeNumericOrLogical}
    channel (1,1) string
    sequenceId (1,1) double = 0
end

bits = logical(bits(:)');
fillBits = mod(-numel(bits), 6);
bits = [bits false(1, fillBits)];
values = double(reshape(bits, 6, []).') * [32; 16; 8; 4; 2; 1];
codes = values + 48;
codes(values >= 40) = codes(values >= 40) + 8;      % 6-bit payload armoring
payload = char(codes.');

maxChars = 60;
nFragments = ceil(numel(payload) / maxChars);
seqField = '';
if nFragments > 1
    seqField = sprintf('%d', mod(sequenceId, 10));
end
sentences = cell(nFragments, 1);
for k = 1:nFragments
    part = payload((k - 1)*maxChars + 1:min(k*maxChars, end));
    fill = 0;
    if k == nFragments
        fill = fillBits;
    end
    body = sprintf('AIVDM,%d,%d,%s,%s,%s,%d', nFragments, k, seqField, channel, part, fill);
    sentences{k} = sprintf('!%s*%02X', body, nmeaChecksum(body));
end
end

function c = nmeaChecksum(body)
c = 0;
for ch = double(body)
    c = bitxor(c, ch);
end
end
