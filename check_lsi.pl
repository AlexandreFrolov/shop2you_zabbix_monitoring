#!/usr/bin/perl
use strict;
use Data::Dumper;

my $zabbix_sender_data_file = '';
my $debug = 0;
my $bin_megacli;
my $zabbix_sender;

my $zabbix_server_ip = $ARGV[0];
my $hostname = $ARGV[1];

if($ARGV[2] eq 'debug') { $debug = 1; } else { $debug = 0; }

if($^O eq 'linux')
{
  $zabbix_sender = '/usr/bin/zabbix_sender';
  $zabbix_sender_data_file = '/home/frolov/zabbix_lsi/zabbix_data.txt';
  $bin_megacli = '/usr/sbin/megacli';
}
elsif($^O eq 'freebsd')
{
  $zabbix_sender = '/usr/local/bin/zabbix_sender';
  $zabbix_sender_data_file = '/home/frolov/zabbix_lsi/zabbix_data.txt';
  $bin_megacli = '/usr/local/sbin/MegaCli';
}
else
{
  print "\nUnsupported OS: $^O";
  exit(1);
}

if ($debug)
{
  print 'Check LSI -- Zabbix trapper, v.2.1. (C) Alexandre Frolov, 2022, alexandre@frolov.pp.ru, shop2you.ru'."\nUse: 'perl check_lsi.pl [zabbix_server_ip] [server_name] debug' \n";
  print "megacli path: ".$bin_megacli."\nzabbix_sender path: ".$zabbix_sender."\n".'OS: '.$^O."\n";
  print "Zabbix server IP: ".$zabbix_server_ip.', Hostname: '.$hostname."\n";
}

# ==============================================================================
#  Get RAID State
# ==============================================================================

my $cmd;
$cmd = "$bin_megacli -LDInfo -LALL -aALL";
if ($debug) { print Dumper($cmd); }


my @rqout = ();
@rqout = split /\n/, `$cmd`;
if ($debug) { print Dumper(\@rqout); }


my $isOptimal = 0;
my $WriteBack = 0;

foreach my $line (@rqout)
{
  next if ($line eq "" or !defined $line);
  if ($debug) { print $line."\n"; }

  if($line=~/State/ && $line=~/Optimal/)  { $isOptimal = 1; }
  if($line=~/Current Cache Policy/ && $line=~/WriteBack/)  { $WriteBack = 1; }
}

# ==============================================================================
#  Get Drive Info
# ==============================================================================

$cmd = "$bin_megacli -PDList -aALL";

my $MediaErrorCount = 0;
my $OtherErrorCount = 0;
my $PredictiveFailureCount = 0;
my $OnlineDriveCount = 0;
my $HotspareDriveCount = 0;
my $DeviceId = 0;

my $raid_drive_has_errors = 0;
my $HasPredictiveFailureCount = 0;



my $retry_count = 2;
do
{
  @rqout = ();
  @rqout = split /\n/, `$cmd`;

  my $responce_array_size = $#rqout;
  if ($responce_array_size < 3) # PDList cmd failed
  {
    $retry_count -= 1;
    if ($debug) { print Dumper(\@rqout); }
    sleep(10);
  }
  else
  {
     $retry_count = 0;
  }
} while ($retry_count > 0);


my $str;
my %drive_with_errors;

