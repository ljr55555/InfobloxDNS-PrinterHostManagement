################################################################################
##      Date:           2015-08-07
##      Author:         Lisa Rushworth
##      Purpose:         This program finds any new or updated records in the
##			$strDBDatabase.$strDBTable table and updates the DNS zone
##			$strPrinterZone accordingly.
##      Version:        1.0     LJR     2015-08-07      Initial Code
##
##      Notes:
################################################################################
##      Editable Variables
################################################################################
$strInfobloxMaster = "infoblox.company.gTLD";
$strPrinterZone = 'printers.company.gTLD';
$strAlertRecipients = 'me@company.gTLD';
$strViewName = 'ViewName';
$strMailRelay = 'mail.company.gTLD';
$strAlertSender = 'devnull@company.gTLD';
# File with seed used for crypt_tea password encryption 
$strCryptTeaSeed = '/path/to/seed/file';
# Infoblox credentials with API access
$strIBUID = "5d316345667a376e525a5669704c37534764366a5477";
$strIBPWD = "5c4237316a5f3853434b6a37797a356a3274645a647959495466414969535352";
# Database read only credentials
$strDBUID = "52766367412d49665575537a5946362d556c32346141";
$strDBPWD = "575541666b25736846614e7a39366830715645526441";
$strDBHost = 'dbserver.company.gTLD';
$strDBDatabase = 'databaseName';
$strDBTable = 'printerInventoryTable';
$strMessageSubject = "Printer DNS Update Failure"
################################################################################
#               DO NOT EDIT BELOW THIS LINE UNLESS YOU REALLY MEAN IT         ##
################################################################################
use Crypt::Tea;
use Date::Manip;
use DBI;
use Infoblox;
use File::Spec;
use Mail::Sender;

my $strDirectoryName = File::Spec->rel2abs(__FILE__);
my $strScriptFile =$0;

if(length($strDirectoryName) < length($strScriptFile)){
        $strDirectoryName =~ s/$strScriptFile$//;
}
else{
        $strDirectoryName =~ s/[^\/]+$//;
        $strScriptFile =~ s/^$strDirectoryName//;
}
print "Current path is $strDirectoryName and the file is $strScriptFile\n";

$strScriptPath = $strDirectoryName . '/' . $strScriptFile;

my $strScriptHost = $ENV{HOSTNAME};
chomp($strScriptHost);


my $strHistoryFile = $strScriptPath . "history.txt";
open(HISTORY, ">>$strHistoryFile");

$strIBUID = &decryptTeaString($strIBUID);
$strIBPWD = &decryptTeaString($strIBPWD);

$strDBUID = &decryptTeaString($strDBUID);
$strDBPWD = &decryptTeaString($strDBPWD);

$strSearchDate= &UnixDate("yesterday", "%Y-%m-%d");
$strCurrentDate = localtime();

$strMessageSubject = "$strCurrentDate $strMessageSubject";

my ($dbh);
$dbh = DBI->connect("DBI:mysql:$strDBDatabase;host=$strDBHost", "$strDBUID", "$strDBPWD", { RaiseError => 1 });

if (! defined($dbh) ){
	print "Error connecting to DSN $strDBHost $strDBDatabase:\n\t" . $DBI::errstr  . "\n";
	&sendAlert("Error connecting to $strDBHost $strDBDatabase - " . $DBI::errstr);
}
else{
	$session = Infoblox::Session->new ("master"=> $strInfobloxMaster, "username" => $strIBUID, "password" => $strIBPWD);

	if ($session->status_code()) {
		&sendAlert("Construct session failed: ", $session->status_code() . ":" . $session->status_detail());
	}
	else{
		# new
		$sqlquery = "select dns_name, ip, date from $strDBTable where date >= '$strSearchDate' AND dns_name LIKE '%' AND ip LIKE '%' AND active = 'yes'";
		# initial run
		#$sqlquery = "select dns_name, ip, date from $strDBTable where dns_name LIKE '%' AND ip LIKE '%' AND active = 'yes'";
		print "New:\tSearching for $sqlquery\n";
		$sth = $dbh->prepare($sqlquery);
		$sth->execute;

		while (my $sqlRecord = $sth->fetchrow_hashref()) {
			my $strDNSName= $sqlRecord->{"dns_name"};
			$strDNSName = lc($strDNSName);
			my $strIP = $sqlRecord->{"ip"};
			my $strDate = $sqlRecord->{"updatedate"};
			print HISTORY "$strCurrentDate\tADD\t$strDNSName\t$strIP";
			&dnsAddFunction($strDNSName, $strIP);
			print HISTORY "\n";
			print "\n\n";
		}
		$sth->finish;

		# changes
		$sqlquery = "select dns_name, ip, updatedate from $strDBTable where updatedate >= '$strSearchDate' AND dns_name LIKE '%' AND ip LIKE '%' AND active = 'yes'";
		print "Updates:\tSearching for $sqlquery\n";
		$sth = $dbh->prepare($sqlquery);
		$sth ->execute;
		while (my $sqlRecord = $sth->fetchrow_hashref()) {
			my $strDNSName= $sqlRecord->{"dns_name"};
			$strDNSName = lc($strDNSName);
			my $strIP = $sqlRecord->{"ip"};
			my $strDate = $sqlRecord->{"updatedate"};
			print HISTORY "$strCurrentDate\tUPDATE\t$strDNSName\t$strIP";
			&dnsUpdateFunction($strDNSName, $strIP);
			print HISTORY "\n";
			print "\n\n";
		}
		$sth->finish;


		# removals
		$sqlquery = "select dns_name, ip, updatedate from $strDBTable where updatedate >= '$strSearchDate' AND active = 'no'";
		print "Deletes:\tSearching for $sqlquery\n";
		$sth = $dbh->prepare($sqlquery);
		$sth ->execute;
		while (my $sqlRecord = $sth->fetchrow_hashref()) {
			my $strDNSName= $sqlRecord->{"dns_name"};
			$strDNSName = lc($strDNSName);
			my $strIP = $sqlRecord->{"ip"};
			my $strDate = $sqlRecord->{"updatedate"};
			print HISTORY "$strCurrentDate\tREMOVE\t$strDNSName\t$strIP";
			&dnsDeleteFunction($strDNSName, $strIP);
			print HISTORY "\n";
			print "\n\n";
		}
		$sth->finish;
	}
	$dbh->disconnect();
}
close HISTORY;
exit(0);

