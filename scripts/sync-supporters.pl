#!/usr/bin/env perl
# Publishes the Sky Supporters onto the homepage.
#
# Reads the folder the Chubbitz Discord bot refreshes once a day and writes:
#   - media/supporters/<discord_id>.png   each supporter's picture
#   - data/supporters.json                who is shown, and which picture each
#                                         one had, so the next run can tell
#                                         what actually changed
#   - index.html                          the "My Supporters" section, rendered
#                                         between the supporters markers
#
#   perl scripts/sync-supporters.pl [path-to-supporter_export]
#
# The export folder is READ ONLY. Nothing in it is written, moved or deleted.
# No Discord token or API key is read, printed or stored - everything this
# needs is already in the folder.
#
# SAFE TO RE-RUN
#   A picture is only copied when its avatar_hash changed or its file is
#   missing. People who lost the role have their picture deleted. A run that
#   changes nothing leaves every file untouched, so it makes no commit.
#
# WHEN IT REFUSES TO RUN
#   If the export is older than MAX_AGE_HOURS the bot is probably down, so the
#   run is skipped with a note saying how old it is, and the site keeps showing
#   the supporters it already has. Same for an export that can't be parsed or
#   that lists nobody: a bad read should never empty the section. None of these
#   counts as a failure - they exit 0, because a scheduled task that cries wolf
#   gets ignored.

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use Encode qw(decode_utf8);

my $MAX_AGE_HOURS = 48;

my $DEFAULT_EXPORT =
    'C:/Users/siahm/Documents/Josiah Programs/chubbitz supporter assistant/supporter_export';

my $export = @ARGV ? $ARGV[0] : $DEFAULT_EXPORT;
my $root   = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

my $avatar_dir    = File::Spec->catdir($root, 'media', 'supporters');
my $manifest_path = File::Spec->catfile($root, 'data', 'supporters.json');
my $page_path     = File::Spec->catfile($root, 'index.html');

sub say_now { print strftime('%Y-%m-%d %H:%M:%S', localtime) . "  $_[0]\n" }

# A reason to stop that isn't a failure: say it plainly and leave everything be.
sub skip {
    say_now("SKIPPED: $_[0]");
    say_now('Nothing was changed.');
    exit 0;
}

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub spit_raw {
    my ($path, $data) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "can't write $path: $!\n";
    print {$fh} $data;
    close $fh;
}

# "2026-11-05T01:11:39.801531+00:00" -> epoch seconds.
sub iso_to_epoch {
    my ($s) = @_;
    return undef unless defined $s
        && $s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;
    my ($Y, $M, $D, $h, $m, $sec, $zone) = ($1, $2, $3, $4, $5, $6, $7);
    require Time::Local;
    my $epoch = Time::Local::timegm($sec, $m, $h, $D, $M - 1, $Y);
    if (defined $zone && $zone ne 'Z') {
        my ($sign, $zh, $zm) = $zone =~ /^([+-])(\d{2}):?(\d{2})$/;
        my $offset = ($zh * 3600 + $zm * 60) * ($sign eq '-' ? -1 : 1);
        $epoch -= $offset;
    }
    return $epoch;
}

