% =========================================================================
%                       AUDIT EDF CHANNEL LABELS
% =========================================================================
%
%  PURPOSE
%  -------
%  Scans a folder of EDF files and extracts channel label information
%  from each file header. No signal data is ever loaded into memory,
%  making this script fast and suitable for large datasets.
%
%  OUTPUT
%  ------
%  Three CSV files are written to the same folder as the EDF files:
%
%    edf_label_counts.csv    — Every unique label found, sorted by frequency
%    edf_file_summary.csv    — Per-file channel count and montage group ID
%    edf_unique_montages.csv — Each distinct channel configuration found
%
%  REQUIREMENTS
%  ------------
%  Base MATLAB only. No toolboxes required.
%
%  USAGE
%  -----
%  1. Set 'inputFolder' (line 43) to the path of your EDF directory.
%  2. Press F5 or click Run.
%
%  NOTES ON EDF FORMAT
%  -------------------
%  The European Data Format (EDF) stores a fixed-length ASCII header at
%  the start of every file:
%    - Bytes   1–256  : global header (patient info, date, # of signals)
%    - Bytes 257–end  : per-signal headers (ns blocks of 256 bytes each),
%                       followed by the raw signal data records.
%  This script reads only the header bytes and closes the file immediately,
%  so memory usage is negligible regardless of recording duration.
%
%  VERSION: 1.0
% =========================================================================

% ---- USER SETTINGS -------------------------

inputFolder = '/home/yourpath';

% -------------------------------------------------------------------------


% =========================================================================
%  SECTION 0 — INPUT VALIDATION
%  Check that the folder exists and contains EDF files before doing anything
% =========================================================================

if ~isfolder(inputFolder)
    error('Input folder does not exist:\n  %s', inputFolder);
end

% dir() searches for files matching '*.EDF'
% On Linux the extension is case-sensitive — change to '*.edf' if needed
files = dir(fullfile(inputFolder, '*.EDF'));

if isempty(files)
    error('No .EDF files found in:\n  %s', inputFolder);
end

fprintf('Found %d EDF file(s) in:\n  %s\n\n', numel(files), inputFolder);


% =========================================================================
%  SECTION 1 — PRE-ALLOCATION
%  Create empty containers before the loop so MATLAB does not need to
%  resize arrays on every iteration (more efficient for large datasets)
% =========================================================================

nFiles     = numel(files);
fileNames  = strings(nFiles, 1);   % one string per file
nChannels  = NaN(nFiles, 1);       % NaN = unread or failed
labelLists = strings(nFiles, 1);   % all labels for one file joined as a string
allLabels  = {};                   % flat pool of every label across all files


% =========================================================================
%  SECTION 2 — MAIN LOOP: READ EACH EDF HEADER
% =========================================================================

for f = 1 : nFiles

    filePath     = fullfile(files(f).folder, files(f).name);
    fileNames(f) = string(files(f).name);

    fprintf('  Reading %d / %d : %s\n', f, nFiles, files(f).name);

    try

        % -----------------------------------------------------------------
        %  STEP 2.1 — Open the file in binary read mode
        %  'ieee-le' = little-endian byte order (required by EDF standard)
        % -----------------------------------------------------------------
        fid = fopen(filePath, 'r', 'ieee-le');
        if fid == -1
            error('fopen() failed — check file permissions.');
        end

        % -----------------------------------------------------------------
        %  STEP 2.2 — Read the global header (always exactly 256 bytes)
        %  '*char' tells fread to return raw characters instead of numbers.
        %  The trailing apostrophe transposes the column vector to a string.
        % -----------------------------------------------------------------
        globalHdr = fread(fid, 256, '*char')';

        % -----------------------------------------------------------------
        %  STEP 2.3 — Parse the number of signals (ns)
        %  Per the EDF spec, bytes 253–256 of the global header contain
        %  the number of signals as a left-justified ASCII integer
        % -----------------------------------------------------------------
        ns = str2double(strtrim(globalHdr(253:256)));

        if isnan(ns) || ns < 1
            fclose(fid);
            error('Could not parse number of signals from header (bytes 253–256).');
        end

        % -----------------------------------------------------------------
        %  STEP 2.4 — Read all per-signal headers (ns × 256 bytes)
        %  These bytes follow immediately after the global header.
        %  Important: fields are stored COLUMN-WISE across all signals —
        %  i.e., ALL labels come first (ns × 16 bytes), then ALL transducer
        %  types (ns × 80 bytes), etc. — NOT one full 256-byte block per signal.
        % -----------------------------------------------------------------
        signalHdr = fread(fid, ns * 256, '*char')';
        fclose(fid);

        % -----------------------------------------------------------------
        %  STEP 2.5 — Extract channel labels
        %  Labels occupy the first section: ns consecutive 16-byte fields.
        %  strtrim() removes the trailing spaces EDF uses as padding.
        % -----------------------------------------------------------------
        labels = cell(1, ns);
        for ch = 1 : ns
            startByte  = (ch - 1) * 16 + 1;   % first byte of this label
            endByte    = startByte + 15;        % last byte (16 bytes total)
            labels{ch} = strtrim(signalHdr(startByte : endByte));
        end

        % -----------------------------------------------------------------
        %  STEP 2.6 — Handle empty labels
        %  Some devices write blank labels for unused channels. Replace them
        %  with a placeholder so they do not silently disappear from counts.
        % -----------------------------------------------------------------
        emptyMask = cellfun(@isempty, labels);
        if any(emptyMask)
            warning('audit_edf:emptyLabel', ...
                    '%d empty label(s) in %s — replaced with UNKNOWN_N.', ...
                    sum(emptyMask), files(f).name);
            for k = find(emptyMask)
                labels{k} = sprintf('UNKNOWN_%d', k);
            end
        end

        % -----------------------------------------------------------------
        %  STEP 2.7 — Store results for this file
        %  labelLists stores all labels as one pipe-separated string, e.g.:
        %  "Fp1 | Fp2 | Fz | Cz" — used later for montage comparison
        % -----------------------------------------------------------------
        nChannels(f)  = ns;
        labelLists(f) = string(strjoin(labels, ' | '));
        allLabels     = [allLabels, labels];   %#ok<AGROW>

    catch ME
        % If anything goes wrong, close the file (if still open) and log
        % the error — the loop continues with the remaining files
        if exist('fid', 'var') && fid ~= -1
            fclose(fid);
        end
        warning('audit_edf:readError', ...
                'Could not read %s\n  Reason: %s', files(f).name, ME.message);
        labelLists(f) = "<READ ERROR>";
    end

end % end of main loop

fprintf('\nFinished reading all files.\n\n');


% =========================================================================
%  SECTION 3 — GLOBAL LABEL COUNTS
%  Count how many times each unique label appears across ALL files.
%  A label present in only a subset of files may indicate recording
%  inconsistencies or equipment changes across sessions.
% =========================================================================

if isempty(allLabels)
    warning('audit_edf:noLabels', ...
            'No labels could be read from any file. Label count table is empty.');
    labelCountTable = table(string({}), zeros(0,1), ...
                            'VariableNames', {'Label', 'Count'});
else
    % unique() returns sorted unique values and an index (idx) mapping each
    % element of allLabels to its position in uniqueLabels
    [uniqueLabels, ~, idx] = unique(allLabels);

    % accumarray() sums the count of elements mapping to each unique label
    counts = accumarray(idx(:), 1);

    labelCountTable = table(string(uniqueLabels(:)), counts(:), ...
                            'VariableNames', {'Label', 'Count'});

    % Sort descending so the most common labels appear at the top
    labelCountTable = sortrows(labelCountTable, 'Count', 'descend');
end

fprintf('=== GLOBAL LABEL COUNTS ===\n');
disp(labelCountTable);


% =========================================================================
%  SECTION 4 — PER-FILE SUMMARY
%  One row per file showing filename and number of channels.
%  The full label list and montage ID are also stored (used in Section 5).
% =========================================================================

fileSummaryTable = table(fileNames, nChannels, labelLists, ...
                         'VariableNames', {'FileName', 'NChannels', 'LabelList'});

fprintf('=== FILE SUMMARY (channel counts) ===\n');
disp(fileSummaryTable(:, {'FileName', 'NChannels'}));


% =========================================================================
%  SECTION 5 — MONTAGE CONSISTENCY CHECK
%  Two files share the same montage if their label strings are identical
%  (same channels in the same order). Each unique configuration is assigned
%  an integer MontageID so files can be grouped and compared easily.
%
%  Ideal result  → Unique montages: 1  (all files have the same channels)
%  Problem case  → Unique montages: N  (N different channel configurations)
% =========================================================================

% unique() on the labelLists string array assigns the same montageID to
% any two files whose label string is character-for-character identical
[uniqueMontages, ~, montageID] = unique(labelLists);

% Append the montage group ID to the per-file table
fileSummaryTable.MontageID = montageID;

montageTable = table((1 : numel(uniqueMontages))', uniqueMontages, ...
                     'VariableNames', {'MontageID', 'LabelList'});

fprintf('=== UNIQUE MONTAGES FOUND ===\n');
disp(montageTable);


% =========================================================================
%  SECTION 6 — QUICK CHECKS SUMMARY
%  A compact overview printed to the Command Window for a fast sanity check
% =========================================================================

validNChannels      = nChannels(~isnan(nChannels));   % exclude failed files
uniqueChannelCounts = unique(validNChannels);
nReadable           = sum(~isnan(nChannels));
nUnreadable         = sum( isnan(nChannels));

fprintf('=== QUICK CHECKS ===\n');
fprintf('  Total files            : %d\n',   nFiles);
fprintf('  Successfully read      : %d\n',   nReadable);
fprintf('  Failed to read         : %d\n',   nUnreadable);

if ~isempty(uniqueChannelCounts)
    fprintf('  Unique channel counts  : %s\n', mat2str(uniqueChannelCounts'));
else
    fprintf('  Unique channel counts  : (none — no files were readable)\n');
end

fprintf('  Unique montages        : %d\n\n', numel(uniqueMontages));

if nUnreadable > 0
    fprintf('[WARNING] %d file(s) could not be read. See warnings above.\n\n', ...
            nUnreadable);
end


% =========================================================================
%  SECTION 7 — SAVE RESULTS TO CSV
%  Three CSV files are written to the input folder.
%  writetable() creates the file if it does not exist and overwrites it
%  on subsequent runs — no manual cleanup needed between executions.
% =========================================================================

outLabelCounts = fullfile(inputFolder, 'edf_label_counts.csv');
outFileSummary = fullfile(inputFolder, 'edf_file_summary.csv');
outMontages    = fullfile(inputFolder, 'edf_unique_montages.csv');

try
    writetable(labelCountTable,  outLabelCounts);
    writetable(fileSummaryTable, outFileSummary);
    writetable(montageTable,     outMontages);

    fprintf('CSV files saved to:\n');
    fprintf('  %s\n', outLabelCounts);
    fprintf('  %s\n', outFileSummary);
    fprintf('  %s\n', outMontages);

catch ME
    warning('audit_edf:saveError', ...
            'Could not save CSV files.\n  Reason: %s\n  Check write permissions for: %s', ...
            ME.message, inputFolder);
end

% =========================================================================
%  END OF SCRIPT
% =========================================================================
