%% organize_epochs.m
% Copies epochs 1-10 (per level+frequency combination) from batch folders
% to a destination directory, and organizes .log and .pkl files.
%
% STRUCTURE EXPECTED:
%   [batch_folder]/
%       something.log
%       something.pkl
%       [subject]EDF/
%           [subject]_[level]_level_[frequency]Hz_Epoch_1.txt
%           ...
%           [subject]_[level]_level_[frequency]Hz_Epoch_N.txt
%
% OUTPUT STRUCTURE:
%   [dest_root]/
%       [subject]EDF/
%           [subject]_[level]_level_[frequency]Hz_Epoch_1.txt
%           ...  (only epochs 1-10)
%       log_files/
%           something.log
%       pkl_files/
%           something.pkl

% =========================================================================
%                        USER CONFIGURATION
% =========================================================================

% List of batch folder paths to process
batch_folders = {
    
    'FOLDERPATH', ...
};

% Destination root folder where results will be written
dest_root = 'folderpath'; 

% Maximum number of epochs to keep per level+frequency combination
max_epochs = 10;

% =========================================================================
%                          MAIN PROCESSING
% =========================================================================

% Create destination root if it doesn't exist
if ~exist(dest_root, 'dir')
    mkdir(dest_root);
    fprintf('Created destination root: %s\n', dest_root);
end

% Create log_files and pkl_files directories
log_dest  = fullfile(dest_root, 'log_files');
pkl_dest  = fullfile(dest_root, 'pkl_files');
if ~exist(log_dest, 'dir'),  mkdir(log_dest);  end
if ~exist(pkl_dest, 'dir'),  mkdir(pkl_dest);  end

total_copied = 0;
total_logs   = 0;
total_pkls   = 0;

for b = 1:numel(batch_folders)
    batch_path = batch_folders{b};

    if ~exist(batch_path, 'dir')
        warning('Batch folder not found, skipping: %s', batch_path);
        continue;
    end

    fprintf('\n=== Processing batch: %s ===\n', batch_path);

    % --- Copy .log files ---
    log_files = dir(fullfile(batch_path, '*.log'));
    for f = 1:numel(log_files)
        src  = fullfile(batch_path, log_files(f).name);
        dst  = fullfile(log_dest, log_files(f).name);
        copyfile(src, dst);
        fprintf('  [LOG]  Copied: %s\n', log_files(f).name);
        total_logs = total_logs + 1;
    end

    % --- Copy .pkl files ---
    pkl_files = dir(fullfile(batch_path, '*.pkl'));
    for f = 1:numel(pkl_files)
        src  = fullfile(batch_path, pkl_files(f).name);
        dst  = fullfile(pkl_dest, pkl_files(f).name);
        copyfile(src, dst);
        fprintf('  [PKL]  Copied: %s\n', pkl_files(f).name);
        total_pkls = total_pkls + 1;
    end

    % --- Find all [subject]EDF subfolders ---
    all_entries = dir(batch_path);
    edf_folders = all_entries([all_entries.isdir] & ...
                  ~strcmp({all_entries.name}, '.') & ...
                  ~strcmp({all_entries.name}, '..') & ...
                  endsWith({all_entries.name}, 'EDF'));

    if isempty(edf_folders)
        fprintf('  [WARN] No *EDF subfolders found in: %s\n', batch_path);
        continue;
    end

    for e = 1:numel(edf_folders)
        edf_name   = edf_folders(e).name;           % e.g. '122EDF'
        edf_src    = fullfile(batch_path, edf_name);
        edf_dst    = fullfile(dest_root, edf_name);

        % Create subject destination folder
        if ~exist(edf_dst, 'dir')
            mkdir(edf_dst);
        end

        fprintf('  [EDF]  Subject folder: %s\n', edf_name);

        % Get all epoch txt files in this EDF folder
        txt_files = dir(fullfile(edf_src, '*.txt'));

        if isempty(txt_files)
            fprintf('         No .txt files found, skipping.\n');
            continue;
        end

        % --- Group files by [level]_[frequency] combination ---
        % Filename pattern: [subject]_[level]_level_[frequency]Hz_Epoch_[N].txt
        % We extract the combination key = everything before _Epoch_
        combo_map = containers.Map('KeyType', 'char', 'ValueType', 'any');

        for t = 1:numel(txt_files)
            fname = txt_files(t).name;

            % Extract epoch number from filename
            tok = regexp(fname, '_Epoch_(\d+)\.txt$', 'tokens');
            if isempty(tok)
                fprintf('         [SKIP] Cannot parse epoch number: %s\n', fname);
                continue;
            end
            epoch_num = str2double(tok{1}{1});

            % Extract combo key (everything before _Epoch_)
            combo_key = regexprep(fname, '_Epoch_\d+\.txt$', '');

            % Store in map grouped by combo key
            if isKey(combo_map, combo_key)
                entry = combo_map(combo_key);
            else
                entry = struct('files', {{}}, 'epochs', []);
            end
            entry.files{end+1} = fname;
            entry.epochs(end+1) = epoch_num;
            combo_map(combo_key) = entry;
        end

        % --- For each combo, copy only epochs 1 to max_epochs ---
        combos = keys(combo_map);
        for c = 1:numel(combos)
            combo_key = combos{c};
            entry     = combo_map(combo_key);

            % Filter to epochs <= max_epochs
            valid_idx = entry.epochs <= max_epochs;
            valid_files  = entry.files(valid_idx);
            valid_epochs = entry.epochs(valid_idx);

            if isempty(valid_files)
                fprintf('         [WARN] No epochs 1-%d found for: %s\n', ...
                        max_epochs, combo_key);
                continue;
            end

            fprintf('         Combo: %s  →  %d epoch(s) to copy\n', ...
                    combo_key, numel(valid_files));

            % Sort by epoch number for tidy output
            [~, sort_idx] = sort(valid_epochs);
            valid_files   = valid_files(sort_idx);

            for v = 1:numel(valid_files)
                src = fullfile(edf_src, valid_files{v});
                dst = fullfile(edf_dst, valid_files{v});
                copyfile(src, dst);
                total_copied = total_copied + 1;
            end
        end
    end
end

fprintf('\n=========================================\n');
fprintf('Done!\n');
fprintf('  Epoch .txt files copied : %d\n', total_copied);
fprintf('  .log files copied       : %d\n', total_logs);
fprintf('  .pkl files copied       : %d\n', total_pkls);
fprintf('  Destination             : %s\n', dest_root);
fprintf('=========================================\n');
