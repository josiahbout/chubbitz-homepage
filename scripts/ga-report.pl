#!/usr/bin/env perl
# Reads Google Analytics reports for thechubbitz.com (read-only).
#
# Signs in as the "analytics-reader" service account using its key file, then
# sends one report request to the Google Analytics Data API and prints the
# JSON answer.
#
#   perl scripts/ga-report.pl '<report request json>'
#   perl scripts/ga-report.pl - < request.json
#
# Example - views per page over the last 7 days:
#   perl scripts/ga-report.pl '{"dateRanges":[{"startDate":"7daysAgo","endDate":"today"}],
#     "dimensions":[{"name":"pagePath"}],"metrics":[{"name":"screenPageViews"}]}'
#
# Request format: https://developers.google.com/analytics/devguides/reporting/data/v1/rest/v1beta/properties/runReport
#
# The key file lives OUTSIDE the website folder so it can never be pushed.
# Set GA_KEY to use a different location.

use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempfile);
use File::Spec;
use File::Basename qw(dirname);

my $PROPERTY = $ENV{GA_PROPERTY} || '544336223';
my $KEY_FILE = $ENV{GA_KEY}
    || File::Spec->catfile(dirname(__FILE__), '..', '..', 'ga-key.json');
my $METHOD   = $ENV{GA_METHOD} || "runReport";   # or runRealtimeReport (last 30 minutes)
my $SCOPE    = 'https://www.googleapis.com/auth/analytics.readonly';

my $body = shift or die "usage: $0 '<report request json>'  (or - to read stdin)\n";
if ($body eq '-') { local $/; $body = <STDIN>; }
decode_json($body);    # fail early on a malformed request

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "can't read $path: $!\n";
    local $/;
    return scalar <$fh>;
}

sub b64url {
    my $s = encode_base64($_[0], '');
    $s =~ tr{+/}{-_};
    $s =~ s/=+$//;
    return $s;
}

# Runs a command with its arguments passed straight through (no shell) and
# returns what it printed.
sub run {
    my (@cmd) = @_;
    open my $p, '-|', @cmd or die "can't run $cmd[0]: $!\n";
    binmode $p;
    local $/;
    my $out = <$p>;
    close $p;
    return defined $out ? $out : '';
}

# ---- sign in ----

-e $KEY_FILE or die "key file not found: $KEY_FILE\n";
my $key = decode_json(slurp($KEY_FILE));
$key->{type} && $key->{type} eq 'service_account' or die "$KEY_FILE isn't a service account key\n";

my $now    = time;
my $unsigned = b64url(encode_json({ alg => 'RS256', typ => 'JWT' })) . '.'
             . b64url(encode_json({
                   iss   => $key->{client_email},
                   scope => $SCOPE,
                   aud   => $key->{token_uri},
                   iat   => $now,
                   exp   => $now + 3600,
               }));

# openssl needs the private key and the data as files; both are deleted right after
my ($kfh, $kpath) = tempfile(UNLINK => 1);
binmode $kfh; print {$kfh} $key->{private_key}; close $kfh;
my ($dfh, $dpath) = tempfile(UNLINK => 1);
binmode $dfh; print {$dfh} $unsigned; close $dfh;

my $sig = run('openssl', 'dgst', '-sha256', '-sign', $kpath, $dpath);
unlink $kpath, $dpath;
length $sig or die "signing failed\n";

my $token_json = run('curl', '-s', '-X', 'POST', $key->{token_uri},
    '--data-urlencode', 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer',
    '--data-urlencode', "assertion=$unsigned." . b64url($sig));
my $token = eval { decode_json($token_json)->{access_token} }
    or die "sign-in failed: $token_json\n";

# ---- report ----

my ($bfh, $bpath) = tempfile(UNLINK => 1);
binmode $bfh; print {$bfh} $body; close $bfh;

my $report = run('curl', '-s', '-X', 'POST',
    "https://analyticsdata.googleapis.com/v1beta/properties/$PROPERTY:$METHOD",
    '-H', "Authorization: Bearer $token",
    '-H', 'Content-Type: application/json',
    '--data-binary', "\@$bpath");
unlink $bpath;

print JSON::PP->new->pretty->canonical->encode(decode_json($report));
