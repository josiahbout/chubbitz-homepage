#!/usr/bin/env perl
# Daily follower update.
#
# Reads follower counts and writes:
#   - metrics.js           the "followers" stat in the homepage pill (the total)
#   - data/followers.json  one entry per day - the total plus each platform -
#                          which the /growth page plots
#
# Run by .github/workflows/update-metrics.yml once a day:
#   perl scripts/update-metrics.pl <linkme.html> [discord=<invite.json>]
#
#   <linkme.html>   the downloaded link.me/thechubbitz profile page
#   discord=<file>  optional: Discord's invite API response (or the invite page
#                   itself). Its member count is recorded as "discord" and added
#                   to the total. If it can't be read, Discord is left out for
#                   that day and everything else still updates.
#
# ADDING A PLATFORM (e.g. X)
#   Connect the account on link.me. Every account link.me shows a follower count
#   for is picked up automatically, so usually nothing here needs to change.
#   - To give it a proper name and colour on /growth, add a line to PLATFORMS
#     near the top of the script in growth/index.html.
#   - Only if its web address isn't recognised in %PLATFORM_HOSTS below (it would
#     then be named after its domain, e.g. vimeo.com -> "vimeo") add it here.
#   A source that isn't on link.me (like Discord) needs its own reader in
#   %SOURCES below plus a download step in the workflow.
#
# ESTIMATED DAYS
#   Days from before daily tracking began carry "estimated": true. That flag is
#   kept as is; days this script records are real readings and never get it.
#
# Nothing is written unless a believable total is found, so a failed download or
# a link.me redesign leaves the site showing its last good numbers.

use strict;
use warnings;
use JSON::PP;
use POSIX qw(strftime);
use File::Basename qw(dirname);
use File::Spec;

# Web address -> the name a platform is recorded under. Subdomains are handled
# (m.youtube.com matches youtube.com), and aliases share a name (twitter.com
# and x.com both count as "x").
my %PLATFORM_HOSTS = (
    'instagram.com'  => 'instagram',
    'youtube.com'    => 'youtube',
    'youtu.be'       => 'youtube',
    'tiktok.com'     => 'tiktok',
    'x.com'          => 'x',
    'twitter.com'    => 'x',
    'threads.net'    => 'threads',
    'threads.com'    => 'threads',
    'facebook.com'   => 'facebook',
    'fb.com'         => 'facebook',
    'twitch.tv'      => 'twitch',
    'kick.com'       => 'kick',
    'snapchat.com'   => 'snapchat',
    'bsky.app'       => 'bluesky',
    'linkedin.com'   => 'linkedin',
    'pinterest.com'  => 'pinterest',
    'spotify.com'    => 'spotify',
    'soundcloud.com' => 'soundcloud',
);

# Sources that aren't on link.me: name => reader. Each reader gets the file's
# contents and returns a count, or undef if it can't find one.
my %SOURCES = (
    # Discord's invite API gives approximate_member_count. If that ever changes,
    # the invite page's own "... | 935 members" description is read instead.
    discord => sub {
        my ($text) = @_;
        my $data = eval { decode_json($text) };
        if (ref $data eq 'HASH' && defined $data->{approximate_member_count}
            && $data->{approximate_member_count} =~ /^\d+$/) {
            return $data->{approximate_member_count};
        }
        return $1 =~ s/,//gr if $text =~ /\b(\d[\d,]*)\s+members?\b/i;
        return;
    },
);

my ($html_path, @extra_args) = @ARGV;
die "usage: $0 <linkme.html> [discord=<file>]\n" unless defined $html_path;

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

