#!/usr/bin/env perl
# Daily follower update.
#
# Reads the "Total Followers" count off the downloaded link.me profile page and
# writes it into:
#   - metrics.js           the "followers" stat in the homepage pill
#   - data/followers.json  one entry per day, which the /growth graph plots
#
# Run by .github/workflows/update-metrics.yml once a day:
#   perl scripts/update-metrics.pl <downloaded-linkme.html>
#
# Nothing is written unless a believable number is found, so a failed download
# or a link.me redesign leaves the site showing its last good numbers.

use strict;
use warnings;
use JSON::PP;
use POSIX qw(strftime);
use File::Basename qw(dirname);
use File::Spec;

my $html_path = shift or die "usage: $0 <linkme.html>\n";

my $root         = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $metrics_path = File::Spec->catfile($root, 'metrics.js');
my $history_path = File::Spec->catfile($root, 'data', 'followers.json');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "can't read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub spit {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "can't write $path: $!\n";
    print {$fh} $text;
    close $fh;
}

# 60994 -> "61K", 61234 -> "61.2K", 1450000 -> "1.5M". Matches how link.me
# rounds, and drops a trailing ".0".
#
# Rounds a whole number of tenths rather than using sprintf("%.1f"): printf
# rounding works on the binary float, so 1.45 can come out as "1.4".
sub compact {
    my ($n) = @_;
    return "$n" if $n < 1000;
    my ($div, $suffix) = $n >= 1_000_000 ? (1_000_000, 'M') : (1000, 'K');
    my $tenths = int($n / ($div / 10) + 0.5);
    if ($suffix eq 'K' && $tenths >= 10_000) {   # 999,960 would read "1000K"
        ($div, $suffix) = (1_000_000, 'M');
        $tenths = int($n / ($div / 10) + 0.5);
    }
    my $v = int($tenths / 10) . ($tenths % 10 ? '.' . ($tenths % 10) : '');
    return "$v$suffix";
}

# ---- 1. find the number ------------------------------------------------------

my $html = slurp($html_path);

# First choice: the exact total link.me embeds in the page's data.
my ($total) = $html =~ /\btotalFollowers\s*:\s*(\d+)/;
my $source  = 'totalFollowers';

# Fallback: add up the per-platform counts it embeds alongside it.
if (!defined $total) {
    my @counts = $html =~ /\bfollowerCount\s*:\s*(\d+)/g;
    if (@counts) {
        $total = 0;
        $total += $_ for @counts;
        $source = 'sum of ' . scalar(@counts) . ' platform followerCounts';
    }
}

die "No follower count found in the link.me page - it may have changed its layout. Nothing was written.\n"
    unless defined $total;
die "Follower count $total doesn't look right. Nothing was written.\n"
    if $total <= 0 || $total > 1_000_000_000;

my $today = strftime('%Y-%m-%d', gmtime);

# ---- 2. load history and sanity-check against it -----------------------------

my @history;
if (-e $history_path) {
    my $decoded = decode_json(slurp($history_path));
    die "$history_path isn't a list. Nothing was written.\n" unless ref $decoded eq 'ARRAY';
    @history = grep { ref $_ eq 'HASH' && defined $_->{date} && defined $_->{followers} } @$decoded;
}

# A real audience doesn't halve overnight; a count that small means the page was
# read wrong, so keep yesterday's numbers rather than publish a bad one.
my ($previous) = grep { $_->{date} lt $today } reverse sort { $a->{date} cmp $b->{date} } @history;
if ($previous && $total < $previous->{followers} * 0.5) {
    die "Follower count $total is less than half of $previous->{followers} on $previous->{date}. "
      . "Assuming a bad read. Nothing was written.\n";
}

# ---- 3. write metrics.js -----------------------------------------------------

my $formatted = compact($total);
my $js        = slurp($metrics_path);
my $new_js    = $js;
my $replaced  = ($new_js =~ s/(\{\s*value:\s*")[^"]*("\s*,\s*label:\s*"followers"\s*\})/${1}${formatted}${2}/);
die "Couldn't find the followers line in metrics.js. Nothing was written.\n" unless $replaced;

# ---- 4. write the history ----------------------------------------------------

@history = grep { $_->{date} ne $today } @history;
push @history, { date => $today, followers => $total };
@history = sort { $a->{date} cmp $b->{date} } @history;

# One entry per line so each day shows up as a one-line diff.
my $new_history = "[\n"
    . join(",\n", map { sprintf '  {"date": "%s", "followers": %d}', $_->{date}, $_->{followers} } @history)
    . "\n]\n";

my $old_history = -e $history_path ? slurp($history_path) : '';

if ($new_js ne $js)                  { spit($metrics_path, $new_js) }
if ($new_history ne $old_history) {
    my $dir = dirname($history_path);
    mkdir $dir unless -d $dir;
    spit($history_path, $new_history);
}

printf "Followers: %d (%s), read from %s\n", $total, $formatted, $source;
printf "metrics.js: %s\n", $new_js ne $js ? "updated" : "unchanged";
printf "data/followers.json: %s, %d day%s of history\n",
    $new_history ne $old_history ? "updated" : "unchanged",
    scalar(@history), @history == 1 ? '' : 's';
