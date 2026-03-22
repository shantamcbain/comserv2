#!/usr/bin/perl
use strict;
use warnings;
use JSON;
use File::Spec;
use DateTime;

=head1 NAME

documentation_sync_audit.pl - Independent audit for DocumentationSyncAgent

=head1 DESCRIPTION

Generates a list of documentation files that need updating based on:
1. Code files changed (via git diff)
2. Code-to-documentation mappings (from RepositoryCodeAudit.json v2.0 - 1:N mapping)
3. Current documentation status (file exists, version, last updated)
4. Filter: Only PRIMARY docs (documentation_path), skip historical/tutorial/audit files

Output: JSON audit report that DocumentationSyncAgent can process independently.
Identifies ONLY docs that need updates - excludes docs already current from recent commits.

=head1 USAGE

    perl documentation_sync_audit.pl [options]
    
Options:
    --git-range       Git range to check (default: HEAD~1..HEAD for last commit)
                      Examples: HEAD~1..HEAD (last commit), HEAD~5..HEAD (last 5 commits),
                                HEAD~10..HEAD (last 10 commits), or any valid git range
    --output-file     Write audit to JSON file (optional)
    --verbose         Show detailed progress messages
    --check-duplicates Include deduplication analysis (detects files flagged multiple days without updates)

=head1 OUTPUT

JSON structure:
{
  "audit_timestamp": "2026-01-05T17:38:00Z",
  "git_range": "HEAD~10..HEAD",
  "files_changed": 25,You are the DocumentationSyncAgent, responsible for maintaining documentation consistency in the Comserv project. Your current task is to continue processing the documentation sync audit results.

## Current Status
- **Completed:** 8 documentation files have been updated/created:
  - DocumentationMetadataIndex.tt (CREATE)
  - RemoteDB controller (CREATE)
  - DBSchemaManager model (CREATE)
  - DocumentationRoleAccess.tt (CREATE)
  - RemoteDB utility (CREATE)
  - WebSearchResult.tt (UPDATE 0.01→0.02)
  - Grok.tt (CORRECTED to 0.01)
  - Ollama.tt (CORRECTED to 0.01)

- **Remaining:** 13 files from the latest audit (9 updates + 4 creates):
  1. /Documentation/controllers/SchemaComparison.tt (UPDATE 0.02→0.03)
  2. /Documentation/models/AiModelConfig.tt (CREATE)
  3. /Documentation/AiConversation.tt (UPDATE 0.01→0.02)
  4. /Documentation/CodeSearchIndex.tt (CREATE)
  5. /Documentation/models/RemoteDB.tt (UPDATE 1.00→1.01)
  6. /Documentation/models/Chat.tt (UPDATE 1.00→1.01)
  7. /Documentation/controllers/Admin.tt (UPDATE 1.12→1.13)
  8. /Documentation/controllers/AI.tt (UPDATE 1.13→1.14)
  9. /Documentation/controllers/Root.tt (UPDATE 0.02→0.03)

## Rules Reminder
- Use DocumentationTtTemplate.tt for new files
- Start new docs at version 0.01
- Increment existing docs by 0.01
- Add "Recent Changes" section for updates
- Use CSS variables, semantic HTML, TOC with anchors
- Update last_updated to current date (YYYY-MM-DD format)
- Follow sequential editing: one file at a time

## Task
Begin with the first remaining file: /Documentation/controllers/SchemaComparison.tt (UPDATE from 0.02 to 0.03, add Recent Changes section).

Read the existing file, update it according to the audit action, then confirm completion before proceeding to the next file.
  "documentation_files_needing_update": [
    {
      "code_file": "lib/Comserv/Controller/AI.pm",
      "documentation_file": "/Documentation/AI.tt",
      "exists": true,
      "reason": "Code changed in git diff",
      "last_updated": "2025-12-28",
      "version": "1.00",
      "action": "UPDATE - Bump version to 1.01, add Recent Changes section"
    }
  ],
  "summary": {
    "total_code_changes": 25,
    "docs_needing_update": 7,
    "docs_missing": 3,
    "ready_to_sync": true
  }
}

=cut

my $project_root = '/home/shanta/PycharmProjects/comserv2';
my $doc_reports_dir = "$project_root/Comserv/root/Documentation/AuditReports";

sub ensure_audit_dir {
    return 1 if -d $doc_reports_dir;
    mkdir $doc_reports_dir or die "Cannot create $doc_reports_dir: $!\n";
    return 1;
}