# "https://www.youtube.com/@TheChubbitz" -> "youtube"
sub platform_key {
    my ($url) = @_;
    my ($host) = $url =~ m{^[a-z][a-z0-9+.-]*://([^/:?#]+)}i or return;
    $host = lc $host;
    my @parts = split /\./, $host;
    for my $i (0 .. $#parts - 1) {                 # full host, then each parent domain
        my $candidate = join '.', @parts[$i .. $#parts];
        return $PLATFORM_HOSTS{$candidate} if $PLATFORM_HOSTS{$candidate};
    }
    my $name = @parts >= 2 ? $parts[-2] : $parts[0]; # unknown site: its domain name
    $name =~ s/[^a-z0-9]//g;
    return length $name ? $name : undef;
}

my (@warnings, %warned);
sub warn_note {
    my ($key, $msg) = @_;
    push @warnings, $msg;
    $warned{$key} = 1 if defined $key;
}

# ---- 1. find the numbers ------------------------------------------------------

my $html = slurp($html_path);

# Each connected account in link.me's page data looks like
#   linkValue:"https://www.instagram.com/thechubbitz", ... followerCount:50608
# [^{}]*? keeps the match inside that one account's object.
my %platforms;
while ($html =~ /\blinkValue\s*:\s*"([^"]*)"[^{}]*?\bfollowerCount\s*:\s*(\d+)/g) {
    my ($url, $count) = ($1, $2);
    my $key = platform_key($url);
    next unless defined $key;
    $platforms{$key} += $count;                      # two accounts on one platform add up
}

# link.me's own total: the exact number it embeds, or failing that the platforms
# added up, or failing that any follower counts at all.
my ($linkme_total) = $html =~ /\btotalFollowers\s*:\s*(\d+)/;
my $source = 'link.me totalFollowers';
if (!defined $linkme_total) {
    if (%platforms) {
        $linkme_total = 0;
        $linkme_total += $_ for values %platforms;
        $source = 'sum of ' . scalar(keys %platforms) . ' link.me platforms';
    } else {
        my @counts = $html =~ /\bfollowerCount\s*:\s*(\d+)/g;
        if (@counts) {
            $linkme_total = 0;
            $linkme_total += $_ for @counts;
            $source = 'sum of ' . scalar(@counts) . ' link.me follower counts';
        }
    }
}

die "No follower count found in the link.me page - it may have changed its layout. Nothing was written.\n"
    unless defined $linkme_total;

# Extra sources (e.g. Discord) are added on top.
my $total = $linkme_total;
for my $arg (@extra_args) {
    my ($name, $path) = $arg =~ /^([a-z0-9]+)=(.*)$/ or die "usage: $0 <linkme.html> [discord=<file>]\n";
    die "Unknown source '$name'. Known: " . join(', ', sort keys %SOURCES) . "\n" unless $SOURCES{$name};
    my $count = (-s $path) ? $SOURCES{$name}->(slurp($path)) : undef;
    if (defined $count && $count =~ /^\d+$/) {
        $platforms{$name} = $count;
        $total += $count;
        $source .= " + $name";
    } else {
        warn_note($name, "Couldn't read today's $name count, so it's left out of today's numbers.");
    }
}

die "Follower count $total doesn't look right. Nothing was written.\n"
    if $total <= 0 || $total > 1_000_000_000;

my $today = strftime('%Y-%m-%d', gmtime);

# ---- 2. load history and sanity-check against it -----------------------------

my @history;
if (-e $history_path) {
    my $decoded = decode_json(slurp($history_path));
    die "$history_path isn't a list. Nothing was written.\n" unless ref $decoded eq 'ARRAY';
    for my $e (@$decoded) {
        next unless ref $e eq 'HASH' && defined $e->{date} && defined $e->{followers};
        my %p;
        if (ref $e->{platforms} eq 'HASH') {
            for my $k (keys %{ $e->{platforms} }) {
                $p{$k} = $e->{platforms}{$k} if defined $e->{platforms}{$k} && $e->{platforms}{$k} =~ /^\d+$/;
            }
        }
        push @history, {
            date      => $e->{date},
            followers => $e->{followers},
            platforms => \%p,
            estimated => ($e->{estimated} ? 1 : 0),
        };
    }
}

my ($previous) = grep { $_->{date} lt $today } reverse sort { $a->{date} cmp $b->{date} } @history;

