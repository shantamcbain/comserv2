use strict; use warnings;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::LegacyCgiMap;
my $m = Comserv::Util::LegacyCgiMap->load("$FindBin::Bin/../config/legacy_redirects.json");
my @cases = (
  ['/cgi-bin/index.cgi', 'site=BMaster&view=JobView&session_id=ABC', '/jobs'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=HostingView&session_id=YVQV', '/CSC/web_hosting'],
  ['/cgi-bin/index.cgi/cgi-bin/index.cgi', 'site=Forager&view=ProductView', '/shop'],
  ['/cgi-bin/beetalk.beemaster.ca/cgi-bin/index.cgi', 'site=BMaster', '/'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=SwarmControl', 'https://beemaster.ca/page/core_swarm_control'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=BeeProductsStock', '/BMaster/products'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=QueenRearingWorkshop', '/workshop'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=EarthHeartColective', '/workshop'],
  ['/cgi-bin/index.cgi', 'site=BMaster&procedure=WinterizingYard', '/page/wintering-yard-fall-2026'],
  ['/cgi-bin/index.cgi', 'site=BMaster&procedure=WinterVisits', 'https://beemaster.ca/page/core_autumn_stores_interior_bc'],
  ['/cgi-bin/index.cgi', 'site=BMaster&procedure=ContactView', '/HelpDesk/contact'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=Disease', 'https://beemaster.ca/page/core_disease_screen_signs'],
  ['/cgi-bin/index.cgi', 'site=ECF&page=Disease', '/BMaster/education'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=HiveEvaluationLost', 'https://beemaster.ca/page/core_disease_screen_signs'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=NewsLetterView', 'https://beemaster.ca/page/nl-pub-beemaster-class-newsletters'],
  ['/cgi-bin/index.cgi', 'site=Forager&view=NewsLetterView', '/newsletters'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=ProceduresView', '410'],
  ['/cgi-bin/index.cgi', 'site=BMaster&submit_logon=1&view=JobView', '410'],
  ['/cgi-bin/index.cgi', 'session_id=X&site=Forager', '/'],
  ['/cgi-bin/', 'session_id=X&view=MembersView', '/membership'],
  ['/cgi-bin/index.cgi', '&?site=BMaster&view=MailView', '/newsletters'],
  ['/cgi-bin/BuyAndSell/buy.cgi', 'site=BMaster&session_id=R&&display_details_view.x&record_id=3&Small+Perl+Programing+Jobs', '410'],
  ['/cgi-bin/BuyAndSell/buy.cgi', 'site=BMaster&display_add_form=on', '/marketplace'],
  ['/cgi-bin/ENCY/herbs.cgi', 'site=BMaster&view=HerbDetailView&record_id=31', '/ENCY/herb_detail/31'],
  ['/cgi-bin/ENCY/herbs.cgi', 'record_id=31x', '/ENCY/BotanicalNameView'],
  ['/cgi-bin/ENCY/herbs.cgi', 'site=BMaster&view=BotanicalNameView', '/ENCY/BotanicalNameView'],
  ['/cgi-bin/FAQ/faq.cgi', 'site=MonasheeSupport&sort_field1=category', '/faq'],
  ['/cgi-bin/Apis/yards.cgi', 'site=BMaster&view=YardsView', '410'],
  ['/cgi-bin/CSC/csc.cgi', 'site=CSC&view=OpensourceView', 'https://computersystemconsulting.ca/page/open_source_vs_closed'],
  ['/cgi-bin/computersystemconsulting.ca/cgi-bin/CSC/csc.cgi', '', '/CSC'],
  ['/cgi-bin/ENCY/formulas.cgi', '', '/ENCY/Formula'],
  ['/cgi-bin/Hal.archives+louver+yes.fr', 'site=x', '410'],
  ['/cgi-bin/BuyAndSell/default', 'v', '410'],
  ['/cgi-bin/index.cgi', 'site=BMaster&procedure=LiveStream', '410'],
  ['/cgi-bin/index.cgi', 'site=BMaster&procedure=YardManagementSystem', '/BMaster'],
  ['/cgi-bin/index.cgi', 'site=BMaster&page=ProjectView', '410'],
  ['/cgi-bin/index.cgi', 'site=Forager&page=SwarmControl', '/BMaster/education'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=MentorView', 'https://beemaster.ca/page/mentoring_program'],
  ['/cgi-bin/index.cgi', 'site=ECF&view=MentorView', '410'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=OpensourceView', 'https://computersystemconsulting.ca/page/open_source_vs_closed'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=BMasterBreederView', 'https://beemaster.ca/page/breeder_program'],
  ['/cgi-bin/index.cgi', 'site=BMaster&view=ApisQueensView', 'https://beemaster.ca/page/sustainable_queens'],
  ['/cgi-bin/index.cgi', 'site=ENCY&view=ResourcesView', 'https://ency.usbm.ca/page/environmental_resources'],
  ['/cgi-bin/index.cgi', 'site=Forager&view=ResourcesView', '410'],
  ['/cgi-bin/index.php', '', '410'],
  ['/cgi-bin/index.cgi', 'view=http://evil.example/', '410'],
);
for my $t (@cases) { my ($got) = $m->resolve(@$t[0,1]); is($got, $t->[2], "$t->[0]?$t->[1]") }
# absolute targets: only https to own domains
ok(Comserv::Util::LegacyCgiMap::target_ok($_), "ok target $_") for
  ('/x', '410', 'https://beemaster.ca/page/a', 'https://ency.usbm.ca/page/b', 'https://computersystemconsulting.ca/');
ok(!Comserv::Util::LegacyCgiMap::target_ok($_), "rejected target $_") for
  ('//evil.com/x', 'http://beemaster.ca/x', 'https://evil.com/x', 'https://beemaster.ca.evil.com/x',
   'https://evil.com@beemaster.ca/x', 'https://beemaster.ca:8080/x', '/\\evil.com', 'javascript:alert(1)');
{ require File::Temp; my ($fh, $fn) = File::Temp::tempfile(); print $fh '{"scripts":{"index.cgi":{"default":"https://evil.com/"}}}'; close $fh;
  ok(!eval { Comserv::Util::LegacyCgiMap->load($fn); 1 }, 'map with off-domain target fails to load'); }
# herb record ids are preserved 1:1 (checked vs old ency_herb_tb, 37/37 logged ids)
is(($m->resolve('/cgi-bin/ENCY/herbs.cgi', 'site=USBM&view=HerbDetailView&record_id=27'))[0], '/ENCY/herb_detail/27', 'herb id kept');
is(($m->resolve('/cgi-bin/ENCY/herbs.cgi', 'site=ENCY&display_details_view.x=1&record_id=12'))[0], '/ENCY/herb_detail/12', 'herb details button');
is(($m->resolve('/cgi-bin/ENCY/herbs.cgi', 'record_id=12abc'))[0], '/ENCY/BotanicalNameView', 'bad id -> list');
is(($m->resolve('/cgi-bin/ENCY/herbs.cgi', 'display_power_search_form=on'))[0], '/ENCY/BotanicalNameView', 'power search -> list');
is(($m->resolve('/cgi-bin/ENCY/formulas.cgi', 'display_details_view.x&record_id=22'))[0], '/ENCY/Formula', 'formula ids changed -> list');
done_testing;
