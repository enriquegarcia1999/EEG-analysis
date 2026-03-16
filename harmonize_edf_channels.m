% =========================================================================
%                   HARMONIZE EDF CHANNEL LABELS
%              Prepare EDF files for EEG-Pype / MNE-Python
% =========================================================================
%
%  PURPOSE
%  -------
%  Reads each EDF file, standardizes channel names, removes non-EEG
%  auxiliary channels, and writes a clean EDF to an output folder.
%  Channel ORDER is preserved exactly as in the original file.
%  Original files are never modified.
%
%  WHAT THIS SCRIPT DOES (per file)
%  ---------------------------------
%  1. Strips the "EEG " prefix from all EEG channel names
%       e.g.  "EEG Fp1"  -->  "Fp1"
%  2. Renames legacy 10-20 labels to their modern MNE equivalents
%       T3 --> T7,  T4 --> T8,  T5 --> P7,  T6 --> P8
%       T1 --> F9,  T2 --> F10
%       (also handles alternate forms: "T1-G19" --> F9, "T2-G19" --> F10)
%  3. Removes non-EEG auxiliary channels — the following are dropped:
%       - ECG
%       - All "Unspec *"  channels (device telemetry)
%       - All "EOG *"     channels
%       - All "EEG IN*"   channels  (e.g. IN2A-IN2, IN3A-IN3)
%       - All "EEG *-G19" channels  (already renamed above where relevant)
%       - "EDF Annotations" is KEPT (used as event cues)
%  4. Writes a new EDF to the output folder using the same filename.
%       Channel order in the output matches the original file.
%
%  OUTPUT
%  ------
%  Clean EDF files written to:  <inputFolder>/EDF_harmonized/
%  A summary CSV log:           <inputFolder>/EDF_harmonized/harmonization_log.csv
%
%  REQUIREMENTS
%  ------------
%  Base MATLAB only. No toolboxes required.
%
%  USAGE
%  -----
%  1. Set 'inputFolder' below to your EDF directory.
%  2. Press F5 or click Run.
%
%  NOTES
%  -----
%  EDF writing follows the EDF+ spec. Signal headers are copied verbatim
%  from the source file — only the label field is updated for renamed
%  channels, and dropped channels are excluded entirely.
%
%  VERSION: 1.0
% =========================================================================

% ---- USER SETTINGS ------------------------------------------------------

inputFolder = '/home/ac/egarciavaldes/Desktop/EEG/EDF_working_copy';

% -------------------------------------------------------------------------


% =========================================================================
%  SECTION 0 — CHANNEL DEFINITIONS
% =========================================================================

% Map from source label (after stripping "EEG " prefix) to MNE target name.
% Only channels whose name differs from the MNE standard need an entry.
% Hyphens in source names are replaced with underscores before lookup
% (e.g. "T1-G19" is looked up as "T1_G19") — see Step 2.2.
legacyRename = struct( ...
    'T3',     'T7',  ...
    'T4',     'T8',  ...
    'T5',     'P7',  ...
    'T6',     'P8',  ...
    'T1',     'F9',  ...
    'T2',     'F10', ...
    'T1_G19', 'F9',  ...
    'T2_G19', 'F10'  ...
);

% Channels to DROP (matched against the ORIGINAL label, before renaming).
% Uses exact string match — add more entries here if needed.
dropList = { ...
    'ECG',             ...  % cardiac channel — not used in this pipeline
    'EOG LOC',         ...  % ocular channel
    'EOG ROC',         ...  % ocular channel
    'Unspec AH',       ...  % device telemetry
    'Unspec Sig Buf',  ...
    'Unspec CPU',      ...
    'Unspec Mem',      ...
    'Unspec App CPU',  ...
    'Unspec App Mem',  ...
    'Unspec App VMem', ...
    'Unspec Network',  ...
    'Unspec Dev Cntr', ...
    'Unspec Rec Cntr', ...
    'Unspec Rec Crc',  ...
    'Unspec Cust. 5',  ...
    'Unspec Cust. 6',  ...
    'EEG Cust. 1',     ...  % unknown custom channels
    'EEG Cust. 2',     ...
    'EEG Cust. 3',     ...
    'EEG Cust. 4',     ...
    'EEG IN2A-IN2',    ...  % non-standard input channels
    'EEG IN3A-IN3'     ...
};


% =========================================================================
%  SECTION 1 — SETUP
% =========================================================================

if ~isfolder(inputFolder)
    error('Input folder does not exist:\n  %s', inputFolder);
end

outputFolder = fullfile(inputFolder, 'EDF_harmonized');
if ~isfolder(outputFolder)
    mkdir(outputFolder);
    fprintf('Created output folder:\n  %s\n\n', outputFolder);
end

