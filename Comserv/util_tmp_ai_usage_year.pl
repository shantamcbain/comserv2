#!/usr/bin/env perl
# Temp CLI: year rollup from ai_usage_logs via RemoteDB (ency).
# Run from app dir:  cd Comserv && perl util_tmp_ai_usage_year.pl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $rdb  = Comserv::Model::RemoteDB->new;
my $info = $rdb->get_connection_info('ency');
die "no conn\n" unless $info && $info->{config};
my $conn = $info->{config};
my $dsn  = ( $conn->{db_type} // '' ) eq 'sqlite'
    ? "dbi:SQLite:dbname=$conn->{database_path}"
    : "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
print STDERR "conn host=$conn->{host} port=$conn->{port} db=$conn->{database} user=$conn->{username}\n";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, mysql_enable_utf8mb4 => 1 } );
my $dbh = $schema->storage->dbh;

my $since = $ARGV[0] // '2025-08-31 00:00:00';
my ( $min_at, $max_at, $n ) = $dbh->selectrow_array(
    'SELECT MIN(created_at), MAX(created_at), COUNT(*) FROM ai_usage_logs WHERE created_at >= ?',
    undef, $since
);
print "RANGE\t$min_at\t$max_at\t$n\n";

my $sth = $dbh->prepare(
    q{
  SELECT COALESCE(provider,'unknown') AS provider,
         COALESCE(model,'unknown') AS model,
         COUNT(*) AS calls,
         COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
         COALESCE(SUM(completion_tokens),0) AS completion_tokens,
         COALESCE(SUM(total_tokens),0) AS total_tokens,
         COALESCE(SUM(estimated_cost_usd),0) AS cost_usd,
         SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS ok_calls,
         SUM(CASE WHEN status<>'success' THEN 1 ELSE 0 END) AS err_calls,
         MIN(created_at) AS first_at,
         MAX(created_at) AS last_at
  FROM ai_usage_logs
  WHERE created_at >= ?
  GROUP BY provider, model
  ORDER BY cost_usd DESC, calls DESC
}
);
$sth->execute($since);
print "PROVIDER\tMODEL\tCALLS\tOK\tERR\tPROMPT_TOK\tCOMP_TOK\tTOTAL_TOK\tCOST_USD\tFIRST\tLAST\n";
while ( my $r = $sth->fetchrow_hashref ) {
    printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.6f\t%s\t%s\n",
      @$r{
        qw(provider model calls ok_calls err_calls prompt_tokens completion_tokens total_tokens)
      },
      $r->{cost_usd} + 0,
      $r->{first_at} // '',
      $r->{last_at}  // '';
}

my $sth2 = $dbh->prepare(
    q{
  SELECT COALESCE(provider,'unknown') AS provider,
         COUNT(*) AS calls,
         COALESCE(SUM(total_tokens),0) AS total_tokens,
         COALESCE(SUM(estimated_cost_usd),0) AS cost_usd,
         SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS ok_calls
  FROM ai_usage_logs
  WHERE created_at >= ?
  GROUP BY provider
  ORDER BY cost_usd DESC, calls DESC
}
);
$sth2->execute($since);
print "\nBY_PROVIDER\tCALLS\tOK\tTOTAL_TOK\tCOST_USD\n";
while ( my $r = $sth2->fetchrow_hashref ) {
    printf "%s\t%d\t%d\t%d\t%.6f\n",
      @$r{qw(provider calls ok_calls total_tokens)}, $r->{cost_usd} + 0;
}

my $sth3 = $dbh->prepare(
    q{
  SELECT DATE_FORMAT(created_at, "%Y-%m") AS ym,
         COALESCE(provider,'unknown') AS provider,
         COUNT(*) AS calls,
         COALESCE(SUM(estimated_cost_usd),0) AS cost_usd,
         COALESCE(SUM(total_tokens),0) AS total_tokens
  FROM ai_usage_logs
  WHERE created_at >= ?
  GROUP BY ym, provider
  ORDER BY ym, cost_usd DESC
}
);
$sth3->execute($since);
print "\nMONTH_PROVIDER\tYM\tPROVIDER\tCALLS\tCOST_USD\tTOTAL_TOK\n";
while ( my $r = $sth3->fetchrow_hashref ) {
    printf "%s\t%s\t%d\t%.6f\t%d\n",
      @$r{qw(ym provider calls)}, $r->{cost_usd} + 0, $r->{total_tokens};
}

my ( $tot_c, $tot_tok, $tot_cost ) = $dbh->selectrow_array(
    'SELECT COUNT(*), COALESCE(SUM(total_tokens),0), COALESCE(SUM(estimated_cost_usd),0) FROM ai_usage_logs WHERE created_at >= ?',
    undef, $since
);
printf "\nTOTALS\tcalls=%d\ttokens=%d\tcost=%.6f\n", $tot_c, $tot_tok, $tot_cost + 0;

my $sth4 = $dbh->prepare(
    q{
  SELECT COALESCE(billing_status,'(null)') AS bs,
         COUNT(*) c,
         COALESCE(SUM(estimated_cost_usd),0) cost
  FROM ai_usage_logs
  WHERE created_at >= ?
  GROUP BY bs
  ORDER BY cost DESC
}
);
$sth4->execute($since);
print "\nBILLING_STATUS\tSTATUS\tCALLS\tCOST\n";
while ( my $r = $sth4->fetchrow_hashref ) {
    printf "%s\t%d\t%.6f\n", $r->{bs}, $r->{c}, $r->{cost} + 0;
}