sub get_file_diff_preview {
    my ($file_path) = @_;
    my $full_path = "$project_root/$file_path";
    
    return undef unless -f $full_path;
    
    # Try to get git diff for committed changes first
    my $git_diff_cmd = "cd $project_root && git diff HEAD -- '$file_path' 2>/dev/null | head -15";
    my @diff_lines = ();
    
    open my $fh, '-|', $git_diff_cmd or return undef;
    while (<$fh>) {
        chomp;
        push @diff_lines, $_;
    }
    close $fh;
    
    # If no committed diff, try staged changes
    if (scalar(@diff_lines) == 0) {
        my $staged_cmd = "cd $project_root && git diff --staged -- '$file_path' 2>/dev/null | head -15";
        open $fh, '-|', $staged_cmd or return undef;
        while (<$fh>) {
            chomp;
            push @diff_lines, $_;
        }
        close $fh;
    }
    
    # Return preview (max 15 lines)
    return @diff_lines > 0 ? join("\n", @diff_lines[0..min(14, $#diff_lines)]) : undef;
}

sub min {
    my ($a, $b) = @_;
    return $a < $b ? $a : $b;
}
my $git_range = $ENV{GIT_RANGE} || 'HEAD~1..HEAD';
my $output_file = undef;
my $verbose = 0;
my $check_duplicates = 0;

# Parse command line args
foreach my $arg (@ARGV) {
    if ($arg =~ /--git-range=(.+)/) { $git_range = $1; }
    elsif ($arg =~ /--output-file=(.+)/) { $output_file = $1; }
    elsif ($arg eq '--verbose') { $verbose = 1; }
    elsif ($arg eq '--check-duplicates') { $check_duplicates = 1; }
}

sub get_changed_code_files {
    my ($range) = @_;
    my %files = ();  # Use hash to deduplicate
    
    # Get code files from THREE sources:
    # 1. Committed changes (git diff <range>)
    # 2. Staged changes (git diff --cached)
    # 3. Unstaged/modified (git diff)
    
    # Reason: Audit should find ALL code files needing doc updates,
    # not just committed ones. Staged and modified files also need docs.
    
    foreach my $cmd (
        "cd $project_root && git diff --name-status $range 2>/dev/null",
        "cd $project_root && git diff --cached --name-status 2>/dev/null",
        "cd $project_root && git diff --name-status 2>/dev/null"
    ) {
        open my $fh, '-|', $cmd or next;
        while (<$fh>) {
            chomp;
            my ($status, $path) = split /\t/, $_;
            next unless $path;
            next unless $status =~ /^[AMR]/;  # Added, Modified, Renamed
            
            # Only track Perl code files (.pm, .pl)
            $path =~ s{^Comserv/}{};
            $files{$path} = 1 if $path =~ /\.(pm|pl)$/;
        }
        close $fh;
    }
    
    return keys %files;  # Return deduplicated list
}

sub get_code_to_doc_mappings {
    # Load RepositoryCodeAudit.json v2.0 for 1:N code-to-documentation mappings
    my $audit_file = "$project_root/Comserv/root/Documentation/config/RepositoryCodeAudit.json";
    my %mappings = ();
    
    return %mappings unless -f $audit_file;
    
    open my $fh, '<', $audit_file or return %mappings;
    my $json_text = do { local $/; <$fh> };
    close $fh;
    
    my $audit = JSON->new->decode($json_text);
    
    # Build mappings: code_file => { primary_doc, related_docs }
    foreach my $full_key (keys %{$audit->{code_files}}) {
        my $entry = $audit->{code_files}{$full_key};
        my $primary_doc = $entry->{documentation_path};
        my $related = $entry->{related_documentation} || [];
        
        # Normalize key for mapping (remove Comserv/lib/ prefix for matching)
        my $normalized_key = $full_key;
        $normalized_key =~ s{^Comserv/lib/}{lib/};
        
        # Store primary doc for this code file
        if ($primary_doc) {
            # Normalize path to /Documentation/...
            my $norm_path = $primary_doc;
            $norm_path =~ s{^/?}{/} unless $norm_path =~ m{^/};
            $mappings{$normalized_key} = {
                primary_doc => $norm_path,
                related_docs => $related,
                doc_count => $entry->{doc_count} || 0
            };
        }
    }
    
    return %mappings;
}

sub get_doc_file_info {
    my ($doc_path) = @_;
    my $full_path = "$project_root/Comserv/root$doc_path";
    $full_path =~ s{\.tt$}{};  # Controller might not have .tt in master plan
    $full_path .= '.tt' unless $full_path =~ /\.tt$/;
    
    return {
        exists => (-f $full_path),
        path => $full_path,
        rel_path => $doc_path,
        last_updated => undef,
        version => undef
    } unless -f $full_path;
    
    # Parse .tt file for metadata
    open my $fh, '<', $full_path or return { exists => 0, path => $full_path };
    my $content = do { local $/; <$fh> };
    close $fh;
    
    my ($version) = $content =~ /page_version\s*=\s*"([^"]+)"/;
    my ($last_updated) = $content =~ /last_updated\s*=\s*"([^"]+)"/;
    
    return {
        exists => 1,
        path => $full_path,
        rel_path => $doc_path,
        last_updated => $last_updated,
        version => $version || '0.01'
    };
}

