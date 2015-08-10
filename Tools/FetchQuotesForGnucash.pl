#!/usr/bin/perl -w

use lib '../lib';

use strict;
use Data::GUID;
use DBI;
use Finance::Quote;
use POSIX qw/strftime/;

my $gnucash = "/home/hajo/Finanzen/Test.gnucash";
my $quotedb = "./Quotes.db";

my $logging = 1;
my $dbargs = {AutoCommit => 1, PrintError => 0, RaiseError => 1};

my $gncexists = (-e $gnucash);

my $dbh_gnucash;
if ($gncexists) {
	$dbh_gnucash = DBI->connect("dbi:SQLite:dbname=$gnucash", "", "", $dbargs) 
	               or die "can't connect to $gnucash\n";
}

my $dbh_quotes = DBI->connect("dbi:SQLite:dbname=$quotedb", "", "", $dbargs) 
                 or die "can't connect to $quotedb\n";
				 
&check_db_objects();

my $gnclock = &check_lock();

if ($gncexists) { 
	&sync_commodities; 
}

&fetch_quotes();

if ($gncexists) {
	$dbh_gnucash->disconnect();
}
$dbh_quotes->disconnect();


sub check_lock #----------------------------------------------------------------
{
	if ($logging) { print "Checking if gnucash file is locked.\n"; }

	if ($gncexists) {
		my ($count) = $dbh_gnucash->selectrow_array("SELECT COUNT(*) FROM gnclock");
		#print "Number of rows in gnclock: $count\n";	
		
		if ($count > 0) {
			if ($logging) { print "Gnucash file is locked.\n"; }
			return 1;
		} else {
			if ($logging) { print "Gnucash file is not locked.\n"; }
			return 0;
		}
	}
	else {
		return 0;
	}
}

sub check_db_objects #---------------------------------------------------------
{
	if ($logging) { print "Checking database objects in './Quotes.db'.\n"; }
	
	$dbh_quotes->do("CREATE TABLE IF NOT EXISTS settings (" .
						"key TEXT(32) PRIMARY KEY NOT NULL, " .
						"value TEXT(2048) NOT NULL)"
					);
					
	$dbh_quotes->do("CREATE TABLE IF NOT EXISTS commodities (" .
						"guid TEXT(32) PRIMARY KEY NOT NULL, " .
						"namespace TEXT(2048) NOT NULL, " .
						"symbol TEXT(2048) NOT NULL, " .
						"fullname TEXT(2048), " .
						"source TEXT(2048), " .
						"date TEXT(14), " .
						"value_num BIGINT, " .
						"value_denom BIGINT)"
					);
					
	$dbh_quotes->do("CREATE TABLE IF NOT EXISTS quotes (" .
						"commodity_guid TEXT(32) NOT NULL, " .
						"currency_guid TEXT(32) NOT NULL, " .
						"date TEXT(14) NOT NULL, " .
						"value_num BIGINT NOT NULL, " .
						"value_denom BIGINT NOT NULL, " .
						"PRIMARY KEY (commodity_guid, date))"
					);
}

sub sync_commodities #---------------------------------------------------------
{
	if ($logging) { print "Syncing commodities\n"; }
	
	my ($guid, $namespace, $symbol, $fullname, 
	    $source, $date, $value_num, $value_denom) = "";
		
	my $res = $dbh_gnucash->selectall_arrayref("SELECT guid, namespace, mnemonic, fullname, quote_source FROM commodities WHERE quote_flag=1 ORDER BY namespace, mnemonic;");
	
	my $sth = $dbh_quotes->prepare( "SELECT guid FROM commodities WHERE guid = ?" );
	my $sth_qi = $dbh_quotes->prepare( "INSERT OR REPLACE INTO commodities (guid, namespace, symbol, fullname, source) VALUES (?,?,?,?,?)" );

	if ($logging) { print 0+@$res . " commodities in gnucash\n"; }
		
	foreach my $row (@$res) {
		($guid, $namespace, $symbol, $fullname, $source) = @$row;
		
		#TODO Find a way to do insert or update instead of replacing existing entries
		
		$sth_qi->bind_param( 1, $guid );
		$sth_qi->bind_param( 2, $namespace );
		$sth_qi->bind_param( 3, $symbol );
		$sth_qi->bind_param( 4, $fullname );
		$sth_qi->bind_param( 5, $source );

		$sth_qi->execute() or die "$DBI::errstr\n";
	}
	
	my ($basecurrency_guid,$basecurrency) = 
		$dbh_gnucash->selectrow_array("SELECT c.guid, c.mnemonic " .
									  "FROM accounts a " .
									  "JOIN commodities c ON a.commodity_guid=c.guid " .
									  "WHERE a.name='Root Account'");
									  
	if ($logging) { print "base currency: $basecurrency ($basecurrency_guid)\n"; }
	
	$dbh_quotes->do( "INSERT OR REPLACE INTO settings (key, value) VALUES ('base currency', '$basecurrency:$basecurrency_guid')" );
}

