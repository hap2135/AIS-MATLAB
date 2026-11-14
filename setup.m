function setup
%setup Add the AIS receiver code and tests to the MATLAB path for this session.
%   Run once after starting MATLAB:  run('C:\MATLAB-AIS-DOT\setup.m')  or  cd here; setup
root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'), fullfile(root, 'tests'));
if ~isfolder(fullfile(root, 'logs'))
    mkdir(fullfile(root, 'logs'));
end
fprintf('AIS receiver ready. Logs go to %s\n', fullfile(root, 'logs'));
end
