#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite not installed';
}

use Comserv::Util::Logging;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

{
    package I::Schema; use base 'DBIx::Class::Schema';
    package I::Item; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_items');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(sitename sku name image_path status)
    );
    __PACKAGE__->set_primary_key('id');
}
I::Schema->register_class('Accounting::InventoryItem' => 'I::Item');
my $schema = I::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;
my $mine = $schema->resultset('Accounting::InventoryItem')->create({ sitename => 'Shanta', sku => 'P1', name => 'Photo', status => 'active' });
my $theirs = $schema->resultset('Accounting::InventoryItem')->create({ sitename => 'Other', sku => 'P2', name => 'Other', status => 'active' });

my $root = tempdir(CLEANUP => 1);
my $src = tempdir(CLEANUP => 1);

sub write_bytes {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die $!;
    print $fh $bytes;
    close $fh;
    return $path;
}

{
    package Up;
    sub new { bless $_[1], $_[0] }
    sub filename { $_[0]{filename} }
    sub size { $_[0]{size} // -s $_[0]{tempname} }
    sub tempname { $_[0]{tempname} }
    sub type { $_[0]{type} }
    sub copy_to { File::Copy::copy($_[0]{tempname}, $_[1]) }
    package IC;
    sub new { bless { stash => { inventory_image_root => $root }, schema => $schema }, shift }
    sub stash { $_[0]{stash} }
    sub model { bless { schema => $schema }, 'IM' }
    package IM;
    sub resultset { $_[0]{schema}->resultset($_[1]) }
}

require Comserv::Util::ItemImage;
my $c = IC->new;
my $jpg = write_bytes("$src/client-name.jpg", "\xFF\xD8\xFF\x00jpeg-bytes");
my $ok = Comserv::Util::ItemImage->save($c, Up->new({ filename => 'client-name.jpg', tempname => $jpg, type => 'image/jpeg' }), 'Shanta', $mine->id);
ok($ok->{ok}, 'jpg accepted') or diag($ok->{error} || '');
like($ok->{image_path}, qr{^/static/inventory_images/Shanta/\d+-\d+\.jpg$}, 'server filename');
unlike($ok->{image_path}, qr/client-name/, 'client name not used');
is($ok->{content_type}, 'image/jpeg', 'jpeg type');
$mine->discard_changes;
is($mine->image_path, $ok->{image_path}, 'image_path saved on the session-site item');

my $exe = write_bytes("$src/fake.jpg", "MZ\x90\x00not-a-jpeg");
my $bad = Comserv::Util::ItemImage->save($c, Up->new({ filename => 'fake.jpg', tempname => $exe }), 'Shanta', $mine->id);
is($bad->{code}, 'bad_type', 'exe renamed to jpg is refused');

my $big = Comserv::Util::ItemImage->save($c, Up->new({
    filename => 'big.jpg', tempname => $jpg, size => 8 * 1024 * 1024 + 1,
}), 'Shanta', $mine->id);
is($big->{code}, 'too_large', 'over 8 MB refused');

my $other = Comserv::Util::ItemImage->save($c, Up->new({ filename => 'x.jpg', tempname => $jpg }), 'Shanta', $theirs->id);
is($other->{code}, 'item_not_found', 'other site item is not updated');
$theirs->discard_changes;
ok(!defined $theirs->image_path || $theirs->image_path eq '', 'other site image_path unchanged');

my $none = Comserv::Util::ItemImage->save($c, undef, 'Shanta', $mine->id);
is($none->{code}, 'no_file', 'missing upload');

done_testing;
