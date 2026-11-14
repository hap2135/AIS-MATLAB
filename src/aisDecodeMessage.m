function msg = aisDecodeMessage(bits)
%aisDecodeMessage Decode an AIS message into every field it carries.
%   MSG = aisDecodeMessage(BITS) decodes BITS (logical vector, most
%   significant bit first, as carried in an !AIVDM payload) into a struct.
%   All 27 ITU-R M.1371 message types are handled. Values the sender marked
%   "not available" are returned as NaN (numbers) or "" (text). Binary
%   application payloads (types 6, 8, 17, 25, 26) are returned as hex.
%
%   Field layouts follow ITU-R M.1371-5 and the gpsd "AIVDM/AIVDO protocol
%   decoding" reference.

bits = logical(bits(:)');

msg = struct();
msg.type = u(bits, 0, 6);
msg.typeName = typeName(msg.type);
msg.repeat = u(bits, 6, 2);
msg.mmsi = u(bits, 8, 30);
msg.numBits = numel(bits);

switch msg.type
    case {1, 2, 3}                                  % Class A position
        msg.navStatus = u(bits, 38, 4);
        msg.navStatusText = navStatusText(msg.navStatus);
        rot = s(bits, 42, 8);
        msg.rateOfTurnRaw = rot;
        msg.rateOfTurn = rateOfTurn(rot);           % deg/min, + = starboard
        msg.speedOverGround = speed(u(bits, 50, 10));
        msg.positionAccuracyHigh = logical(u(bits, 60, 1));
        msg.longitude = lon28(s(bits, 61, 28));
        msg.latitude = lat27(s(bits, 89, 27));
        msg.courseOverGround = course(u(bits, 116, 12));
        msg.trueHeading = heading(u(bits, 128, 9));
        msg.timestampSecond = u(bits, 137, 6);
        msg.specialManeuver = u(bits, 143, 2);
        msg.specialManeuverText = maneuverText(msg.specialManeuver);
        msg.raim = logical(u(bits, 148, 1));
        msg.radioStatus = u(bits, 149, 19);

    case {4, 11}                                    % Base station / UTC response
        msg.utcYear = u(bits, 38, 14);
        msg.utcMonth = u(bits, 52, 4);
        msg.utcDay = u(bits, 56, 5);
        msg.utcHour = u(bits, 61, 5);
        msg.utcMinute = u(bits, 66, 6);
        msg.utcSecond = u(bits, 72, 6);
        msg.utcText = sprintf('%04d-%02d-%02d %02d:%02d:%02d UTC', msg.utcYear, ...
            msg.utcMonth, msg.utcDay, msg.utcHour, msg.utcMinute, msg.utcSecond);
        msg.positionAccuracyHigh = logical(u(bits, 78, 1));
        msg.longitude = lon28(s(bits, 79, 28));
        msg.latitude = lat27(s(bits, 107, 27));
        msg.epfd = u(bits, 134, 4);
        msg.epfdText = epfdText(msg.epfd);
        msg.raim = logical(u(bits, 148, 1));
        msg.radioStatus = u(bits, 149, 19);

    case 5                                          % Static and voyage data
        msg.aisVersion = u(bits, 38, 2);
        msg.imo = u(bits, 40, 30);
        msg.callsign = txt(bits, 70, 42);
        msg.shipName = txt(bits, 112, 120);
        msg.shipType = u(bits, 232, 8);
        msg.shipTypeText = shipTypeText(msg.shipType);
        msg = addDimensions(msg, bits, 240);
        msg.epfd = u(bits, 270, 4);
        msg.epfdText = epfdText(msg.epfd);
        msg.etaMonth = u(bits, 274, 4);
        msg.etaDay = u(bits, 278, 5);
        msg.etaHour = u(bits, 283, 5);
        msg.etaMinute = u(bits, 288, 6);
        msg.etaText = etaText(msg.etaMonth, msg.etaDay, msg.etaHour, msg.etaMinute);
        msg.draught = u(bits, 294, 8) / 10;         % metres, 0 = not available
        msg.destination = txt(bits, 302, 120);
        msg.dteNotReady = logical(u(bits, 422, 1));

    case 6                                          % Addressed binary
        msg.sequenceNumber = u(bits, 38, 2);
        msg.destinationMmsi = u(bits, 40, 30);
        msg.retransmitted = logical(u(bits, 70, 1));
        msg.dac = u(bits, 72, 10);
        msg.fi = u(bits, 82, 6);
        msg.applicationText = applicationText(msg.dac, msg.fi);
        msg.dataHex = hexFrom(bits, 88);

    case {7, 13}                                    % Binary / safety acknowledge
        for k = 1:4
            start = 40 + (k - 1)*32;
            if numel(bits) < start + 30, break; end
            msg.(sprintf('ackMmsi%d', k)) = u(bits, start, 30);
            msg.(sprintf('ackSequence%d', k)) = u(bits, start + 30, 2);
        end

    case 8                                          % Broadcast binary
        msg.dac = u(bits, 40, 10);
        msg.fi = u(bits, 50, 6);
        msg.applicationText = applicationText(msg.dac, msg.fi);
        msg.dataHex = hexFrom(bits, 56);

    case 9                                          % SAR aircraft position
        msg.altitude = u(bits, 38, 12);             % metres, 4095 = n/a
        if msg.altitude == 4095, msg.altitude = NaN; end
        sog = u(bits, 50, 10);                      % whole knots for type 9
        if sog == 1023, sog = NaN; end
        msg.speedOverGround = sog;
        msg.positionAccuracyHigh = logical(u(bits, 60, 1));
        msg.longitude = lon28(s(bits, 61, 28));
        msg.latitude = lat27(s(bits, 89, 27));
        msg.courseOverGround = course(u(bits, 116, 12));
        msg.timestampSecond = u(bits, 128, 6);
        msg.regionalReserved = u(bits, 134, 8);
        msg.dteNotReady = logical(u(bits, 142, 1));
        msg.assignedMode = logical(u(bits, 146, 1));
        msg.raim = logical(u(bits, 147, 1));
        msg.radioStatus = u(bits, 148, 20);

    case 10                                         % UTC/date inquiry
        msg.destinationMmsi = u(bits, 40, 30);

    case 12                                         % Addressed safety text
        msg.sequenceNumber = u(bits, 38, 2);
        msg.destinationMmsi = u(bits, 40, 30);
        msg.retransmitted = logical(u(bits, 70, 1));
        msg.text = txt(bits, 72, numel(bits) - 72);

    case 14                                         % Broadcast safety text
        msg.text = txt(bits, 40, numel(bits) - 40);

    case 15                                         % Interrogation
        msg.interrogatedMmsi1 = u(bits, 40, 30);
        msg.requestedType1_1 = u(bits, 70, 6);
        msg.slotOffset1_1 = u(bits, 76, 12);
        if numel(bits) >= 108
            msg.requestedType1_2 = u(bits, 90, 6);
            msg.slotOffset1_2 = u(bits, 96, 12);
        end
        if numel(bits) >= 158
            msg.interrogatedMmsi2 = u(bits, 110, 30);
            msg.requestedType2_1 = u(bits, 140, 6);
            msg.slotOffset2_1 = u(bits, 146, 12);
        end

    case 16                                         % Assigned mode command
        msg.destinationMmsiA = u(bits, 40, 30);
        msg.offsetA = u(bits, 70, 12);
        msg.incrementA = u(bits, 82, 10);
        if numel(bits) >= 144
            msg.destinationMmsiB = u(bits, 92, 30);
            msg.offsetB = u(bits, 122, 12);
            msg.incrementB = u(bits, 134, 10);
        end

    case 17                                         % DGNSS corrections
        msg.longitude = lon18(s(bits, 40, 18));
        msg.latitude = lat17(s(bits, 58, 17));
        msg.dataHex = hexFrom(bits, 80);

    case 18                                         % Class B position
        msg.speedOverGround = speed(u(bits, 46, 10));
        msg.positionAccuracyHigh = logical(u(bits, 56, 1));
        msg.longitude = lon28(s(bits, 57, 28));
        msg.latitude = lat27(s(bits, 85, 27));
        msg.courseOverGround = course(u(bits, 112, 12));
        msg.trueHeading = heading(u(bits, 124, 9));
        msg.timestampSecond = u(bits, 133, 6);
        msg.regionalReserved = u(bits, 139, 2);
        msg.csUnit = logical(u(bits, 141, 1));      % true = carrier-sense unit
        msg.hasDisplay = logical(u(bits, 142, 1));
        msg.hasDsc = logical(u(bits, 143, 1));
        msg.wholeBand = logical(u(bits, 144, 1));
        msg.acceptsMsg22 = logical(u(bits, 145, 1));
        msg.assignedMode = logical(u(bits, 146, 1));
        msg.raim = logical(u(bits, 147, 1));
        msg.radioStatus = u(bits, 148, 20);

    case 19                                         % Extended Class B
        msg.speedOverGround = speed(u(bits, 46, 10));
        msg.positionAccuracyHigh = logical(u(bits, 56, 1));
        msg.longitude = lon28(s(bits, 57, 28));
        msg.latitude = lat27(s(bits, 85, 27));
        msg.courseOverGround = course(u(bits, 112, 12));
        msg.trueHeading = heading(u(bits, 124, 9));
        msg.timestampSecond = u(bits, 133, 6);
        msg.regionalReserved = u(bits, 139, 4);
        msg.shipName = txt(bits, 143, 120);
        msg.shipType = u(bits, 263, 8);
        msg.shipTypeText = shipTypeText(msg.shipType);
        msg = addDimensions(msg, bits, 271);
        msg.epfd = u(bits, 301, 4);
        msg.epfdText = epfdText(msg.epfd);
        msg.raim = logical(u(bits, 305, 1));
        msg.dteNotReady = logical(u(bits, 306, 1));
        msg.assignedMode = logical(u(bits, 307, 1));

    case 20                                         % Data link management
        for k = 1:4
            start = 40 + (k - 1)*30;
            if numel(bits) < start + 30, break; end
            msg.(sprintf('offset%d', k)) = u(bits, start, 12);
            msg.(sprintf('numberOfSlots%d', k)) = u(bits, start + 12, 4);
            msg.(sprintf('timeout%d', k)) = u(bits, start + 16, 3);
            msg.(sprintf('increment%d', k)) = u(bits, start + 19, 11);
        end

    case 21                                         % Aid to navigation
        msg.aidType = u(bits, 38, 5);
        msg.aidTypeText = aidTypeText(msg.aidType);
        msg.name = txt(bits, 43, 120);
        msg.positionAccuracyHigh = logical(u(bits, 163, 1));
        msg.longitude = lon28(s(bits, 164, 28));
        msg.latitude = lat27(s(bits, 192, 27));
        msg = addDimensions(msg, bits, 219);
        msg.epfd = u(bits, 249, 4);
        msg.epfdText = epfdText(msg.epfd);
        msg.timestampSecond = u(bits, 253, 6);
        msg.offPosition = logical(u(bits, 259, 1));
        msg.regionalReserved = u(bits, 260, 8);
        msg.raim = logical(u(bits, 268, 1));
        msg.virtualAid = logical(u(bits, 269, 1));
        msg.assignedMode = logical(u(bits, 270, 1));
        if numel(bits) > 272
            msg.name = [msg.name txt(bits, 272, numel(bits) - 272)];
        end

    case 22                                         % Channel management
        msg.channelA = u(bits, 40, 12);
        msg.channelB = u(bits, 52, 12);
        msg.txRxMode = u(bits, 64, 4);
        msg.lowPower = logical(u(bits, 68, 1));
        msg.addressed = logical(u(bits, 139, 1));
        if msg.addressed
            msg.destinationMmsi1 = u(bits, 69, 30);
            msg.destinationMmsi2 = u(bits, 104, 30);
        else
            msg.neLongitude = lon18(s(bits, 69, 18));
            msg.neLatitude = lat17(s(bits, 87, 17));
            msg.swLongitude = lon18(s(bits, 104, 18));
            msg.swLatitude = lat17(s(bits, 122, 17));
        end
        msg.channelABandwidthReduced = logical(u(bits, 140, 1));
        msg.channelBBandwidthReduced = logical(u(bits, 141, 1));
        msg.transitionalZoneSize = u(bits, 142, 3);

    case 23                                         % Group assignment
        msg.neLongitude = lon18(s(bits, 40, 18));
        msg.neLatitude = lat17(s(bits, 58, 17));
        msg.swLongitude = lon18(s(bits, 75, 18));
        msg.swLatitude = lat17(s(bits, 93, 17));
        msg.stationType = u(bits, 110, 4);
        msg.shipType = u(bits, 114, 8);
        msg.shipTypeText = shipTypeText(msg.shipType);
        msg.txRxMode = u(bits, 144, 2);
        msg.reportingInterval = u(bits, 146, 4);
        msg.quietTimeMinutes = u(bits, 150, 4);

    case 24                                         % Class B static data
        msg.partNumber = u(bits, 38, 2);
        if msg.partNumber == 0
            msg.shipName = txt(bits, 40, 120);
        else
            msg.shipType = u(bits, 40, 8);
            msg.shipTypeText = shipTypeText(msg.shipType);
            msg.vendorId = txt(bits, 48, 18);
            msg.unitModel = u(bits, 66, 4);
            msg.serialNumber = u(bits, 70, 20);
            msg.callsign = txt(bits, 90, 42);
            if floor(msg.mmsi / 1e7) == 98           % auxiliary craft
                msg.mothershipMmsi = u(bits, 132, 30);
            else
                msg = addDimensions(msg, bits, 132);
            end
        end

    case {25, 26}                                   % Single/multi-slot binary
        msg.addressed = logical(u(bits, 38, 1));
        msg.structured = logical(u(bits, 39, 1));
        dataStart = 40;
        if msg.addressed
            msg.destinationMmsi = u(bits, 40, 30);
            dataStart = 70;
        end
        dataEnd = numel(bits);
        if msg.type == 26
            msg.radioStatus = u(bits, numel(bits) - 20, 20);
            dataEnd = numel(bits) - 20;
        end
        msg.dataHex = hexFrom(bits(1:dataEnd), dataStart);

    case 27                                         % Long-range position
        msg.positionAccuracyHigh = logical(u(bits, 38, 1));
        msg.raim = logical(u(bits, 39, 1));
        msg.navStatus = u(bits, 40, 4);
        msg.navStatusText = navStatusText(msg.navStatus);
        msg.longitude = lon18(s(bits, 44, 18));
        msg.latitude = lat17(s(bits, 62, 17));
        sog = u(bits, 79, 6);                       % whole knots, 63 = n/a
        if sog == 63, sog = NaN; end
        msg.speedOverGround = sog;
        cog = u(bits, 85, 9);                       % whole degrees, 511 = n/a
        if cog == 511, cog = NaN; end
        msg.courseOverGround = cog;
        msg.gnssPositionLatency = ~logical(u(bits, 94, 1));
end
end

%% Field extraction (start is the 0-based bit offset)

function v = u(bits, start, len)
if start + len > numel(bits) || len <= 0
    v = NaN;
    return
end
v = double(bits(start + 1:start + len)) * pow2(len - 1:-1:0)';
end

function v = s(bits, start, len)
v = u(bits, start, len);
if v >= 2^(len - 1)
    v = v - 2^len;
end
end

function str = txt(bits, start, len)
nChars = floor(min(len, numel(bits) - start) / 6);
codes = zeros(1, max(nChars, 0));
for k = 1:nChars
    codes(k) = u(bits, start + (k - 1)*6, 6);
end
codes(codes < 32) = codes(codes < 32) + 64;         % 6-bit ASCII
str = deblank(regexprep(char(codes), '@.*$', ''));  % '@' ends the text
end

function hex = hexFrom(bits, start)
data = bits(start + 1:end);
data = [data false(1, mod(-numel(data), 4))];
if isempty(data)
    hex = '';
    return
end
hex = dec2hex(double(reshape(data, 4, []).') * [8; 4; 2; 1]).';
end

function msg = addDimensions(msg, bits, start)
msg.toBow = u(bits, start, 9);
msg.toStern = u(bits, start + 9, 9);
msg.toPort = u(bits, start + 18, 6);
msg.toStarboard = u(bits, start + 24, 6);
msg.length = msg.toBow + msg.toStern;               % metres, 0 = unknown
msg.beam = msg.toPort + msg.toStarboard;
end

%% Unit conversions

function v = lon28(raw)
v = raw / 600000;
if raw == 181*600000, v = NaN; end
end

function v = lat27(raw)
v = raw / 600000;
if raw == 91*600000, v = NaN; end
end

function v = lon18(raw)
v = raw / 600;
if raw == 181*600, v = NaN; end
end

function v = lat17(raw)
v = raw / 600;
if raw == 91*600, v = NaN; end
end

function v = speed(raw)
v = raw / 10;                                       % knots
if raw == 1023, v = NaN; end
end

function v = course(raw)
v = raw / 10;                                       % degrees true
if raw >= 3600, v = NaN; end
end

function v = heading(raw)
v = raw;
if raw == 511, v = NaN; end
end

function v = rateOfTurn(raw)
if isnan(raw) || abs(raw) >= 127
    v = NaN;                                        % n/a or no turn indicator
else
    v = sign(raw) * (raw / 4.733)^2;
end
end

function str = etaText(month, day, hour, minute)
if month == 0 || day == 0 || hour == 24 || minute == 60
    str = '';
else
    str = sprintf('%02d-%02d %02d:%02d UTC', month, day, hour, minute);
end
end

%% Lookup tables

function name = typeName(type)
names = ["Position report (Class A)", "Position report (Class A, assigned)", ...
    "Position report (Class A, interrogated)", "Base station report", ...
    "Static and voyage data", "Addressed binary message", "Binary acknowledge", ...
    "Broadcast binary message", "SAR aircraft position", "UTC/date inquiry", ...
    "UTC/date response", "Addressed safety message", "Safety acknowledge", ...
    "Broadcast safety message", "Interrogation", "Assigned mode command", ...
    "DGNSS broadcast", "Position report (Class B)", "Extended Class B report", ...
    "Data link management", "Aid to navigation report", "Channel management", ...
    "Group assignment command", "Static data report (Class B)", ...
    "Single slot binary message", "Multiple slot binary message", ...
    "Long-range position report"];
name = 'Unknown';
if type >= 1 && type <= 27
    name = char(names(type));
end
end

function str = navStatusText(code)
names = ["Under way using engine", "At anchor", "Not under command", ...
    "Restricted manoeuvrability", "Constrained by draught", "Moored", ...
    "Aground", "Engaged in fishing", "Under way sailing", "Reserved (HSC)", ...
    "Reserved (WIG)", "Towing astern", "Pushing ahead / towing alongside", ...
    "Reserved", "AIS-SART / MOB / EPIRB active", "Not defined"];
str = lookup(names, code);
end

function str = maneuverText(code)
str = lookup(["Not available", "No special maneuver", "Special maneuver", ""], code);
end

function str = epfdText(code)
names = strings(1, 16);
names(1:9) = ["Undefined", "GPS", "GLONASS", "GPS/GLONASS", "Loran-C", ...
    "Chayka", "Integrated navigation system", "Surveyed", "Galileo"];
names(16) = "Internal GNSS";
str = lookup(names, code);
end

function str = aidTypeText(code)
names = ["Not specified", "Reference point", "RACON", "Fixed structure off shore", ...
    "Spare", "Light, without sectors", "Light, with sectors", ...
    "Leading light front", "Leading light rear", "Beacon, cardinal N", ...
    "Beacon, cardinal E", "Beacon, cardinal S", "Beacon, cardinal W", ...
    "Beacon, port hand", "Beacon, starboard hand", ...
    "Beacon, preferred channel port hand", ...
    "Beacon, preferred channel starboard hand", "Beacon, isolated danger", ...
    "Beacon, safe water", "Beacon, special mark", "Cardinal mark N", ...
    "Cardinal mark E", "Cardinal mark S", "Cardinal mark W", "Port hand mark", ...
    "Starboard hand mark", "Preferred channel port hand", ...
    "Preferred channel starboard hand", "Isolated danger", "Safe water", ...
    "Special mark", "Light vessel / LANBY / rig"];
str = lookup(names, code);
end

function str = shipTypeText(code)
if isnan(code) || code == 0
    str = 'Not available';
    return
end
hazard = ["", "hazard cat. A", "hazard cat. B", "hazard cat. C", "hazard cat. D", ...
    "", "", "", "", ""];
special = containers.Map(30:39, {'Fishing', 'Towing', 'Towing (large)', ...
    'Dredging / underwater ops', 'Diving ops', 'Military ops', 'Sailing', ...
    'Pleasure craft', 'Reserved', 'Reserved'});
service = containers.Map(50:59, {'Pilot vessel', 'Search and rescue', 'Tug', ...
    'Port tender', 'Anti-pollution', 'Law enforcement', 'Local vessel', ...
    'Local vessel', 'Medical transport', 'Noncombatant ship'});
groups = containers.Map([2 4 6 7 8 9], {'Wing in ground', 'High-speed craft', ...
    'Passenger', 'Cargo', 'Tanker', 'Other'});
tens = floor(code / 10);
if isKey(special, code)
    str = special(code);
elseif isKey(service, code)
    str = service(code);
elseif isKey(groups, tens)
    str = groups(tens);
    detail = hazard(mod(code, 10) + 1);
    if strlength(detail) > 0
        str = sprintf('%s, %s', str, detail);
    end
else
    str = sprintf('Reserved (%d)', code);
end
end

function str = applicationText(dac, fi)
str = '';
known = {1, 31, 'Meteorological and hydrographic data'; ...
         1, 11, 'Meteorological and hydrographic data (legacy)'; ...
         1, 21, 'Weather observation from ship'; ...
         1, 22, 'Area notice'; ...
         1, 24, 'Extended ship static and voyage data'; ...
         1, 27, 'Route information'; ...
         1, 29, 'Text description'; ...
         367, 33, 'USCG environmental message'; ...
         367, 22, 'USCG area notice'; ...
         367, 24, 'USCG extended ship static data'; ...
         366, 56, 'USCG encrypted data'; ...
         366, 57, 'USCG encrypted data'};
for k = 1:size(known, 1)
    if known{k, 1} == dac && known{k, 2} == fi
        str = known{k, 3};
        return
    end
end
end

function str = lookup(names, code)
str = '';
if ~isnan(code) && code + 1 <= numel(names)
    str = char(names(code + 1));
end
end