foreach my $line (@rqout)
{
  if ($debug) { print $line."\n"; }

  if($line=~/Device Id/)
  {
    ($str, $DeviceId) = split(/:/, $line);
    $MediaErrorCount = 0;
    $OtherErrorCount = 0;
    $PredictiveFailureCount = 0;
  }

  if($line=~/Media Error Count/)  { ($str, $MediaErrorCount) = split(/:/, $line); }
  if($line=~/Other Error Count/)  { ($str, $OtherErrorCount) = split(/:/, $line); }
  if($line=~/Predictive Failure Count/)  { ($str, $PredictiveFailureCount) = split(/:/, $line); }

  if($MediaErrorCount != 0 || $OtherErrorCount != 0 || $PredictiveFailureCount != 0)
  {
    $drive_with_errors{$DeviceId} = { MediaErrorCount => $MediaErrorCount, OtherErrorCount => $OtherErrorCount, PredictiveFailureCount => $PredictiveFailureCount };
    $raid_drive_has_errors = 1;
  }

  if($PredictiveFailureCount != 0)
  {
     $HasPredictiveFailureCount = 1;
  }

  if($line=~/Firmware state/ && $line=~/Online/)  { $OnlineDriveCount += 1; }
  if($line=~/Firmware state/ && $line=~/Hotspare/)  { $HotspareDriveCount += 1; }
}

# ==============================================================================
#  Get BBU State
# ==============================================================================

$cmd = "$bin_megacli -AdpBbuCmd -aAll";
@rqout = ();
@rqout = split /\n/, `$cmd`;

my $BatteryReplacementRequired = 'No';
my $RemainingCapacityLow = 'No';
my $CycleCount=0;

foreach my $line (@rqout)
{
  if ($debug) { print $line."\n"; }
  if($line=~/Battery Replacement required/)  { ($str, $BatteryReplacementRequired) = split(/:/, $line); }
  if($line=~/Remaining Capacity Low/)  { ($str, $RemainingCapacityLow) = split(/:/, $line); }
  if($line=~/Cycle Count/)  { ($str, $CycleCount) = split(/:/, $line); }
}

# ==============================================================================
# All data was collected
# ==============================================================================

if ($debug) {
  print "\nOnlineDriveCount: ".$OnlineDriveCount."\n";
  print "HotspareDriveCount: ".$HotspareDriveCount."\n";
  print "BatteryReplacementRequired: ".$BatteryReplacementRequired."\n";
  print "RemainingCapacityLow: ".$RemainingCapacityLow."\n";
  print "CycleCount: ".$CycleCount."\n";

  if($isOptimal == 1) { print "State is Optimal\n"; }
  if($WriteBack == 1) { print "Mode is WriteBack -- OK\n"; }

  if ($debug)
  {
    if($raid_drive_has_errors != 0)
    {
      print Dumper(\%drive_with_errors);
    }
  }
}

# ==============================================================================
# Prepare Zabbix Sender file
# ==============================================================================

open(my $fh, '>', $zabbix_sender_data_file) or die "Не могу открыть '$zabbix_sender_data_file' $!";
print $fh $hostname." lsi.isOptimal ".$isOptimal."\n";
print $fh $hostname." lsi.WriteBack ".$WriteBack."\n";
print $fh $hostname." lsi.OnlineDriveCount ".$OnlineDriveCount."\n";
print $fh $hostname." lsi.HotspareDriveCount ".$HotspareDriveCount."\n";
print $fh $hostname." lsi.BatteryReplacementRequired ".$BatteryReplacementRequired."\n";
print $fh $hostname." lsi.RemainingCapacityLow ".$RemainingCapacityLow."\n";
print $fh $hostname." lsi.RaidDriveHasErrors ".$raid_drive_has_errors."\n";
print $fh $hostname." lsi.PredictiveFailureCount ".$HasPredictiveFailureCount."\n";
print $fh $hostname." lsi.CycleCount ".$CycleCount."\n";

close $fh;


my @zabbix_server_ip_array = split(',', $zabbix_server_ip);
foreach my $server_ip (@zabbix_server_ip_array)
{
  my $trap_cmd = $zabbix_sender.' -vv -z '.$server_ip.' -i '.$zabbix_sender_data_file;
  if ($debug) {
    print "Trap cmd: ".$trap_cmd."\n";
  };

  my @trapout = ();
  @trapout = split /\n/, `$trap_cmd`;

  if ($debug) { print Dumper(\@trapout); }
}
