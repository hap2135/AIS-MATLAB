function packets = aisDetectPackets(disc, sps)
%aisDetectPackets Find CRC-valid AIS packets in an FM discriminator signal.
%   PACKETS = aisDetectPackets(DISC, SPS) slices DISC (instantaneous
%   frequency of one AIS channel, SPS samples per symbol) at every sample
%   phase, NRZI-decodes the bits, finds HDLC frames that follow the AIS
%   training sequence, removes bit stuffing and keeps frames whose CRC-16
%   checks. Each element of PACKETS has fields
%     bits         message bits (logical row, MSB first, CRC removed)
%     startSample  index into DISC of the start flag
%     endSample    index into DISC of the end flag

packets = struct('bits', {}, 'startSample', {}, 'endSample', {});
disc = disc(:);
if numel(disc) < 100*sps
    return
end

% Remove carrier frequency offset (transmitter and tuner error)
disc = disc - movmedian(disc, 64*sps);

found = {};
for phase = 1:sps
    level = disc(phase:sps:end) > 0;
    bits = level(2:end) == level(1:end-1);          % NRZI: no transition = 1
    str = char('0' + bits');
    flags = strfind(str, '01111110');
    flags = flags(flags > 6);
    for f = flags
        preamble = str(f-6:f-1);                    % tail of training sequence
        if ~strcmp(preamble, '010101') && ~strcmp(preamble, '101010')
            continue
        end
        [data, stop] = unstuff(bits, f + 8);
        n = numel(data);
        if n < 88 || mod(n, 8) ~= 0 || ~crcOk(data)
            continue
        end
        % Bytes are sent least significant bit first
        msgBits = reshape(flipud(reshape(data(1:end-16), 8, [])), 1, []);
        key = char('0' + msgBits);
        if any(strcmp(found, key))
            continue                                % same packet, other phase
        end
        found{end+1} = key; %#ok<AGROW>
        packets(end+1) = struct('bits', msgBits, ...
            'startSample', phase + f*sps, 'endSample', phase + stop*sps); %#ok<AGROW>
    end
end
end

function [data, stop] = unstuff(bits, pos)
% Collect HDLC data bits up to the closing flag, removing stuffed zeros.
maxBits = 1100;                                     % 5-slot message + CRC
data = false(1, maxBits + 8);
n = 0;
run = 0;
stop = 0;
for p = pos:min(numel(bits), pos + maxBits + maxBits/5)
    if bits(p)
        run = run + 1;
        if run == 6                                 % closing flag 01111110
            data = data(1:max(n - 6, 0));
            stop = p;
            return
        end
        n = n + 1;
        data(n) = true;
    else
        if run ~= 5                                 % 0 after 11111 is stuffing
            n = n + 1;
            data(n) = false;
        end
        run = 0;
    end
    if n > maxBits
        break
    end
end
data = false(1, 0);
end

function ok = crcOk(data)
% CRC-16-CCITT (HDLC FCS) over data + FCS leaves the residue 0xF0B8.
persistent table
if isempty(table)
    table = zeros(1, 256);
    for k = 0:255
        c = k;
        for b = 1:8
            if bitand(c, 1)
                c = bitxor(bitshift(c, -1), 33800);  % 0x8408
            else
                c = bitshift(c, -1);
            end
        end
        table(k + 1) = c;
    end
end
bytes = pow2(0:7) * double(reshape(data, 8, []));
crc = 65535;
for b = bytes
    crc = bitxor(bitshift(crc, -8), table(bitxor(bitand(crc, 255), b) + 1));
end
ok = crc == 61624;                                  % 0xF0B8
end