################################################################################
## This function adds a DNS A record via the Infoblox API
## Input: 	$strName -- hostname
##		$strIP -- assignment IP address
## Output:	VOID
################################################################################
sub dnsAddFunction{
	my $strName = $_[0];
	my $strIP = $_[1];

	if( length($strName) < 3 || length($strIP) < 7){
		&sendAlert("$strName or $strIP bad data.");
	}
	else{

		my $strFQDNS = $strName . '.' . $strPrinterZone;

		print "ADD: $strFQDNS with IP $strIP:\n";

		#Verify if the zone exists
		my $object = $session->get(object => "Infoblox::DNS::Zone", name => $strPrinterZone, view=>"Paetec");
		if($object) {
			print "Zone exists on server, proceeding\n";

			#Get A record through the session
			my @retrieved_objs = $session->get(object => "Infoblox::DNS::Record::A", name => $strFQDNS, view => $strViewName);
			print scalar(@retrieved_objs) . " retrieved for $strFQDNS\n";
			if( scalar(@retrieved_objs) == 1){
				my $dnsPrinter = $retrieved_objs[0];
				my $ipv4addr = $dnsPrinter->ipv4addr();
				# should verify *just* one returned here
				if($strIP =~ /^$ipv4addr$/){
					print "Current record matches IP, no change needed\n";
					print HISTORY "\tCurrent record matches IP, no change needed";
				}
				else{
					print "Current record needs an update, but was a new record ... throwing error.\n";
					&sendAlert("$strFQDNS created in table with IP $strIP, but already exists in DNS with $ipv4addr. Update if update required.");
				}
			}
			elsif( scalar(@retrieved_objs) > 1){
				&sendAlert("Found " . scalar(@retrieved_objs) . " records for $strFQDNS. This will need to be addressed manually.");
			}
			else{
				## I have added this to search DNS view in array format as to create A record you have to have in that formate
				my @result = $session -> get
				(
				    object => "Infoblox::DNS::View",
				    name => $strViewName
				);
				#Construct a DNS A object
				my $bind_a = Infoblox::DNS::Record::A->new(name => $strFQDNS, ipv4addr => $strIP, views    => [$result[0]]  );
				unless ($bind_a) {
					&sendAlert("Construct DNS record A failed: ", Infoblox::status_code() . ":" . Infoblox::status_detail());
				}
				print "DNS A object created, ready to add\n";
				#Add the DNS A record object to Infoblox Appliance through a session
				$session->add($bind_a);
				print $session->status_code() . ": " . $session->status_detail() . "\n";
				if($session->add($bind_a) ){
					print "DNS A object added to server successfully\n";
				}
				else{
					&sendAlert("Add record A failed: ", $session->status_code() . ":" . $session->status_detail());
				}
			}
		}
		else{
			&sendAlert("I cannot find the zone $strPrinterZone ... someone needs to look at this.");
		}
	}
}