sub get_code_file_commit_timestamp {
    my ($code_file, $range) = @_;
    my $timestamp = undef;
    
    # Get the most recent commit timestamp for this file in the SPECIFIED RANGE ONLY
    # This is critical: must use the range parameter to get the actual commit date
    # not the original commit date from all history
    my $cmd = "cd $project_root && git log $range --format=%cI -- '$code_file' 2>/dev/null | head -1";
    open my $fh, '-|', $cmd or return undef;
    while (<$fh>) {
        chomp;
        next if /^$/;
        $timestamp = $_;
        last;
    }
    close $fh;
    
    return $timestamp;
}

sub parse_timestamp {
    my ($ts_str) = @_;
    return undef unless $ts_str;
    
    # Parse various formats
    
    # Format: "Tue Jan 06 2026 15:17:55 UTC" (day name month date year time)
    if ($ts_str =~ /\w+\s+(\w+)\s+(\d{2})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})/) {
        my %months = (Jan=>1, Feb=>2, Mar=>3, Apr=>4, May=>5, Jun=>6, Jul=>7, Aug=>8, Sep=>9, Oct=>10, Nov=>11, Dec=>12);
        my $month = $months{$1} || 1;
        return sprintf("%04d%02d%02d%02d%02d%02d", $3, $month, $2, $4, $5, $6);
    }
    
    # Format: "2026-01-10 14:42:00 UTC"
    if ($ts_str =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/) {
        return "$1$2$3$4$5$6";
    }
    
    # ISO8601 format: 2026-01-10T14:42:00+00:00
    if ($ts_str =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        return "$1$2$3$4$5$6";
    }
    
    # Date-only format: 2026-01-10 (assume start of day)
    if ($ts_str =~ /(\d{4})-(\d{2})-(\d{2})/) {
        return "$1$2${3}000000";
    }
    
    return undef;
}

sub was_doc_updated_in_range {
    my ($doc_path, $git_range) = @_;
    
    # Check if the documentation file (.tt) was committed in the specified git range
    # If it was, we can skip re-flagging it since it was already updated
    # This prevents re-flagging docs that were already updated in response to code changes
    
    # Normalize doc path for git diff
    my $git_path = $doc_path;
    $git_path =~ s{^/?Documentation}{Comserv/root/Documentation};
    
    # Check if .tt file was changed in this git range
    my $cmd = "cd $project_root && git diff --name-only $git_range -- '$git_path' 2>/dev/null | wc -l";
    open my $fh, '-|', $cmd or return 0;
    my $diff_count = <$fh>;
    close $fh;
    
    chomp $diff_count if defined $diff_count;
    return ($diff_count && $diff_count > 0) ? 1 : 0;
}

