#!/usr/bin/perl -w
use strict;

use lib '../lib';

use Finance::Quote;
use POSIX qw/strftime/;

my $base = "CHF";
my %rates = ("EUR", "USD");
my %stocklist = ("ADEN.VX", "LOGN.SW", "SREN.VX", "UBSG.VX");
my %fundlist = ("686921", "686923");

print "==================================================================================\n";
print "=== Update Currencies and Rates                                                ===\n";
print "=== "
      .strftime('%d-%b-%Y %H:%M',localtime)
      ."                                                          ===\n";                                           
print "==================================================================================\n\n";

my $quoter = Finance::Quote->new();

print "Currency   Rate\n";
print "----------------------------------------------------------------------------------\n";

foreach my $rate (%rates){
	print $rate."        ".$quoter->currency($rate, $base)." $base\n";	
}

print "\n";


my ($name, $date, $last, $p_change, $high, $low, $volume, $close);

format STDOUT_TOP =

Ticker         Date       Last  %Change        High       Low    Volume      Close
----------------------------------------------------------------------------------
.

format STDOUT =
@<<<<<< @>>>>>>>>>>  @####.### @###.###   @####.### @####.### @>>>>>>>>  @####.###
$name,  $date,       $last,   $p_change, $high,   $low,    $volume,   $close
.

my %stocks = $quoter->fetch("yahoo", %stocklist);

foreach my $code (%stocklist) {
	unless ($stocks{$code,"success"}) {
		warn "Lookup of $code failed - ".$stocks{$code,"errormsg"}."\n";
		next;
	}
	$name = $code;
	$date = $stocks{$code,'date'};
	$last = $stocks{$code,'last'};
	$p_change = $stocks{$code,'p_change'};
	$high = $stocks{$code,'high'};
	$low = $stocks{$code,'low'};
	$volume = $stocks{$code,'volume'};
	$close = $stocks{$code,'close'};
	write;
}

my %funds = $quoter->fetch("morningstarch", %fundlist);
print "\n\n";

#use Data::Dumper;
#print Dumper(\%stocks);
#print Dumper(\%funds);

print "Fund\t\t\tDate\t\tPrice\n";
print "----------------------------------------------------------------------------------\n";
foreach my $fund (%fundlist) {
	print $funds{$fund, 'name'}."\t".$funds{$fund, 'date'}."\t".$funds{$fund, 'price'}." ".$funds{$fund, 'currency'}."\n";
}

print "\n\n";