################################################################################
## This function updates an existing DNS A record via the Infoblox API
## Input: 	$strName -- hostname
##		$strIP -- assignment IP address
## Output:	VOID
################################################################################
sub dnsUpdateFunction{
	my $strName = $_[0];
	my $strIP = $_[1];

	if( length($strName) < 3 || length($strIP) < 7){
		&sendAlert("$strName or $strIP bad data.");
	}
	else{
		my $strFQDNS = $strName . '.' . $strPrinterZone;

		print "Update: $strFQDNS with IP $strIP:\n";	

		#Verify if the zone exists
		my $object = $session->get(object => "Infoblox::DNS::Zone", name => $strPrinterZone, view=>$strViewName);
		if($object) {
			print "Zone exists on server, proceeding\n";

			#Get A record through the session
			my @retrieved_objs = $session->get(object => "Infoblox::DNS::Record::A", name => $strFQDNS, view => $strViewName);
			print scalar(@retrieved_objs) . " retrieved for $strFQDNS\n";
			if( scalar(@retrieved_objs) == 1 || scalar(@retrieved_objs) == 0){
				if(scalar(@retrieved_objs) == 1){
					my $dnsPrinter = $retrieved_objs[0];
					if($dnsPrinter){
						if($strUpdate == $strUpdateFlag){
							my $ipv4addr = $dnsPrinter->ipv4addr();
							if($strIP =~ /^$ipv4addr$/){
								print "Current record matches IP, no change needed\n";
								print HISTORY "\tCurrent record matches IP, no change needed";
							}
							else{
								$dnsPrinter->ipv4addr($strIP);
								if($session->modify($dnsPrinter) ){			# If change applied successfully
									print "DNS A object modified successfully \n";
								}
								else{
									&sendAlert("Modify record A failed: ", $session->status_code() . ":" . $session->status_detail());
								}
							}
						}
					}
				}
				else{					# If I don't already have a record, create it
					&dnsAddFunction($strName, $strIP);
				}
			}
			else{
				&sendAlert("Found " . scalar(@retrieved_objs) . " records for $strFQDNS. This will need to be addressed manually.");
			}
		}
		else{
			&sendAlert("I cannot find the zone $strPrinterZone ... someone needs to look at this.");
		}
	}
}

################################################################################
## This function removes a DNS A record via the Infoblox API
## Input: 	$strName -- hostname
##		$strIP -- assignment IP address
## Output:	VOID
################################################################################
sub dnsDeleteFunction{
	my $strName = $_[0];
	my $strIP = $_[1];

	if( length($strName) < 3 || length($strIP) < 7){
		&sendAlert("$strName or $strIP bad data.");
	}
	else{
		my $strFQDNS = $strName . '.' . $strPrinterZone;

		print "Delete: $strFQDNS with IP $strIP:\n";

		#Verify if the zone exists
		my $object = $session->get(object => "Infoblox::DNS::Zone", name => $strPrinterZone, view=>$strViewName);
		if($object) {
			print "Zone exists on server, proceeding\n";

			#Get A record through the session
			my @retrieved_objs = $session->get(object => "Infoblox::DNS::Record::A", name => $strFQDNS, view => $strViewName);
			print scalar(@retrieved_objs) . " retrieved for $strFQDNS\n";
			if( scalar(@retrieved_objs) == 1){
				 my $object = $retrieved_objs[0];
				 unless ($object) {
				     &sendAlert("Get record A failed: ", $session->status_code() . ":" . $session->status_detail());
				     return;
				 }
				 my $ipv4addr = $object->ipv4addr();
				if($strIP =~ /^$ipv4addr$/){
					 #Submit the object for removal
					 if($session->remove($object)){
						print "Successfully removed $strFQDNS.\n";
					 }
					 else{
						&sendAlert("Remove record A failed: ", $session->status_code() . ":" . $session->status_detail());
					 }
				}
				else{
					&sendAlert("Cannot remove $strFQDNS. Database IP is $strIP, but DNS has $ipv4addr. This needs to be addressed manually.");
				}
			}
			elsif( scalar(@retrieved_objs) > 1){
				&sendAlert("Found " . scalar(@retrieved_objs) . " records for $strFQDNS. This will need to be addressed manually.");
			}
			else{
				print HISTORY "\tRecord not found, no need to remove.";
			}
		}
		else{
			&sendAlert("I cannot find the zone $strPrinterZone ... someone needs to look at this.");
		}
	}
}

################################################################################
## This function returns a clear text value from a Crypt::Tea encrypted string
## Input: 	$strInputText -- encrypted string
## Output:	string -- clear text of encrypted string
################################################################################
sub decryptTeaString{
        $strInputText= $_[0];
        $key = `cat $strCryptTeaSeed`;
        chomp($key);
        $strInputText = pack("H*",$strInputText);
        $strInputText= decrypt($strInputText,$key);
        return $strInputText;
}


################################################################################
## This function sends an SMTP message
## Input: 	$strError -- message body
## Output:	VOID
################################################################################
sub sendAlert{
	my $strError = $_[0];
	print HISTORY "\t$strError";
	print "\t$strError";
	return;
	$sender = new Mail::Sender {smtp => $strMailRelay};
	$sender->Open({ from => $strAlertSender,
				to => $strAlertRecipients,
				subject => $strMessageSubject,
				headers => "MIME-Version: 1.0\r\nContent-type: text/plain"});

	$sender->SendLineEnc($strError);
	$sender->Close();
}