files = dir(fullfile(inputFolder, '*.EDF'));
if isempty(files)
    error('No .EDF files found in:\n  %s', inputFolder);
end

nFiles = numel(files);
fprintf('Found %d EDF file(s). Starting harmonization...\n\n', nFiles);

% Pre-allocate log columns
logFileNames = strings(nFiles, 1);
logOrigChans = NaN(nFiles, 1);
logKeptChans = NaN(nFiles, 1);
logDropped   = strings(nFiles, 1);
logStatus    = strings(nFiles, 1);


% =========================================================================
%  SECTION 2 — MAIN LOOP
% =========================================================================

for f = 1 : nFiles

    srcPath         = fullfile(files(f).folder, files(f).name);
    dstPath         = fullfile(outputFolder, files(f).name);
    logFileNames(f) = string(files(f).name);

    fprintf('  Processing %d / %d : %s\n', f, nFiles, files(f).name);

    fid    = -1;
    fidOut = -1;

    try

        % -----------------------------------------------------------------
        %  STEP 2.1 — Read the full EDF file
        %  Signal data must be loaded because we are writing a new EDF
        %  containing only the kept channels
        % -----------------------------------------------------------------
        fid = fopen(srcPath, 'r', 'ieee-le');
        if fid == -1
            error('Cannot open source file.');
        end

        % Global header — 256 bytes, kept as raw bytes for faithful rewriting
        globalHdr     = fread(fid, 256, '*uint8')';
        globalHdrChar = char(globalHdr);

        % Parse the three fields we need from the global header
        nDataRecords = str2double(strtrim(globalHdrChar(237:244)));  % # data records
        ns           = str2double(strtrim(globalHdrChar(253:256)));  % # signals

        if isnan(ns) || ns < 1
            fclose(fid); fid = -1;
            error('Could not parse number of signals from header.');
        end

        % Per-signal header fields (stored column-wise across all channels)
        sigLabels     = readSignalField(fid, ns, 16);  % channel label
        sigTransducer = readSignalField(fid, ns, 80);  % transducer type
        sigPhysDim    = readSignalField(fid, ns,  8);  % physical dimension
        sigPhysMin    = readSignalField(fid, ns,  8);  % physical minimum
        sigPhysMax    = readSignalField(fid, ns,  8);  % physical maximum
        sigDigMin     = readSignalField(fid, ns,  8);  % digital minimum
        sigDigMax     = readSignalField(fid, ns,  8);  % digital maximum
        sigPrefilter  = readSignalField(fid, ns, 80);  % prefiltering info
        sigSamplesRec = readSignalField(fid, ns,  8);  % samples per data record
        sigReserved   = readSignalField(fid, ns, 32);  % reserved field

        % Convert samples-per-record to numeric array
        samplesPerRec = zeros(1, ns);
        for ch = 1 : ns
            samplesPerRec(ch) = str2double(strtrim(sigSamplesRec{ch}));
        end

        % Read all signal data (interleaved int16 samples, record by record)
        totalSamples = sum(samplesPerRec) * nDataRecords;
        rawData      = fread(fid, totalSamples, 'int16');
        fclose(fid); fid = -1;

        % De-interleave into one cell per channel
        signalData = cell(1, ns);
        ptr = 0;
        for rec = 1 : nDataRecords
            for ch = 1 : ns
                n              = samplesPerRec(ch);
                signalData{ch} = [signalData{ch}; rawData(ptr+1 : ptr+n)];
                ptr            = ptr + n;
            end
        end

        % -----------------------------------------------------------------
        %  STEP 2.2 — Decide which channels to keep and rename labels
        %
        %  Logic:
        %    - If the original label is in dropList  --> drop the channel
        %    - Otherwise strip "EEG " prefix, apply legacyRename --> keep
        %
        %  Channel ORDER is determined by their position in the source file.
        % -----------------------------------------------------------------
        keepIdx    = [];    % indices of channels to keep (in source order)
        newLabels  = {};    % renamed labels for kept channels
        droppedLbls = {};   % original labels of dropped channels

        for ch = 1 : ns
            origLabel = strtrim(sigLabels{ch});

            % Check drop list first (match against original label)
            if ismember(origLabel, dropList)
                droppedLbls{end+1} = origLabel; %#ok<AGROW>
                continue
            end

            % Strip "EEG " prefix
            lbl = origLabel;
            if strncmp(lbl, 'EEG ', 4)
                lbl = lbl(5:end);
            end

            % Replace hyphens with underscores for struct field lookup
            % e.g. "T1-G19" -> lookup key "T1_G19", renamed to "F9"
            lblKey = strrep(lbl, '-', '_');
            if isfield(legacyRename, lblKey)
                lbl = legacyRename.(lblKey);
            end

            keepIdx{end+1}   = ch;   %#ok<AGROW>
            newLabels{end+1} = lbl;  %#ok<AGROW>
        end

        keepIdx  = cell2mat(keepIdx);
        nsOut    = numel(keepIdx);

        logOrigChans(f) = ns;
        logKeptChans(f) = nsOut;
        logDropped(f)   = string(strjoin(droppedLbls, ' | '));

        % -----------------------------------------------------------------
        %  STEP 2.3 — Write the new EDF file
        %  Structure is identical to the source except:
        %    - ns field in global header is updated
        %    - header byte count is updated
        %    - only kept channels appear in signal headers and data records
        %    - renamed channels use their new label
        % -----------------------------------------------------------------
        fidOut = fopen(dstPath, 'w', 'ieee-le');
        if fidOut == -1
            error('Cannot create output file.');
        end

        % Update global header: number-of-signals (bytes 253-256)
        newGlobalHdr          = globalHdr;
        newGlobalHdr(253:256) = uint8(sprintf('%-4d', nsOut));

        % Update global header: total header bytes (bytes 185-192)
        newHdrBytes           = 256 + nsOut * 256;
        newGlobalHdr(185:192) = uint8(sprintf('%-8d', newHdrBytes));

        fwrite(fidOut, newGlobalHdr, 'uint8');

        % Write per-signal headers using the renamed labels for kept channels
        writeSignalField(fidOut, newLabels,                   16);
        writeSignalField(fidOut, sigTransducer(keepIdx),      80);
        writeSignalField(fidOut, sigPhysDim(keepIdx),          8);
        writeSignalField(fidOut, sigPhysMin(keepIdx),          8);
        writeSignalField(fidOut, sigPhysMax(keepIdx),          8);
        writeSignalField(fidOut, sigDigMin(keepIdx),           8);
        writeSignalField(fidOut, sigDigMax(keepIdx),           8);
        writeSignalField(fidOut, sigPrefilter(keepIdx),       80);
        writeSignalField(fidOut, sigSamplesRec(keepIdx),       8);
        writeSignalField(fidOut, sigReserved(keepIdx),        32);

        % Write data records — same order as source, kept channels only
        for rec = 1 : nDataRecords
            for k = 1 : nsOut
                ch  = keepIdx(k);
                n   = samplesPerRec(ch);
                idx = (rec-1)*n + 1 : rec*n;
                fwrite(fidOut, signalData{ch}(idx), 'int16');
            end
        end

        fclose(fidOut); fidOut = -1;

        logStatus(f) = "OK";
        fprintf('    -> Kept %d / %d channels. Dropped: %s\n', ...
                nsOut, ns, strjoin(droppedLbls, ', '));

    catch ME
        if fid    ~= -1, fclose(fid);    end
        if fidOut ~= -1, fclose(fidOut); end
        warning('harmonize_edf:fileError', ...
                'Failed on %s\n  Reason: %s', files(f).name, ME.message);
        logStatus(f)  = string(['ERROR: ' ME.message]);
        logDropped(f) = "N/A";
    end

