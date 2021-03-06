%>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
%                        Homework8_main.m
% Author      : Zach Dischner
% Date        : 11/3/2013
% Description : Matlab script for all calculations required for
%               ASEN 5090 Homework 8
%
%                 __...____________________          ,
%                `(\ [ ===NCC-1700===--|__|) ___..--"_`--.._____
%                  `"""""""""""""""""| |""` [_""_-___________"_/
%                                    | |   /..../`'-._.-'`
%                                ____| |__/::..'_
%                               |\ ".`"` '_____//\
%                               `"'-.   """""  \\/
%                                    `""""""""""`
% <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
%% Questions to Answer (First for ease of grading)
type('answers.txt')

%% Setup Work Space
clc;clear all;close all
tic;
screen_size = get(0,'ScreenSize');
sw = screen_size(3);    % Screen Width
sh = screen_size(4);    % Screen Height
addpath HW8_files
soln_format = '|  %2.0f | %15.3f | %7.3f | %12.3f | %6.3f | %9.3f | %3.2f | \t\n';
debug = 0;


%% Setup Problem
%------Define Navigation and Observation File
RINEX_FILES = {'joze2640.onehour','onsa2640.onehour'};
nav_msg  = 'brdc2640.12n';

%------Define Orbit determination parameters
params.mu = 3.986005e14;        % Gravitational param [m^3/s^2]
params.we = 7.2921151467e-5;    % Earth's rotation rate [rad/s]

%------Define speed of light
params.c = 299792458; % [m/s]

params.options=optimset('Display','off','TolFun',1e-10,'TolX',1e-10);

%------Elevation Mask
el_mask = 10; %degrees


%------Define Zenith Correction for each site
Tzenith = [2.4086, 2.3858]; %[m]


%------Read navigation message content
nav_data = read_GPSbroadcast(nav_msg); % Returns [n x 25] matrix of sat orbit information
%                  col1: prn, PRN number of satellite
%                  col2: M0, mean anomaly at reference time, rad
%                  col3: delta_n, mean motion difference from computed value, rad/s
%                  col4: ecc, eccentricity of orbit
%                  col5: sqrt_a, square root of semi-major axis, m^0.5
%                  col6: Loa, longitude of ascending node of orbit plane at weekly epoch, rad
%                  col7: incl, inclination angle at reference time, rad
%                  col8: perigee, argument of perigee, rad
%                  col9: ra_rate, rate of change of right ascension, rad/s
%                 col10: i_rate, rate of change of inclination angle, rad/s
%                 col11: Cuc, amplitude of the cosine harmonic correction term to the argument of latitude
%                 col12: Cus, amplitude of the sine harmonic correction term to the argument of latitude
%                 col13: Crc, amplitude of the cosine harmonic correction term to the orbit radius
%                 col14: Crs, amplitude of the sine harmonic correction term to the orbit radius
%                 col15: Cic, amplitude of the cosine harmonic correction term to the angle of inclination
%                 col16: Cis, amplitude of the cosine harmonic correction term to the angle of inclination
%                 col17: Toe, reference time ephemeris (seconds into GPS week)
%                 col18: IODE, issue of data (ephemeris)
%                 col19: GPS_week, GPS Week Number (to go with Toe)
%                 col20: Toc, time of clock
%                 col21: Af0, satellite clock bias (sec)
%                 col22: Af1, satellite clock drift (sec/sec)
%                 col23: Af2, satellite clock drift rate (sec/sec/sec)
%                 col24: blank (zero)
%                 col25: health, satellite health (0=good and usable)

%% Calculate  Pre-Fit Residuals
for file_idx=1:length(RINEX_FILES)
    rinex_file = RINEX_FILES{file_idx};
    fprintf('Processing Rinex file %s\n', rinex_file)
    
    %% Read Observation Files, Sort Data
    %------Read a-priori receiver position from header of RINEX obs file
    [ fid, rec_xyz, observables ] = read_rinex_header( rinex_file );
    [rec_lla] = ecef2lla(rec_xyz');
    
    %------Form least squares like variables
    xr = rec_xyz(1); yr = rec_xyz(2); zr = rec_xyz(3);
    X = [xr, yr, zr, 1]; 
    
    %------Read Observation file
    obs_data    = read_rinex_obs3(rinex_file);
    cols        = obs_data.col; % Structure of column index descriptions
    %------Make nice column addressing variables (P1_col, P2_col ... etc)
    fields = fieldnames(cols);
    for kk=1:length(fields)
        eval(cell2mat([fields(kk),'_col = cols.',fields(kk),';']));
    end
    
    %------Only look at first epoch
    [GPSSecAryUn,secs_idx] = unique(obs_data.data(:,TOW_col));
    PRNS = obs_data.data(: , PRN_col);
    GPSWeekAry = obs_data.data(: , WEEK_col);
    GPSSecAry = obs_data.data(: , TOW_col);
    
    %% Fetch/Compute Pseudorange Values
    
    %------Allocate
    rho_obs = zeros(1, length(PRNS));
    rho_model = rho_obs;
    el = rho_obs;
    res = rho_obs;
    ionFree = rho_obs;
    sat_prn = rho_obs;
    epoch_iter = 0;
    for sec_idx = secs_idx'
        epoch_iter = epoch_iter + 1;
        
        %% Calculate "Modeled" Pseudorange
        %------Setup Range Finding
        GPS_SOW = GPSSecAry(sec_idx);
        GPS_Week = GPSWeekAry(sec_idx);
        params.Secs = GPS_SOW; %(GPS_Secs(1))  % Seconds used to calculate seconds since epoch
        
        %------Iterate over epoch satellite data
        Nsats = sum(GPSSecAry == GPSSecAry(sec_idx));
        iter = 0; clear H y
        for sat = 1:Nsats
            data_idx = sec_idx+sat-1;
            iter = iter + 1;
            PRN = obs_data.data(data_idx,PRN_col);
            
            %------Calculate Geometric Range
            [R, rel_dt, satXYZ] = getSatGeomRange(rec_xyz', GPS_Week, GPS_SOW, PRN, nav_data, params);
            xs = satXYZ(1); ys = satXYZ(2); zs = satXYZ(3);
            
            %------Check Elevation Angle
            [az, el(iter), r] = ecef2azelrange(satXYZ', rec_xyz);
            if el(iter) < el_mask
                iter=iter-1;
                continue
            end
            rel_corr = rel_dt*params.c;
            
            %------Get clock correction
            sat_clk_t_corr = getSatClockCorrection(GPS_Week, GPS_SOW, PRN, nav_data);
            
            %------Get Satellite Correction
            sat_corr = sat_clk_t_corr*params.c;
            
            %------Get Tropospheric Correction
            Tropo_corr = getTropoCorrection(Tzenith(file_idx), el(iter) );
            rho_model(iter) = R - sat_corr + Tropo_corr + rel_corr;
            
            %% Fetch Observed Pseudoranges
            %------Get Observed pseudorange
            P2 = obs_data.data(data_idx,P2_col);
            
            if sum(strcmp(observables,'P1'))>0
                %------Retrieve P1 as 2nd freq pseudorange
                PorC1 = obs_data.data(data_idx,P1_col);
%                 rho_obs(iter) = P1;                
            else
                %------Retrieve C1 as 2nd freq pseudorange
                PorC1 = obs_data.data(data_idx,C1_col);
%                 rho_obs(iter) = C1;
            end
            
            %------Use ONLY ionosphere free. Uncomment linesto use what data we have 
            if P2==0
                iter=iter-1;
                continue
%                 rho_obs(iter) = PorC1;
            elseif PorC1==0
                iter=iter-1;
                continue
%                 rho_obs(iter) = P2;
            else 
                rho_obs(iter) = 2.5457*PorC1-1.5457*P2;
            end
            
            %------Populate Least Squares Variables
            H(iter,:) = [(xr-xs)/R, (yr-ys)/R, (zr-zs)/R, 1]; %??? What about clock???
            % same as (rec_xyz' - satXYZ)/R
            y(iter) = rho_obs(iter) - rho_model(iter);
            
            sat_prn(iter) = PRN;
            
            if epoch_iter == 1 && file_idx == 1 && debug == 1
                if sat == 1
                    fprintf('|_PRN_|________P3_______|___Geom Range___|____satClk____|__rel__|__Tropo___|___prefit___|\n')
                end
                fprintf(1,soln_format,PRN,...
                    rho_obs(iter), R,sat_corr,...
                    rel_corr,Tropo_corr,y(iter))
            end
            
        end     % End Satellite Iteration
        %------Obtain least squares correction
        del_x(epoch_iter,:) = transpose((H'*H)\H'*y'); 
        P = inv(H'*H).*(0.5)^2;
        
        %------Rotate
        rec_xyz_adj = repmat(rec_xyz', epoch_iter, 1) - del_x(:,1:3);
        rec_lla_adj = ecef2lla(rec_xyz_adj);
        lat_station =  rec_lla_adj(epoch_iter,1);
        lon_station = rec_lla_adj(epoch_iter,2);
        P(1:3,1:3) = rotateCovariance(P(1:3,1:3), lat_station,lon_station);
        sigmas(epoch_iter,:) = sqrt(diag(P))';

        key_epoch = 2;
        if epoch_iter == key_epoch
            fprintf('\n\n----------------------------%s-------------------------',rinex_file)
            rec_xyz_adj = repmat(rec_xyz', epoch_iter, 1) - del_x(:,1:3);
            rec_lla_adj = ecef2lla(rec_xyz_adj);
            [de, dn, du] = ecef2enuv(del_x(key_epoch,1), ...
                                     del_x(key_epoch,2), ...
                                     del_x(key_epoch,3), ...
                                     rec_lla_adj(key_epoch,1),rec_lla_adj(key_epoch,2));
           fprintf('\nEast/Sig (m) %3.3f %3.3f\n',de,sigmas(epoch_iter,1)) 
           fprintf('North/Sig (m) %3.3f %3.3f\n',dn,sigmas(epoch_iter,2)) 
           fprintf('Up/Sig (m) %3.3f %3.3f\n',du,sigmas(epoch_iter,3)) 
           fprintf('Clk/Sig (m) %5.3f %3.3f\n',del_x(key_epoch,4),sigmas(epoch_iter,4))
        end
    end     % End time iteration
     

    [de, dn, du] = ecef2enuv(del_x(:,1), ...
                             del_x(:,2), ...
                             del_x(:,3), ...
                             rec_lla_adj(:,1),rec_lla_adj(:,2));
%   or...
    [xe,yn,zu]=ecef2enu(del_x(:,1),del_x(:,2),del_x(:,3),...
                            rec_lla_adj(:,1),rec_lla_adj(:,2),rec_lla_adj(:,3),oblateSpheroid);
    
    t = linspace(GPSSecAryUn(1),GPSSecAryUn(end),length(GPSSecAryUn));
    t = (t-t(1))/60;
    figure; subplot(2,1,1);
    plot(t,[de,dn,du])
    xlabel('Minutes Since First Epoch');ylabel('Delta [m]'); legend('East','North','Up')
    title(['Error for ', rinex_file])
    subplot(2,1,2)
    plot(t,sigmas(:,1:3))
    xlabel('Minutes Since First Epoch');ylabel('STD'); legend('East','North','Up')
    title(['Error for ', rinex_file])
    
%     ecef2enuv()
    
    %------Remove data with '0' observation
    zs = rho_obs == 0;
    rho_obs(zs) = []; rho_model(zs) = [];
clear del_x H
    
end     % End Rinex File Iteration


%% Clean, Reformat
figure_awesome


%% SUPPORTING FUNCTION - Homework8_main.m
type('Homework8_main.m')

%% SUPPORTING FUNCTION - getSatGeomRange.m
type('getSatGeomRange.m')

%% SUPPORTING FUNCTION - date2GPSTime.m
type('date2GPSTime.m')

%% SUPPORTING FUNCTION - findNearestEphem.m
type('findNearestEphem.m')

%% SUPPORTING FUNCTION - calculateSatellitePosition.m
type('calculateSatellitePosition.m')

%% SUPPORTING FUNCTION - findFirstEpoch.m
type('findFirstEpoch.m')

%% SUPPORTING FUNCTION - getSatClockCorrection.m
type('getSatClockCorrection.m')

%% SUPPORTING FUNCTION - date2GPSTime.m
type('GPSTime2Date.m')

%% SUPPORTING FUNCTION - getTropoCorrection.m
type('getTropoCorrection.m')

fprintf('\nSim took %3.1f seconds to run\n',toc)
