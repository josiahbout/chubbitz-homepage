#!/usr/bin/env perl
# Builds sitemap.xml: every page on the site, except ones marked noindex.
#
# Run automatically by .github/workflows/sitemap.yml whenever an .html file is
# pushed, so adding a page is all it takes - it appears in the sitemap on its
# own, and a deleted page drops out.
#
# To keep a page OUT of the sitemap (and out of search results), give it
#   <meta name="robots" content="noindex">
#
#   perl scripts/build-sitemap.pl
#
# Each page's <lastmod> is the date of the last commit that changed its file.

use strict;
use warnings;
use File::Find;
use File::Spec;
use File::Basename qw(dirname basename);
use POSIX qw(strftime);

my $SITE = 'https://thechubbitz.com';

# Folders that hold assets, data or tooling rather than pages.
my %SKIP_DIRS = map { $_ => 1 } qw(media data scripts node_modules);

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
chdir $root or die "can't cd to $root: $!\n";

my @files;
find({
    no_chdir   => 1,
    preprocess => sub { grep { $_ eq '.' || $_ eq '..' || (!/^\./ && !$SKIP_DIRS{$_}) } @_ },
    wanted     => sub { push @files, $File::Find::name if -f $_ && /\.html?$/i },
}, '.');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "can't read $path: $!\n";
    local $/;
    return scalar <$fh>;
}

sub noindex {
    my ($html) = @_;
    while ($html =~ /(<meta\b[^>]*>)/gi) {
        my $tag = $1;
        return 1 if $tag =~ /\bname\s*=\s*["']?robots\b/i && $tag =~ /noindex/i;
    }
    return 0;
}

# Date of the last commit touching the file; today if it isn't committed yet.
sub lastmod {
    my ($file) = @_;
    # quiet git while it runs, so a copy of the site without history falls back
    # to today silently instead of printing "fatal: not a git repository"
    open my $saved_err, '>&', \*STDERR or die "can't save STDERR: $!\n";
    open STDERR, '>', File::Spec->devnull;
    my $date;
    if (open my $git, '-|', 'git', 'log', '-1', '--format=%cs', '--', $file) {
        $date = <$git>;
        close $git;
    }
    open STDERR, '>&', $saved_err or die "can't restore STDERR: $!\n";
    $date = '' unless defined $date;
    $date =~ s/\s+//g;
    return $date =~ /^\d{4}-\d{2}-\d{2}$/ ? $date : strftime('%Y-%m-%d', gmtime);
}

sub xml_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

my (@pages, @hidden);
for my $file (sort @files) {
    (my $rel = $file) =~ s{^\./}{};
    next if basename($rel) =~ /^404\.html?$/i;          # error page, not a destination

    # support/index.html -> /support/   index.html -> /   notes.html -> /notes.html
    my $path = '/' . $rel;
    $path =~ s{(^|/)index\.html?$}{$1}i;

    if (noindex(slurp($rel))) {
        push @hidden, $path;
        next;
    }
    push @pages, { path => $path, lastmod => lastmod($rel) };
}

# Homepage first, then alphabetical.
@pages = sort { ($a->{path} eq '/' ? 0 : 1) <=> ($b->{path} eq '/' ? 0 : 1) || $a->{path} cmp $b->{path} } @pages;

my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n}
        . qq{<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n};
for my $p (@pages) {
    $xml .= "  <url>\n"
          . "    <loc>" . xml_escape($SITE . $p->{path}) . "</loc>\n"
          . "    <lastmod>$p->{lastmod}</lastmod>\n"
          . "  </url>\n";
}
$xml .= "</urlset>\n";

my $out = 'sitemap.xml';
my $old = -e $out ? slurp($out) : '';
if ($xml ne $old) {
    open my $fh, '>:raw', $out or die "can't write $out: $!\n";
    print {$fh} $xml;
    close $fh;
}

printf "sitemap.xml: %s, %d page%s\n", $xml ne $old ? 'updated' : 'unchanged', scalar(@pages), @pages == 1 ? '' : 's';
printf "  %-24s %s\n", $_->{path}, $_->{lastmod} for @pages;
print  "left out (noindex): ", join(', ', @hidden), "\n" if @hidden;
