function tests = testAis
%testAis Unit tests for the AIS receiver chain. Run with runtests('testAis').
tests = functiontests(localfunctions);
end

function setup(testCase)
testCase.TestData.out = tempname;
mkdir(testCase.TestData.out);
end

function teardown(testCase)
fclose('all');
rmdir(testCase.TestData.out, 's');
end

function testPositionReportDecode(testCase)
% Reference sentence from the gpsd AIVDM/AIVDO protocol documentation
bits = aisNmeaToBits({'!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C'});
msg = aisDecodeMessage(bits);
verifyEqual(testCase, msg.type, 1);
verifyEqual(testCase, msg.mmsi, 477553000);
verifyEqual(testCase, msg.navStatusText, 'Moored');
verifyEqual(testCase, msg.longitude, -122.345832, 'AbsTol', 2e-6);   % 1/600000 deg resolution
verifyEqual(testCase, msg.latitude, 47.582833, 'AbsTol', 2e-6);
verifyEqual(testCase, msg.courseOverGround, 51);
verifyEqual(testCase, msg.trueHeading, 181);
end

function testStaticVoyageDecode(testCase)
sentences = {'!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C', ...
    '!AIVDM,2,2,1,A,88888888880,2*25'};
msg = aisDecodeMessage(aisNmeaToBits(sentences));
verifyEqual(testCase, msg.mmsi, 351759000);
verifyEqual(testCase, msg.imo, 9134270);
verifyEqual(testCase, msg.callsign, '3FOF8');
verifyEqual(testCase, msg.shipName, 'EVER DIADEM');
verifyEqual(testCase, msg.shipType, 70);
verifyEqual(testCase, [msg.length msg.beam], [295 32]);
verifyEqual(testCase, msg.draught, 12.2, 'AbsTol', 1e-9);
verifyEqual(testCase, msg.destination, 'NEW YORK');
verifyEqual(testCase, msg.etaText, '05-15 14:00 UTC');
end

function testNmeaRoundTrip(testCase)
sentences = {'!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C', ...
    '!AIVDM,2,2,1,A,88888888880,2*25'};
verifyEqual(testCase, aisToNmea(aisNmeaToBits(sentences), 'A', 1), sentences');
end

function testBothChannelsFromSyntheticRadio(testCase)
% Type 1 on channel A and type 5 on channel B, captured as the radio does
% (288 kHz centred on 162.0 MHz), with transmitter frequency error and noise.
fs = 288e3;
posBits = aisNmeaToBits({'!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C'});
staticBits = aisNmeaToBits({'!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C', ...
    '!AIVDM,2,2,1,A,88888888880,2*25'});
rng(1);
x = 0.05*complex(randn(2*fs, 1), randn(2*fs, 1));
burstA = aisWaveform(posBits, fs, -25e3 + 400);
burstB = aisWaveform(staticBits, fs, 25e3 - 300);
x(0.3*fs + (1:numel(burstA))) = x(0.3*fs + (1:numel(burstA))) + burstA;
x(1.1*fs + (1:numel(burstB))) = x(1.1*fs + (1:numel(burstB))) + burstB;
file = fullfile(testCase.TestData.out, 'synthetic.bb');
writer = comm.BasebandFileWriter(file, fs, 162e6);
writer(single(x));
release(writer);

vessels = aisReceive(InputFile=file, ShowMap=false, Verbose=false, ...
    OutputFolder=testCase.TestData.out);

verifyEqual(testCase, sort(vessels.mmsi), [351759000; 477553000]);
nmea = readlines(only(testCase, '*.nmea'), 'EmptyLineRule', 'skip');
verifyEqual(testCase, numel(nmea), 3);
verifyTrue(testCase, any(startsWith(nmea, '!AIVDM,1,1,,A,177KQJ5000G?tO`K>RA1wUbN0TKH')));
verifyTrue(testCase, any(startsWith(nmea, '!AIVDM,2,1,0,B,55?MbV02;H;s<HtKR20EHE')));
end

function testRecordedCapture(testCase)
% Real over-the-air capture shipped with the MathWorks AIS example
file = fullfile(getenv('USERPROFILE'), 'Documents', 'MATLAB', 'Examples', 'R2026a', ...
    'comm', 'ShipTrackingUsingAISSignalsExample', 'ais_capture.bb');
assumeTrue(testCase, isfile(file), 'MathWorks AIS example capture not downloaded');
vessels = aisReceive(InputFile=file, ShowMap=false, Verbose=false, ...
    OutputFolder=testCase.TestData.out);
verifyEqual(testCase, sort(vessels.mmsi), [366941020; 367513020; 367513050]);
end

%% Helpers

function file = only(testCase, pattern)
d = dir(fullfile(testCase.TestData.out, pattern));
assertNumElements(testCase, d, 1);
file = fullfile(d.folder, d.name);
end

function x = aisWaveform(msgBits, fs, freqOffset)
% Build one AIS burst: HDLC frame, NRZI, GMSK (BT 0.4) at 9600 baud.
data = reshape(flipud(reshape(logical(msgBits), 8, [])), 1, []);   % LSB first
crc = 65535;
for b = data
    if xor(bitand(crc, 1), b)
        crc = bitxor(bitshift(crc, -1), 33800);
    else
        crc = bitshift(crc, -1);
    end
end
fcs = bitget(bitxor(crc, 65535), 1:16) == 1;
stuffed = false(1, 0);
run = 0;
for b = [data fcs]
    stuffed(end+1) = b; %#ok<AGROW>
    run = (run + 1)*b;
    if run == 5
        stuffed(end+1) = false; %#ok<AGROW>
        run = 0;
    end
end
flag = logical([0 1 1 1 1 1 1 0]);
frame = [false(1, 8) repmat([false true], 1, 12) flag stuffed flag false(1, 8)];
level = false(size(frame));
state = false;
for k = 1:numel(frame)
    state = xor(state, ~frame(k));                  % NRZI: 0 toggles
    level(k) = state;
end
mod = comm.GMSKModulator('BitInput', true, 'BandwidthTimeProduct', 0.4, ...
    'SamplesPerSymbol', fs/9600);
x = mod(level(:));
x = x .* exp(2j*pi*freqOffset*(0:numel(x) - 1)'/fs);
end