sub print_commodities
{
	my ($guid, $namespace, $mnemonic, $quote_source) = "";
	my $res = $dbh_quotes->selectall_arrayref("SELECT guid, namespace, mnemonic, quote_source "
                                             ."FROM commodities "
											 ."WHERE quote_flag=1 "
											 ."ORDER BY namespace;");
	foreach my $row (@$res) {
		($guid, $namespace, $mnemonic, $quote_source) = @$row;
		print("$guid\t$namespace\t$mnemonic\t$quote_source\n");
	}
}

my ($base_currency, $base_guid);
my %currencies;

sub fetch_quotes #-------------------------------------------------------------
{
	if ($logging) { print "Fetching quotes\n"; }
	
	my $quoter = Finance::Quote->new();
	my $denom = 100000000;
	
	#get base currency
	my ($value) = 
		$dbh_quotes->selectrow_array("SELECT value FROM settings WHERE key='base currency'");
	($base_currency, $base_guid) = split(":", $value);
	
	$currencies{$base_currency} = $base_guid;
	
	if ($logging) { print "$base_currency -> $base_guid\n"; }
	
	#prepare queries
	my $upd_commodities = $dbh_quotes->prepare( "UPDATE commodities SET date=?, value_num=?, value_denom=? WHERE guid=?" );
	my $ins_quotes = $dbh_quotes->prepare( "INSERT INTO quotes VALUES(?, ?, ?, ?, ?)" );
	my $upd_quotes = $dbh_quotes->prepare( "UPDATE quotes SET date=?, value_num=?, value_denom=? WHERE commodity_guid=? AND SUBSTR(date, 1, 8)=?" );
	
	#get all commodities to update
	my ($guid, $namespace, $symbol, $source) = "";
	my $res = $dbh_quotes->selectall_arrayref(
		"SELECT guid, namespace, symbol, source, " .
		"       CASE namespace WHEN 'CURRENCY' THEN 1 ELSE 2 END AS ordernr " .
		"FROM commodities " .
		"WHERE guid!='$base_guid' " .
		"ORDER BY ordernr, namespace, symbol;"
	);

	my $date = strftime('%Y%m%d%H%M%S',localtime);
	my $currency_guid;
	
	foreach my $row (@$res) {
		($guid, $namespace, $symbol, $source) = @$row;
		
		my $value = 0.00;
			
		if ($source eq "currency") {
		
			$currencies{$symbol} = $guid;
			
			$value = $quoter->currency($symbol, $base_currency);
			$currency_guid = $base_guid;

			#print "guid:\n".new_guid()."\n";
			

		} else {
		
			my %quotes = $quoter->fetch($source, $symbol);
			
			unless ($quotes{$symbol,"success"}) {
				warn "Lookup of $symbol failed - ".$quotes{$symbol,"errormsg"}."\n";
				next;
			}
			
			$date = $quotes{$symbol,"isodate"}." ".$quotes{$symbol,"time"}."00";
			$date =~ s/-//g; 
			$date =~ s/://g; 
			$date =~ s/ //g; 
			
			$value = $quotes{$symbol,"price"};
			$currency_guid = $currencies{$quotes{$symbol,"currency"}};
		}
	
		$upd_commodities->bind_param( 1, $date );
		$upd_commodities->bind_param( 2, $value*$denom );
		$upd_commodities->bind_param( 3, $denom );
		$upd_commodities->bind_param( 4, $guid );
		
		$upd_quotes->bind_param( 1, $date );
		$upd_quotes->bind_param( 2, $value*$denom );
		$upd_quotes->bind_param( 3, $denom );
		$upd_quotes->bind_param( 4, $guid );
		$upd_quotes->bind_param( 5, substr ($date,0,8) );
		
		my $count = 0;
		if ($value != 0.00) {
			
			$count = $upd_commodities->execute();
			
			if ( $upd_quotes->execute() < 1 ) {

					$ins_quotes->bind_param( 1, $guid );
					$ins_quotes->bind_param( 2, $currency_guid );
					$ins_quotes->bind_param( 3, $date );
					$ins_quotes->bind_param( 4, $value*$denom );
					$ins_quotes->bind_param( 5, $denom );
					
					$ins_quotes->execute();
					
					#if ($logging) { print "Quote inserted.\n"; }
			} #else {
				#if ($logging) { print "Quote updated.\n"; }	
			#}
		} 
		
		if ($logging) { print "$symbol\t$date\t$value\n"; }		
	}
	
	#for my $cur (keys %currencies) {
	#	print "$cur => $currencies{$cur}\n";
	#}
}

sub new_guid
{
	my $guid = substr (lc(Data::GUID->new->as_hex), 2);
	return $guid;
}