sub should_update_doc {
    my ($doc_info, $code_commit_ts, $code_file, $git_range, $doc_path) = @_;
    
    # If doc doesn't exist, always create it
    return 1 unless $doc_info->{exists};
    
    # CRITICAL FIX: Check if doc was already COMMITTED in this git range
    # Only skip if doc was finalized/committed. Don't skip for staged/unstaged docs.
    if (was_doc_updated_in_range($doc_path, $git_range)) {
        print "   ℹ️ Doc was already COMMITTED in this range, skipping\n" if $verbose;
        return 0;
    }
    
    # Check if doc was recently verified as current
    # If documentation is recent and accurate, skip even if code changed with minor updates
    my $doc_updated = parse_timestamp($doc_info->{last_updated});
    my $code_changed = parse_timestamp($code_commit_ts);
    
    if ($doc_updated && $code_changed) {
        # If doc is more recent than code change, it's already accurate
        if ($doc_updated >= $code_changed) {
            print "   ℹ️ Doc (last updated: $doc_info->{last_updated}) is current or more recent than code change, skipping\n" if $verbose;
            return 0;
        }
        
        # If doc is less than 5 days old, assume it's still accurate even if code changed
        # This prevents re-flagging for minor code changes (encoding, formatting, etc)
        my $now_dt = DateTime->now(time_zone => 'UTC');
        my $five_days_ago_dt = $now_dt->clone->subtract(days => 5);
        my $five_days_ago_ts = $five_days_ago_dt->strftime('%Y%m%d%H%M%S');
        
        if ($doc_updated >= $five_days_ago_ts) {
            print "   ℹ️ Doc is recent ($doc_info->{last_updated}), skipping to avoid re-flagging for minor code changes\n" if $verbose;
            return 0;
        }
    }
    
    # Check if code file has ACTUAL changes from any source (committed, staged, unstaged)
    # Use the same three-way check as get_changed_code_files
    my $has_changes = 0;
    
    foreach my $check_cmd (
        "cd $project_root && git diff $git_range -- '$code_file' 2>/dev/null | wc -l",
        "cd $project_root && git diff --cached -- '$code_file' 2>/dev/null | wc -l",
        "cd $project_root && git diff -- '$code_file' 2>/dev/null | wc -l"
    ) {
        open my $dfh, '-|', $check_cmd or next;
        my $diff_lines = <$dfh>;
        close $dfh;
        
        chomp $diff_lines if defined $diff_lines;
        if ($diff_lines && $diff_lines > 5) {
            $has_changes = 1;
            last;  # Found changes, no need to check further
        }
    }
    
    # If no actual changes in code from any source, skip
    return 0 if !$has_changes;
    
    # CRITICAL FIX: Allow BOTH committed AND new files (staged/unstaged)
    # Committed files: Only flag if in the specified range
    # New files: Flag even if not yet committed (so they get documented before commit)
    # This prevents circular updates while allowing new code to be documented immediately
    
    # Check if code file has changes in the COMMITTED RANGE
    my $committed_changes = `cd $project_root && git diff $git_range -- '$code_file' 2>/dev/null | wc -l`;
    chomp $committed_changes if defined $committed_changes;
    
    # If has changes in committed range, flag it
    if ($committed_changes && $committed_changes > 5) {
        return 1;
    }
    
    # If no committed changes but has staged/unstaged changes (NEW file), also flag it
    # This allows new files to be documented before committing to avoid post-commit documentation
    my $staged_or_unstaged = 0;
    foreach my $check_cmd (
        "cd $project_root && git diff --cached -- '$code_file' 2>/dev/null | wc -l",
        "cd $project_root && git diff -- '$code_file' 2>/dev/null | wc -l"
    ) {
        open my $dfh, '-|', $check_cmd or next;
        my $diff_lines = <$dfh>;
        close $dfh;
        chomp $diff_lines if defined $diff_lines;
        if ($diff_lines && $diff_lines > 5) {
            $staged_or_unstaged = 1;
            last;
        }
    }
    
    if ($staged_or_unstaged) {
        print "   ℹ️ Flagging NEW file (staged/unstaged) for documentation\n" if $verbose;
        return 1;
    }
    
    print "   ℹ️ Code changes not in any source (committed range, staged, or unstaged)\n" if $verbose;
    return 0;
}

sub determine_update_action {
    my ($doc_info) = @_;
    
    unless ($doc_info->{exists}) {
        # NEW documents must start at 0.01 per DocumentationTtTemplate.tt specification
        return "CREATE - New documentation file needed (controller recently added). START PAGE VERSION AT 0.01";
    }
    
    # For existing documents, increment the current version
    my $version = $doc_info->{version} || '0.01';
    my $next_version = sprintf("%.2f", $version + 0.01);
    my $action = "UPDATE - Bump version from $version to $next_version, add Recent Changes section";
    
    return $action;
}

