use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::GitFix;

my $g = Comserv::Model::AI2::GitFix->new;

# The line that used to hijack every editor turn once Chat.pm was attached.
my $investigator = q{investigator => "You are a cost-effective investigator using only cheap or free models. Your job is to search logs, code, git history, usage data, and reports to answer questions about what happened. Be efficient and produce a clear report with findings, relevant paths, commits if possible, and direct quotes."};

my $editor_prompt = join("\n",
    '[AI Editor agent=programming phase=plan]',
    'why is the editor giving fiction',
    '',
    '---',
    'These files were loaded live from this app via GET /ai2/load_file (including auto pipeline controllers). They ARE in this message.',
    '',
    '[FILE: lib/Comserv/Model/AI2/Chat.pm] (live /ai2/load_file)',
    '```',
    $investigator,
    '```',
);
ok !$g->is_path_rejection_ask($editor_prompt),
    'attached Chat.pm source does not trigger GitFix';

my $file_has_error = join("\n",
    'what does this file do',
    '',
    '---',
    'These files were loaded live from this app via GET /ai2/load_file',
    '',
    '[FILE: lib/Comserv/Model/AI2/GitFix.pm] (live /ai2/load_file)',
    '```',
    'proposal for "Rejected unsafe or unknown path(s)" errors.',
    '```',
);
ok !$g->is_path_rejection_ask($file_has_error),
    'the error phrase inside an attached file is not the user ask';

ok $g->is_path_rejection_ask(
    'Rejected unsafe or unknown path(s): data/ai_caps.json (must exactly match git status)'
), 'a pasted flash error still triggers';

ok !$g->is_path_rejection_ask('git commit failed on a path in the editor'),
    'a loose git/commit/path sentence does not trigger';

done_testing;
