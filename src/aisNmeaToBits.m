function bits = aisNmeaToBits(sentences)
%aisNmeaToBits Extract AIS message bits from !AIVDM/!AIVDO sentences.
%   BITS = aisNmeaToBits(SENTENCES) joins the fragments of one AIS message
%   (cell array or string array of sentences, in order), checks each NMEA
%   checksum and returns the message bits (logical row, MSB first), ready
%   for aisDecodeMessage. Use it to decode logs from other AIS receivers.

sentences = cellstr(sentences);
payload = '';
fillBits = 0;
for k = 1:numel(sentences)
    line = strtrim(sentences{k});
    tokens = regexp(line, '^!(AIVD[MO],.*)\*([0-9A-Fa-f]{2})$', 'tokens', 'once');
    if isempty(tokens)
        error('aisNmeaToBits:badSentence', 'Not an AIVDM sentence: %s', line);
    end
    expected = 0;
    for ch = double(tokens{1})
        expected = bitxor(expected, ch);
    end
    if expected ~= hex2dec(tokens{2})
        error('aisNmeaToBits:badChecksum', 'Checksum mismatch: %s', line);
    end
    fields = strsplit(tokens{1}, ',', 'CollapseDelimiters', false);
    payload = [payload fields{6}]; %#ok<AGROW>
    fillBits = str2double(fields{7});
end

values = double(payload) - 48;
values(values > 40) = values(values > 40) - 8;
bits = logical(reshape(dec2bin(values, 6).', 1, []) - '0');
bits = bits(1:end - fillBits);
end