sub detect_naming_mismatches {
    my (%code_to_doc) = @_;
    my @mismatches = ();
    
    # Check for code files that exist but documentation doesn't match naming
    foreach my $code_file (keys %code_to_doc) {
        my $mapping = $code_to_doc{$code_file};
        my $expected_doc = $mapping->{primary_doc};
        
        next unless $expected_doc;
        
        my $full_path = "$project_root/Comserv/root$expected_doc";
        $full_path =~ s{\.tt$}{};
        $full_path .= '.tt' unless $full_path =~ /\.tt$/;
        
        unless (-f $full_path) {
            # Try alternate naming patterns to find misnamed files
            my @candidates = ();
            
            # Extract base name and directory from code file
            my ($code_basename, $code_dir) = $code_file =~ m{^(.*/)?([^/]+)\.pm$};
            $code_basename = $code_basename || '';
            
            # Extract expected doc directory
            my ($doc_dir, $doc_basename) = $expected_doc =~ m{^(/[^/]+(?:/[^/]+)*)/?([^/]+)\.tt$};
            $doc_dir ||= '/Documentation';
            
            # Pattern 1: Check for underscore variants (Admin vs Admin_Controller)
            my @check_patterns = (
                "$doc_dir/${doc_basename}_Controller.tt",
                "$doc_dir/\L${doc_basename}.tt",
                "$doc_dir/\L${doc_basename}_Controller.tt",
                "/Documentation/\L${doc_basename}.tt",
                "/Documentation/\L${doc_basename}_Controller.tt",
            );
            
            foreach my $pattern (@check_patterns) {
                my $candidate = "$project_root/Comserv/root$pattern";
                if (-f $candidate) {
                    my $type = 'unknown';
                    $type = 'underscore_suffix' if $pattern =~ /_Controller/;
                    $type = 'case_variation' if $pattern =~ /\L/;
                    
                    push @candidates, {
                        found_at => $pattern,
                        pattern_type => $type
                    };
                }
            }
            
            # Add mismatches for each candidate found
            if (@candidates) {
                foreach my $candidate (@candidates) {
                    push @mismatches, {
                        code_file => $code_file,
                        expected_documentation => $expected_doc,
                        found_at => $candidate->{found_at},
                        pattern_type => $candidate->{pattern_type},
                        severity => "warning",
                        suggestion => "Rename '" . $candidate->{found_at} . "' to '$expected_doc' for naming consistency with code file"
                    };
                }
            }
        }
    }
    
    return @mismatches;
}

sub analyze_duplicate_entries {
    my (@audit_items) = @_;
    my %doc_history = ();
    
    opendir my $dh, $doc_reports_dir or return { duplicates => [], flagged_multiple_days => [] };
    my @audit_files = grep { /DocumentationSyncAudit.*\.json$/ } readdir $dh;
    closedir $dh;
    
    return { duplicates => [], flagged_multiple_days => [] } unless @audit_files;
    
    # Sort by date (newest first)
    @audit_files = sort { $b cmp $a } @audit_files;
    
    # Limit to last 10 days
    @audit_files = @audit_files[0..9] if scalar(@audit_files) > 10;
    
    # Analyze past audits
    foreach my $file (sort @audit_files) {
        my $full_path = "$doc_reports_dir/$file";
        next unless -f $full_path;
        
        my ($date) = $file =~ /DocumentationSyncAudit(\d{4}-\d{2}-\d{2})/;
        next unless $date;
        
        open my $fh, '<', $full_path or next;
        my $json_text = do { local $/; <$fh> };
        close $fh;
        
        my $past_audit = JSON->new->decode($json_text);
        
        foreach my $item (@{$past_audit->{documentation_files_needing_update} || []}) {
            my $doc = $item->{documentation_file};
            next unless $doc;
            
            push @{$doc_history{$doc}}, {
                date => $date,
                version => $item->{version},
                action => $item->{action}
            };
        }
    }
    
    # Check for duplicates in current audit and repeated files
    my @duplicates = ();
    my @flagged_multiple = ();
    
    # Find files appearing multiple times in past audits without version bump
    foreach my $doc (keys %doc_history) {
        my $appearances = $doc_history{$doc};
        
        if (scalar(@$appearances) > 1) {
            my $first_version = $appearances->[0]->{version};
            my $last_version = $appearances->[-1]->{version};
            
            if ($first_version eq $last_version) {
                push @flagged_multiple, {
                    documentation_file => $doc,
                    appearances => scalar(@$appearances),
                    version_unchanged => $first_version,
                    dates => [map { $_->{date} } @$appearances]
                };
            }
        }
    }
    
    return {
        duplicates => \@duplicates,
        flagged_multiple_days => \@flagged_multiple
    };
}

# Main logic
print "📊 DOCUMENTATION SYNC AUDIT\n";
print "=" . "=" x 70 . "\n";
print "Git Range: $git_range\n\n" if $verbose;