end % end main loop

fprintf('\nDone. %d / %d files processed successfully.\n\n', ...
        sum(logStatus == "OK"), nFiles);


% =========================================================================
%  SECTION 3 — SAVE LOG
% =========================================================================

logTable = table(logFileNames, logOrigChans, logKeptChans, logDropped, logStatus, ...
                 'VariableNames', {'FileName', 'OrigChannels', 'KeptChannels', ...
                                   'DroppedChannels', 'Status'});

logPath = fullfile(outputFolder, 'harmonization_log.csv');
try
    writetable(logTable, logPath);
    fprintf('Log saved to:\n  %s\n', logPath);
catch ME
    warning('harmonize_edf:logError', 'Could not save log: %s', ME.message);
end


% =========================================================================
%  LOCAL HELPER FUNCTIONS
% =========================================================================

function fields = readSignalField(fid, ns, fieldWidth)
% Read one column-wise field block from the EDF per-signal header.
% Returns a cell array of ns raw (unstripped) strings.
    raw    = fread(fid, ns * fieldWidth, '*char')';
    fields = cell(1, ns);
    for i = 1 : ns
        s         = (i-1) * fieldWidth + 1;
        fields{i} = raw(s : s + fieldWidth - 1);  % raw — trimming done later
    end
end

function writeSignalField(fid, values, fieldWidth)
% Write one column-wise field block to the output EDF.
% Each value is space-padded (or truncated) to exactly fieldWidth bytes.
    for i = 1 : numel(values)
        v   = char(strtrim(values{i}));
        v   = v(1 : min(end, fieldWidth));           % truncate if too long
        pad = repmat(' ', 1, fieldWidth - numel(v)); % pad with spaces
        fwrite(fid, uint8([v, pad]), 'uint8');
    end
end

% =========================================================================
%  END OF SCRIPT
% =========================================================================