# A real audience doesn't halve overnight; a total that small means the page was
# read wrong, so keep yesterday's numbers rather than publish a bad one.
if ($previous && $total < $previous->{followers} * 0.5) {
    die "Follower count $total is less than half of $previous->{followers} on $previous->{date}. "
      . "Assuming a bad read. Nothing was written.\n";
}

# Same idea per platform, but softer: one account dropping out (usually link.me
# losing its connection) shouldn't block the whole day. Skip just that platform
# so its graph doesn't show a fake crash, and flag it.
if ($previous) {
    for my $key (sort keys %{ $previous->{platforms} }) {
        my $before = $previous->{platforms}{$key};
        next unless $before > 0;
        next if $warned{$key};
        if (!exists $platforms{$key}) {
            warn_note($key, "$key has no follower count today (had $before on $previous->{date}). Is it still connected?");
        } elsif ($platforms{$key} < $before * 0.5) {
            warn_note($key, "$key read as $platforms{$key}, under half of $before on $previous->{date}. Not recorded today.");
            # An extra source was added to the total above, so take it back out.
            # A link.me platform stays in: link.me's own total already includes it.
            $total -= $platforms{$key} if $SOURCES{$key};
            delete $platforms{$key};
        }
    }
}

# ---- 3. write metrics.js -----------------------------------------------------

my $formatted = compact($total);
my $js        = slurp($metrics_path);
my $new_js    = $js;
my $replaced  = ($new_js =~ s/(\{\s*value:\s*")[^"]*("\s*,\s*label:\s*"followers"\s*\})/${1}${formatted}${2}/);
die "Couldn't find the followers line in metrics.js. Nothing was written.\n" unless $replaced;

# ---- 4. write the history ----------------------------------------------------

# Today's reading replaces any entry already there for today - including an
# estimate - and is always a real reading.
@history = grep { $_->{date} ne $today } @history;
push @history, { date => $today, followers => $total, platforms => {%platforms}, estimated => 0 };
@history = sort { $a->{date} cmp $b->{date} } @history;

# One entry per line so each day shows up as a one-line diff. Platform names are
# always [a-z0-9], so they need no escaping.
sub entry_json {
    my ($e) = @_;
    my $line = sprintf '  {"date": "%s", "followers": %d', $e->{date}, $e->{followers};
    my @keys = sort keys %{ $e->{platforms} };
    if (@keys) {
        $line .= ', "platforms": {'
               . join(', ', map { sprintf '"%s": %d', $_, $e->{platforms}{$_} } @keys)
               . '}';
    }
    $line .= ', "estimated": true' if $e->{estimated};
    return $line . '}';
}
my $new_history = "[\n" . join(",\n", map { entry_json($_) } @history) . "\n]\n";

my $old_history = -e $history_path ? slurp($history_path) : '';

if ($new_js ne $js) { spit($metrics_path, $new_js) }
if ($new_history ne $old_history) {
    my $dir = dirname($history_path);
    mkdir $dir unless -d $dir;
    spit($history_path, $new_history);
}

# ---- 5. report ---------------------------------------------------------------

my $estimated = grep { $_->{estimated} } @history;

printf "Followers: %d (%s), from %s\n", $total, $formatted, $source;
if (%platforms) {
    my $sum = 0;
    $sum += $_ for values %platforms;
    for my $key (sort { $platforms{$b} <=> $platforms{$a} } keys %platforms) {
        printf "  %-10s %d\n", $key, $platforms{$key};
    }
    printf "  (platforms add up to %d%s)\n", $sum, $sum == $total ? ', matching the total' : '';
} else {
    print "  No per-platform counts found.\n";
}
printf "metrics.js: %s\n", $new_js ne $js ? "updated" : "unchanged";
printf "data/followers.json: %s, %d day%s of history%s\n",
    $new_history ne $old_history ? "updated" : "unchanged",
    scalar(@history), @history == 1 ? '' : 's',
    $estimated ? " ($estimated estimated)" : '';

# In GitHub Actions, ::warning:: shows up as a yellow note on the run page.
for my $w (@warnings) {
    print $ENV{GITHUB_ACTIONS} ? "::warning::$w\n" : "Warning: $w\n";
}