my @changed_files = get_changed_code_files($git_range);
my %code_to_doc = get_code_to_doc_mappings();

print "Found " . scalar(@changed_files) . " code files changed\n\n" if $verbose;

my @audit_items = ();
foreach my $normalized_file (@changed_files) {
    my $code_file = $normalized_file;
    my $original_file = $code_file;
    # Reconstruct original path for git operations (git diff returns with Comserv/ prefix)
    $original_file = "Comserv/$code_file" unless $code_file =~ m{^Comserv/};
    
    my $doc_path;
    my $mapping_info;
    
    # Case 1: File has existing mapping in RepositoryCodeAudit.json v2.0
    if (exists $code_to_doc{$code_file}) {
        $mapping_info = $code_to_doc{$code_file};
        $doc_path = $mapping_info->{primary_doc};
    } 
    # Case 2: NEW controller file (Admin) - auto-generate expected doc path
    elsif ($code_file =~ m{lib/Comserv/Controller/Admin/([A-Z][^/]+)\.pm$}) {
        my $controller_name = $1;
        # Generate doc path: /Documentation/controllers/ControllerName.tt
        $doc_path = "/Documentation/controllers/$controller_name.tt";
    }
    # Case 3: NEW controller file (regular) - auto-generate expected doc path
    elsif ($code_file =~ m{lib/Comserv/Controller/([A-Z][^/]+)\.pm$}) {
        my $controller_name = $1;
        # Generate doc path: /Documentation/controllers/ControllerName.tt
        $doc_path = "/Documentation/controllers/$controller_name.tt";
    }
    # Case 4: NEW model file - auto-generate expected doc path (handles nested paths like Schema/Result/*)
    elsif ($code_file =~ m{lib/Comserv/Model/}) {
        # Extract the model class name (last component before .pm)
        my ($model_name) = $code_file =~ m{/([A-Z][^/]+)\.pm$};
        if ($model_name) {
            # Generate doc path: /Documentation/models/ModelName.tt
            $doc_path = "/Documentation/models/$model_name.tt";
        } else {
            next;  # Skip if can't extract model name
        }
    }
    # Case 5: NEW view file - auto-generate expected doc path
    elsif ($code_file =~ m{lib/Comserv/View/([A-Z][^/]+)\.pm$}) {
        my $view_name = $1;
        # Generate doc path: /Documentation/views/ViewName.tt
        $doc_path = "/Documentation/views/$view_name.tt";
    }
    # Case 6: NEW utility file - auto-generate expected doc path
    elsif ($code_file =~ m{lib/Comserv/Util/([A-Z][^/]+)\.pm$}) {
        my $util_name = $1;
        # Generate doc path: /Documentation/utils/UtilName.tt
        $doc_path = "/Documentation/utils/$util_name.tt";
    }
    # Case 7: No mapping and not a recognized pattern - skip
    else {
        next;
    }
    
    my $doc_info = get_doc_file_info($doc_path);
    
    # CRITICAL: Check if code changed and doc wasn't already updated in response
    # Use git diff to verify actual changes exist
    my $code_commit_ts = get_code_file_commit_timestamp($original_file, $git_range);
    
    # Skip if documentation was already updated after this code change
    unless (should_update_doc($doc_info, $code_commit_ts, $original_file, $git_range, $doc_path)) {
        print "   ℹ️ Skipping $code_file (doc already updated in this range or code unchanged)\n" if $verbose;
        next;
    }
    
    my $action = determine_update_action($doc_info);
    
    my $diff_preview = get_file_diff_preview($code_file);
    
    my $audit_item = {
        code_file => $code_file,
        documentation_file => $doc_info->{rel_path},
        exists => $doc_info->{exists},
        reason => "Code changed in git diff ($git_range)",
        last_updated => $doc_info->{last_updated} || "Unknown",
        version => !$doc_info->{exists} ? '0.01' : ($doc_info->{version} || '0.01'),
        action => $action,
        full_path => $doc_info->{path}
    };
    
    # Add diff preview if available (helps doc sync identify what changed)
    $audit_item->{diff_preview} = $diff_preview if defined $diff_preview;
    
    push @audit_items, $audit_item;
}

# Run deduplication check if requested
my $dedup_analysis = undef;
if ($check_duplicates) {
    $dedup_analysis = analyze_duplicate_entries(@audit_items);
    print STDERR "\n⚠️  DUPLICATE CHECK RESULTS:\n" if $verbose;
    print STDERR "   - Flagged multiple days without update: " . scalar(@{$dedup_analysis->{flagged_multiple_days}}) . "\n" if $verbose;
}

