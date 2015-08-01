#!/usr/bin/perl -W
#
#    Copyright (C) 1998, Dj Padzensky <djpadz@padz.net>
#    Copyright (C) 1998, 1999 Linas Vepstas <linas@linas.org>
#    Copyright (C) 2000, Yannick LE NY <y-le-ny@ifrance.com>
#    Copyright (C) 2000, Paul Fenwick <pjf@cpan.org>
#    Copyright (C) 2000, Brent Neal <brentn@users.sourceforge.net>
#    Copyright (C) 2000, Volker Stuerzl <volker.stuerzl@gmx.de>
#    Copyright (C) 2003,2005,2006 Jörg Sommer <joerg@alea.gnuu.de>
#    Copyright (C) 2008 Martin Kompf (skaringa at users.sourceforge.net)
#    Copyright (C) 2014, Erik Colson <ecocode@cpan.org>
#    Copyright (C) 2014, Hajo Hindriks <hajo at hindriks.ch>
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
#    02111-1307, USA
#
#
# This code is derived from the work in the package
# Finance::Quote::VWD. It fetches Postsoleil quotes 
# from morningstar.ch
#
# This code was developed to be used from GnuCash <http://www.gnucash.org/>

# =============================================================

package Finance::Quote::MorningstarCH;
require 5.005;

use strict;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTML::TreeBuilder;
use HTML::TableExtract;
use Data::Dumper;

our $VERSION = '1.37'; # VERSION

my $url1 = 'http://www.morningstar.ch/ch/funds/SecuritySearchResults.aspx?search=ch0006869231&type=';
my $urlDetails = 'http://www.morningstar.ch/ch/funds/snapshot/snapshot.aspx?id=';

# LOGGING - set to 1 to enable log file
my $logging = 1;
my $logfile = '>>./PostFinance.log';

sub methods { return ( morningstarch => \&morningstarch ); }

sub labels {
    return ( morningstarch => [ qw/currency date isodate name price last symbol time/ ] );
}

# =======================================================================
# The vwd routine gets quotes of funds from the website of
# vwd Vereinigte Wirtschaftsdienste GmbH.
#
# This subroutine was written by Volker Stuerzl <volker.stuerzl@gmx.de>
# and adjusted to match the new vwd interface by Jörg Sommer

# Trim leading and tailing whitespaces (also non-breakable whitespaces)
sub trim {
    $_ = shift();
    s/^\s*//;
    s/\s*$//;
    s/&nbsp;//g;
    return $_;
}

# Trim leading and tailing whitespaces, leading + and tailing %, leading
# and tailing &plusmn; (plus minus) and translate german separators into
# english separators. Also removes the thousands separator in returned
# values.
sub trimtr {
    $_ = shift();
    s/&nbsp;//g;
    s/&plusmn;//g;
    s/^\s*\+?//;
    s/\%?\s*$//;
    tr/,./.,/;
    s/,//g;
    return $_;
}