sub esc_html {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# ---- 1. read the export ------------------------------------------------------

my $json_path = File::Spec->catfile($export, 'supporters.json');
skip("no supporters.json at $json_path - is the export folder where I think it is?")
    unless -e $json_path;

my $raw = slurp_raw($json_path);
skip("couldn't read $json_path") unless defined $raw && length $raw;

my $data = eval { JSON::PP->new->utf8->decode($raw) };
skip("supporters.json isn't valid JSON, so it was probably caught mid-write")
    unless ref $data eq 'HASH';

my $generated = $data->{generated_at};
my $epoch     = iso_to_epoch($generated);
skip('supporters.json has no readable generated_at') unless defined $epoch;

my $age_hours = (time - $epoch) / 3600;
skip(sprintf('the export is %.1f hours old (limit is %d) - the bot may be down',
             $age_hours, $MAX_AGE_HOURS))
    if $age_hours > $MAX_AGE_HOURS;

# A clock slightly ahead is harmless; a wildly future date means something is wrong.
skip(sprintf('the export is dated %.1f hours in the future - check the clock', -$age_hours))
    if $age_hours < -6;

my $list = $data->{supporters};
skip('supporters.json has no supporters list') unless ref $list eq 'ARRAY';
skip('the export lists nobody, so the section was left as it is') unless @$list;

say_now(sprintf('Export is %.1f hours old and lists %d supporter%s.',
                $age_hours, scalar @$list, @$list == 1 ? '' : 's'));

# ---- 2. work out who is in, and which picture each one has -------------------

my (@people, %seen);
for my $s (@$list) {
    next unless ref $s eq 'HASH';
    my $id = $s->{discord_id};
    next unless defined $id && $id =~ /^[0-9]{5,25}$/;   # a plain snowflake, nothing else
    next if $seen{$id}++;

    my $name = $s->{username};
    $name = $s->{display_name} unless defined $name && length $name;
    next unless defined $name && length $name;

    # Only the extension is taken from avatar_file; the name is always the id,
    # so a crafted path can't put a file somewhere it shouldn't go.
    my $ext = 'png';
    if (defined $s->{avatar_file} && $s->{avatar_file} =~ /\.([A-Za-z0-9]{1,5})$/) {
        $ext = lc $1;
    }
    $ext = 'png' unless $ext =~ /^(?:png|gif|jpg|jpeg|webp)$/;

    push @people, {
        id     => $id,
        name   => decode_utf8($name),
        hash   => (defined $s->{avatar_hash} ? $s->{avatar_hash} : ''),
        source => $s->{avatar_file},
        ext    => $ext,
    };
}
skip('no usable entries in the export') unless @people;

# ---- 3. what we published last time ------------------------------------------

my %had;
if (-e $manifest_path) {
    my $old = eval { JSON::PP->new->utf8->decode(slurp_raw($manifest_path)) };
    if (ref $old eq 'HASH' && ref $old->{supporters} eq 'ARRAY') {
        for my $e (@{ $old->{supporters} }) {
            next unless ref $e eq 'HASH' && defined $e->{id};
            $had{ $e->{id} } = $e;
        }
    }
}

# ---- 4. copy the pictures that actually changed ------------------------------

make_path($avatar_dir) unless -d $avatar_dir;

my ($copied, $kept, $missing) = (0, 0, 0);
for my $p (@people) {
    my $dest   = File::Spec->catfile($avatar_dir, "$p->{id}.$p->{ext}");
    my $before = $had{ $p->{id} };

    my $unchanged = $before
        && defined $before->{hash} && $before->{hash} eq $p->{hash}
        && defined $before->{ext}  && $before->{ext}  eq $p->{ext}
        && -s $dest;

    if ($unchanged) { $kept++; next }

    unless (defined $p->{source}) {
        $missing++;
        say_now("  $p->{name} has no picture in the export; leaving whatever is on the site.");
        next;
    }

    my $src   = File::Spec->catfile($export, split m{/}, $p->{source});
    my $bytes = slurp_raw($src);
    unless (defined $bytes && length $bytes) {
        $missing++;
        say_now("  couldn't read the picture for $p->{name}; keeping the old one.");
        next;
    }

    spit_raw($dest, $bytes);
    $copied++;
    say_now(sprintf('  picture updated for %s (%.0f KB)', $p->{name}, length($bytes) / 1024));
}

# ---- 5. drop the people who are gone -----------------------------------------

my %current = map { ("$_->{id}.$_->{ext}" => 1) } @people;
my $removed = 0;
if (opendir my $dh, $avatar_dir) {
    for my $f (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
        next if $current{$f};
        next unless $f =~ /^[0-9]{5,25}\.[A-Za-z0-9]{1,5}$/;   # only ever our own files
        if (unlink File::Spec->catfile($avatar_dir, $f)) {
            $removed++;
            say_now("  removed $f (no longer a supporter)");
        }
    }
    closedir $dh;
}

# ---- 6. render the section ---------------------------------------------------

my @rows;
for my $p (sort { lc($a->{name}) cmp lc($b->{name}) || $a->{id} cmp $b->{id} } @people) {
    my $name = esc_html($p->{name});
    push @rows,
        '      <li class="supporter">' . "\n"
      . '        <img class="supporter-pic" loading="lazy" decoding="async" width="64" height="64"' . "\n"
      . '             src="/media/supporters/' . $p->{id} . '.' . $p->{ext} . '" alt="">' . "\n"
      . '        <span class="supporter-name">' . $name . '</span>' . "\n"
      . '      </li>';
}

my $section =
    "\n  <!-- Written by scripts/sync-supporters.pl. Edits between the markers are overwritten. -->\n"
  . "  <section class=\"section\" aria-labelledby=\"supporters-title\">\n"
  . "    <div class=\"section-head\"><span class=\"section-title\" id=\"supporters-title\">My Supporters</span></div>\n"
  . "    <ul class=\"supporters\">\n"
  . join("\n", @rows) . "\n"
  . "    </ul>\n"
  . "  </section>\n\n  ";

my $page = slurp_raw($page_path);
die "can't read $page_path\n" unless defined $page;
my $crlf = $page =~ /\r\n/ ? 1 : 0;
$page =~ s/\r\n/\n/g;

my $start = '<!-- supporters:start -->';
my $end   = '<!-- supporters:end -->';
unless ($page =~ /\Q$start\E/ && $page =~ /\Q$end\E/) {
    die "The supporters markers aren't in index.html, so there's nowhere to write.\n"
      . "Expected $start and $end just above the My Sponsors section.\n";
}

my $new_page = $page;
$new_page =~ s/\Q$start\E.*?\Q$end\E/$start$section$end/s;
$new_page =~ s/\n/\r\n/g if $crlf;

# ---- 7. write the manifest ---------------------------------------------------

my @manifest = map { { id => $_->{id}, name => $_->{name}, hash => $_->{hash}, ext => $_->{ext} } }
               sort { $a->{id} cmp $b->{id} } @people;

my $new_manifest = JSON::PP->new->utf8->canonical->pretty->encode({
    generated_at => $generated,
    synced_at    => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
    role         => (defined $data->{role} ? $data->{role} : 'Sky Supporter'),
    count        => scalar @people,
    supporters   => \@manifest,
});

# synced_at changes every run, so it's left out when deciding whether the
# manifest really changed. Otherwise every run would look like a change.
sub manifest_without_time {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/^\s*"synced_at".*$//m;
    return $text;
}

my $old_page     = slurp_raw($page_path);
my $old_manifest = slurp_raw($manifest_path);

my $page_changed     = (defined $old_page && $old_page ne $new_page) ? 1 : 0;
my $manifest_changed =
    manifest_without_time($old_manifest) ne manifest_without_time($new_manifest) ? 1 : 0;

spit_raw($page_path, $new_page)         if $page_changed;
spit_raw($manifest_path, $new_manifest) if $manifest_changed || !defined $old_manifest;

# ---- 8. report ---------------------------------------------------------------

say_now(sprintf('Pictures: %d copied, %d unchanged, %d removed%s.',
                $copied, $kept, $removed, $missing ? ", $missing missing" : ''));
say_now('index.html: ' . ($page_changed ? 'updated' : 'unchanged'));
say_now('data/supporters.json: ' . ($manifest_changed ? 'updated' : 'unchanged'));

my $changed = $page_changed || $manifest_changed || $copied || $removed;
say_now($changed ? 'Done - there is something to commit.' : 'Done - nothing changed.');
exit 0;
