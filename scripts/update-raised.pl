#!/usr/bin/env perl
# Daily "amount raised" update.
#
# Adds up what supporters have paid through Stripe and writes:
#   - raised.js         the figure the /support bar and counter read
#   - data/raised.json  one entry per day, so the history is there if the
#                       number is ever plotted like followers are
#
# Run by .github/workflows/update-raised.yml once a day:
#   perl scripts/update-raised.pl <dir-of-stripe-pages>
#
#   <dir>  a folder of Stripe /v1/balance_transactions responses, one JSON
#          file per page, as the workflow downloads them.
#
# WHAT COUNTS
#   Gross, not net: what the supporter paid, before Stripe's fee. Refunds and
#   lost disputes subtract, because Stripe records them as negative rows, so
#   the figure can go down as well as up - that is on purpose and correct.
#   Gumroad sales are not counted; this reads Stripe only.
#
# THE BASELINE
#   Daily tracking started on $START_DATE. Money taken before then isn't in
#   the window Stripe is asked for, so it's carried as $BASELINE_CENTS below.
#   Change either only if you mean to restate the total.
#
# NOTHING IS WRITTEN unless the day's numbers look believable, so a failed
# download or a bad read leaves the site showing its last good figure.

use strict;
use warnings;
use JSON::PP;
use POSIX qw(strftime);
use File::Basename qw(dirname);
use File::Spec;

# Taken before daily tracking began, in cents. $112.
my $BASELINE_CENTS = 11200;
my $START_DATE     = '2026-11-04';

# Only this currency is counted. Stripe reports every amount in the smallest
# unit, so these are cents.
my $CURRENCY = 'usd';

# The balance-transaction types that are money raised. The refund and dispute
# ones carry a negative amount and so subtract themselves.
my %COUNTS = map { $_ => 1 } qw(
    charge
    payment
    refund
    payment_refund
    payment_failure_refund
    adjustment
);

# A total outside this range means something was read wrong. Nothing is
# written in that case.
my $MAX_CENTS = 100_000_000;        # $1,000,000

my ($dir) = @ARGV;
die "usage: $0 <dir-of-stripe-pages>\n" unless defined $dir;

my $root         = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $raised_path  = File::Spec->catfile($root, 'raised.js');
my $history_path = File::Spec->catfile($root, 'data', 'raised.json');

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

my @warnings;
sub warn_note { push @warnings, $_[0] }

# ---- 1. add up what Stripe reported -----------------------------------------

my @pages = sort glob(File::Spec->catfile($dir, '*.json'));
die "No Stripe pages found in $dir. Nothing was written.\n" unless @pages;

my ($cents, $rows, %by_type) = (0, 0);
for my $page (@pages) {
    my $data = eval { decode_json(slurp($page)) };
    die "Couldn't read $page as JSON. Nothing was written.\n" unless ref $data eq 'HASH';
    die "Stripe returned an error in $page. Nothing was written.\n" if $data->{error};
    my $list = $data->{data};
    die "$page has no list of transactions. Nothing was written.\n" unless ref $list eq 'ARRAY';

    for my $t (@$list) {
        next unless ref $t eq 'HASH';
        my $type = defined $t->{type} ? $t->{type} : '';
        next unless $COUNTS{$type};
        next unless defined $t->{currency} && lc $t->{currency} eq $CURRENCY;
        next unless defined $t->{amount} && $t->{amount} =~ /^-?\d+$/;
        $cents += $t->{amount};
        $by_type{$type} += $t->{amount};
        $rows++;
    }
}

my $total_cents = $BASELINE_CENTS + $cents;

die "Total $total_cents cents is negative. Nothing was written.\n" if $total_cents < 0;
die "Total $total_cents cents doesn't look right. Nothing was written.\n" if $total_cents > $MAX_CENTS;

# Whole dollars, rounded down, which is how the page shows it.
my $dollars = int($total_cents / 100);
my $today   = strftime('%Y-%m-%d', gmtime);

# ---- 2. load the history and compare ----------------------------------------

my @history;
if (-e $history_path) {
    my $decoded = decode_json(slurp($history_path));
    die "$history_path isn't a list. Nothing was written.\n" unless ref $decoded eq 'ARRAY';
    for my $e (@$decoded) {
        next unless ref $e eq 'HASH' && defined $e->{date} && defined $e->{raised};
        push @history, { date => $e->{date}, raised => $e->{raised}, cents => $e->{cents} };
    }
}

my ($previous) = grep { $_->{date} lt $today } reverse sort { $a->{date} cmp $b->{date} } @history;

# A fall is legitimate - someone was refunded - so it's said out loud rather
# than treated as a failure.
if ($previous && $dollars < $previous->{raised}) {
    warn_note("Raised fell from \$$previous->{raised} on $previous->{date} to \$$dollars. "
            . "That's expected after a refund or a lost dispute; check Stripe if it isn't.");
}

# ---- 3. write raised.js -----------------------------------------------------

my $js       = slurp($raised_path);
my $new_js   = $js;
my $replaced = ($new_js =~ s/(\bvar\s+CHUBBITZ_RAISED\s*=\s*)\d+(\s*;)/${1}${dollars}${2}/);
die "Couldn't find CHUBBITZ_RAISED in raised.js. Nothing was written.\n" unless $replaced;

# ---- 4. write the history ---------------------------------------------------

@history = grep { $_->{date} ne $today } @history;
push @history, { date => $today, raised => $dollars, cents => $total_cents };
@history = sort { $a->{date} cmp $b->{date} } @history;

my $new_history = "[\n"
    . join(",\n", map { sprintf '  {"date": "%s", "raised": %d, "cents": %d}',
                        $_->{date}, $_->{raised}, $_->{cents} } @history)
    . "\n]\n";

my $old_history = -e $history_path ? slurp($history_path) : '';

if ($new_js ne $js) { spit($raised_path, $new_js) }
if ($new_history ne $old_history) {
    my $hist_dir = dirname($history_path);
    mkdir $hist_dir unless -d $hist_dir;
    spit($history_path, $new_history);
}

# ---- 5. report --------------------------------------------------------------

printf "Raised: \$%d (%d cents), from a \$%.2f baseline plus %d Stripe row%s since %s\n",
    $dollars, $total_cents, $BASELINE_CENTS / 100, $rows, $rows == 1 ? '' : 's', $START_DATE;
for my $type (sort { $by_type{$b} <=> $by_type{$a} } keys %by_type) {
    printf "  %-22s %+.2f\n", $type, $by_type{$type} / 100;
}
printf "raised.js: %s\n", $new_js ne $js ? "updated" : "unchanged";
printf "data/raised.json: %s, %d day%s of history\n",
    $new_history ne $old_history ? "updated" : "unchanged",
    scalar(@history), @history == 1 ? '' : 's';

for my $w (@warnings) {
    print $ENV{GITHUB_ACTIONS} ? "::warning::$w\n" : "Warning: $w\n";
}