# Run naming mismatch detection
my @naming_mismatches = detect_naming_mismatches(%code_to_doc);
if ($verbose && @naming_mismatches > 0) {
    print STDERR "\n⚠️  NAMING MISMATCH DETECTION:\n";
    foreach my $mismatch (@naming_mismatches) {
        print STDERR "   - Code: $mismatch->{code_file}\n";
        print STDERR "     Expected: $mismatch->{expected_documentation}\n";
        print STDERR "     Found at: $mismatch->{found_at}\n";
        print STDERR "     Type: $mismatch->{pattern_type}\n";
    }
}

my $audit = {
    audit_timestamp => DateTime->now(time_zone => 'UTC')->iso8601 . 'Z',
    git_range => $git_range,
    files_changed => scalar(@changed_files),
    documentation_files_needing_update => \@audit_items,
    naming_mismatches => @naming_mismatches > 0 ? \@naming_mismatches : undef,
    summary => {
        total_code_changes => scalar(@changed_files),
        docs_needing_update => scalar(@audit_items),
        docs_missing => scalar(grep { !$_->{exists} } @audit_items),
        naming_mismatches_found => scalar(@naming_mismatches),
        ready_to_sync => scalar(@audit_items) > 0 ? 1 : 0
    }
};

# Add dedup analysis if present
if ($dedup_analysis) {
    $audit->{deduplication_analysis} = $dedup_analysis;
}

# Output JSON
my $json = JSON->new->pretty->encode($audit);
print $json;

# Always write audit report to Documentation/AuditReports/ for browser viewing
ensure_audit_dir();
my $dt = DateTime->now(time_zone => 'UTC');
my $date_str = $dt->strftime('%Y-%m-%d');
my $report_file = "$doc_reports_dir/DocumentationSyncAudit.tt";

# Format as .tt file with metadata - COMPLIANT WITH DocumentationTtTemplate.tt
# Audit report itself starts at 0.01 per template specification
my $page_version = sprintf('%.2f', 0.01);
my $rcs_line = "audit_reports/DocumentationSyncAudit.tt,v $page_version ${\($dt->strftime('%Y/%m/%d'))} zencoder Exp - Documentation sync audit report (git range: $git_range)";