sub morningstarch {
    my $quoter = shift;
    my $ua     = $quoter->user_agent();
    my @funds  = @_;
    return unless (@funds);
    my %info;

    if ($logging) {
        open( LOG, $logfile );
    }

    my $max_retry = 30;
    foreach my $fund (@funds) {
        $info{ $fund, "source" }   = "MorningstarCH";
        $info{ $fund, "success" }  = 0;
        $info{ $fund, "errormsg" } = "Parse error";

        # there is another page first to determine the needed id based on the ISIN or Valor, 
        # in a first phase I will just use an if statement and hardcode the id            
        my $id;
        
        # Postsoleil 2
        if (($fund eq "686921") || ($fund eq "686'921") || ($fund eq "CH0006869215")) {
            $id = "F0GBR04PII";
            $info{ $fund, "symbol" } = "686921";
        } 
        
        # Postsoleil 3
        if (($fund eq "686923") || ($fund eq "686'923") || ($fund eq "CH0006869231")) {
            $id = "F0GBR04PIJ";
            $info{ $fund, "symbol" } = "686923";
        } 
     
        my $request = $urlDetails
            . $id;
            
        if ($logging) {
            print LOG "Request='$request'\n";
        }
        
        my $response = $ua->get($request);
        if ( $response->is_success ) {
            
            if ($logging) {
                print LOG "Request was successful.'\n";
            }            
            
            my $html = $response->decoded_content;

            my $tree = HTML::TreeBuilder->new;
            $tree->parse($html);
            
            # find name of fund
            my $divTitle =
                $tree->look_down( "_tag", "div", "class", "snapshotTitleBox");
            next if not $divTitle;
            
            my $title = $divTitle->find("h1");
            next if not $title;
            
            $info{ $fund, "name" } = $title->as_trimmed_text;
            
            if ($logging) {
                print LOG "title found: '$title->as_trimmed_text'\n";
            } 
            
            # all other info below <div class=contentBox>
            my $quickstats =
                $tree->look_down( "_tag", "div", "id", "overviewQuickstatsDiv" );
            next if not $quickstats;
            
            my $te = new HTML::TableExtract( depth => 0, count => 0 );
            $te->parse( $quickstats->as_HTML );
            my $table = $te->first_table_found;
            
            # date, e.g NAV 30.07.2015 
            my $cellDate = $table->cell(1, 0); #row 1, column 0
            my $datum = substr($cellDate, 4);
            
            if ($logging) {
                print LOG "datum: $datum\n";
            }
            if ( $datum =~ /([(0123]\d)\.([01]\d)\.(\d\d\d\d)/ ) {
                # datum contains date
                $quoter->store_date( \%info, $fund,
                                     { day => $1, month => $2, year => $3 } );
                $info{ $fund, "time" } = $quoter->isoTime("21:00");
            }
            
            # currency and price, e.g CHF?107,58
            my $cellValue = $table->cell(1, 2); #row 1, column 2
			
            my $fundCurrency = substr($cellValue, 0, 3);
			$info{ $fund, "currency" } = $fundCurrency;
			
            my $fundPrice = join('.', (split (',', substr($cellValue, 4))));
    
            $info{ $fund, "price" } = $info{ $fund, "last" } = $fundPrice;

            if ($logging) {
                print LOG "Currency found: $fundCurrency\n";
                print LOG "Value found: $fundPrice\n";
            }   
                     
            # fund ok
            $info{ $fund, "success" }  = 1;
            $info{ $fund, "errormsg" } = "";
			
            # log
            if ($logging) {
                print LOG join( ':',
                                $info{ $fund, "name" },
                                $info{ $fund, "symbol" },
                                $info{ $fund, "date" },
                                $info{ $fund, "time" },
                                $info{ $fund, "price" },
                                $info{ $fund, "currency" } );
                print LOG "\n";
            }

            $tree->delete;
        }
        else {
            print "Nach ELSE=============";
            $info{ $fund, "success" }  = 0;
            $info{ $fund, "errormsg" } = "HTTP error " . $response->status_line;
            if ($logging) {
                print LOG "ERROR $fund: " . $info{ $fund, "errormsg" } . "\n";
            }
            if ( $response->code == 503 && $max_retry-- > 0 ) {

                # The server limits the number of request per time and client
                sleep 5;
                redo;
            }
        }
    }

    if ($logging) {
        close LOG;
    }
    return wantarray() ? %info : \%info;
}

1;

=head1 NAME

Finance::Quote::MorningstarCH  - Obtain quotes from morningstar.ch.

=head1 SYNOPSIS

    use Finance::Quote;

    $q = Finance::Quote->new;

    %stockinfo = $q->fetch("morningstar","868921");

=head1 DESCRIPTION

This module obtains information from vwd Vereinigte Wirtschaftsdienste GmbH
http://www.vwd.de/. Many european stocks and funds are available, but
at the moment only funds are supported.

Information returned by this module is governed by vwd's terms
and conditions.

=head1 LABELS RETURNED

The following labels may be returned by Finance::Quote::MorningstarCH:
currency date isodate name price last symbol time.

=head1 SEE ALSO

Morningstar Schweiz, http://www.morningstar.ch

=cut