my $tt_content = <<"EOF";
[% META
   title = "Documentation Sync Audit Report - $date_str"
   description = "Automated audit of documentation files requiring updates based on code changes detected via git diff. Identifies primary documentation files that need version bumps or creation for recently modified code."
   roles = "admin,developer"
   TemplateType = "Documentation"
   category = "audit,documentation,system"
   page_version = "$page_version"
   last_updated = "${\($dt->strftime('%a %b %d %Y'))}"
   site_specific = "false"
%]
[% PageVersion = '$rcs_line' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<div class="container">
    <h1 style="color: var(--text-color); font-family: var(--header-font);">Documentation Sync Audit Report</h1>
    
    <div class="last-updated" style="color: var(--text-muted-color); font-size: var(--font-size-small);">
        <strong>Generated:</strong> $date_str | 
        <strong>Version:</strong> $page_version |
        <strong>Git Range:</strong> $git_range |
        <strong>Status:</strong> Ready for DocumentationSyncAgent processing
    </div>

    <!-- QUICK SUMMARY SECTION -->
    <div id="summary" class="row" style="margin: var(--spacing-large) 0; background-color: var(--light-color); padding: var(--spacing-medium); border-left: 4px solid var(--primary-color); border-radius: 4px;">
        <div class="col-100">
            <h2 style="color: var(--text-color); font-family: var(--header-font); margin-top: 0;">Audit Summary</h2>
            <ul style="color: var(--text-color); font-family: var(--body-font); list-style: none; padding-left: 0;">
                <li style="margin: var(--spacing-small) 0;"><strong style="color: var(--primary-color);">Total Code Files Changed:</strong> __TOTAL_CHANGES__</li>
                <li style="margin: var(--spacing-small) 0;"><strong style="color: var(--primary-color);">Documentation Files Needing Update:</strong> __DOCS_UPDATE__</li>
                <li style="margin: var(--spacing-small) 0;"><strong style="color: var(--primary-color);">New Documentation Files Needed:</strong> __DOCS_CREATE__</li>
                <li style="margin: var(--spacing-small) 0;"><strong style="color: var(--primary-color);">Ready to Sync:</strong> Yes</li>
            </ul>
        </div>
    </div>

    <!-- FULL AUDIT REPORT SECTION -->
    <div class="row">
        <div class="col-100">
            <h2 id="audit-data" style="color: var(--text-color); font-family: var(--header-font);">Detailed Audit Report (JSON)</h2>
            <p style="color: var(--text-color); font-family: var(--body-font); font-style: italic;">This JSON data is the authoritative source for which documentation files need updates. Use DocumentationSyncAgent workflow to process each item.</p>
            <pre style="background-color: var(--secondary-color); color: var(--text-color); padding: var(--spacing-medium); border-radius: 4px; overflow-x: auto; border: 1px solid var(--border-color);"><code>__JSON_DATA__</code></pre>
        </div>
    </div>

    <!-- HOW TO USE SECTION -->
    <div class="row">
        <div class="col-100">
            <h2 id="how-to-use" style="color: var(--text-color); font-family: var(--header-font);">How to Use This Report</h2>
            <ol style="color: var(--text-color); font-family: var(--body-font);">
                <li><strong>Review Audit Data:</strong> Examine the JSON above to see which documentation files need updating</li>
                <li><strong>For Each Item:</strong>
                    <ul>
                        <li>If <code style="background-color: var(--light-color); padding: 2px 4px;">"exists": true</code> → Update existing .tt file (bump version as shown in "action" field)</li>
                        <li>If <code style="background-color: var(--light-color); padding: 2px 4px;">"exists": null</code> → Create new documentation file using DocumentationTtTemplate.tt</li>
                    </ul>
                </li>
                <li><strong>Version Numbering:</strong> Follow format from "action" field (e.g., bump 1.12 → 1.13)</li>
                <li><strong>Add Recent Changes Section:</strong> Include code change summary in updated .tt files</li>
                <li><strong>Update Metadata:</strong> Ensure last_updated field reflects current date (YYYY-MM-DD format)</li>
            </ol>
            <p style="text-align: right; margin-top: var(--spacing-small);"><a href="#summary" style="color: var(--link-color); font-size: var(--font-size-small);">↑ Back to Summary</a></p>
        </div>
    </div>

    <!-- FOOTER -->
    <div class="row" style="margin-top: var(--spacing-large); padding-top: var(--spacing-medium); border-top: 1px solid var(--border-color);">
        <div class="col-100">
            <p style="color: var(--text-muted-color); font-family: var(--body-font); font-size: var(--font-size-small);">
                <strong>Generated by:</strong> documentation_sync_audit.pl (DocumentationSyncAgent workflow)<br/>
                <strong>Source:</strong> RepositoryCodeAudit.json v2.0 (1:N code-to-documentation mapping)<br/>
                <strong>Timestamp:</strong> ${\($dt->iso8601())}Z
            </p>
        </div>
    </div>
</div>
EOF

my $total_changes = $audit->{summary}->{total_code_changes} || 0;
my $docs_update = scalar(grep { $_->{exists} } @{$audit->{documentation_files_needing_update}}) || 0;
my $docs_create = scalar(grep { !$_->{exists} } @{$audit->{documentation_files_needing_update}}) || 0;

$tt_content =~ s/__DATE__/$dt->strftime('%a %b %d %H:%M:%S UTC %Y')/ge;
$tt_content =~ s/__TOTAL_CHANGES__/$total_changes/g;
$tt_content =~ s/__DOCS_UPDATE__/$docs_update/g;
$tt_content =~ s/__DOCS_CREATE__/$docs_create/g;
$tt_content =~ s/__JSON_DATA__/$json/g;

open my $fh, '>', $report_file or die "Cannot write to $report_file: $!\n";
print $fh $tt_content;
close $fh;

# Also write plain JSON version for scripting
my $json_file = $report_file;
$json_file =~ s/\.tt$/.json/;
open $fh, '>', $json_file or die "Cannot write to $json_file: $!\n";
print $fh $json;
close $fh;

print STDERR "\n✅ Audit report written:\n";
print STDERR "   - .tt (browser): $report_file → /Documentation/AuditReports/DocumentationSyncAudit.tt\n";
print STDERR "   - .json (scripts): $json_file\n";
print STDERR "\n" . "=" x 70 . "\n";
print STDERR "Ready for DocumentationSyncAgent to process\n";

exit 0;
