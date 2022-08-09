#!/usr/bin/perl

use strict;
use Data::Dumper;

my $debug = 0;
my $bin_repquota;
my $zabbix_sender;
my $zabbix_server_ip = $ARGV[0];
my $hostname = $ARGV[1];
my $zabbix_item_key = 'quota.key';

if($ARGV[2] eq 'debug') { $debug = 1; } else { $debug = 0; }

if ($debug)
{
  print 'Check quota -- Zabbix trapper. (C) Alexandre Frolov, 2022, alexandre@frolov.pp.ru, shop2you.ru'."\nUse: 'perl check_quota.pl [IP-address] [hostname] debug' \n";
  print "repquota path:".$bin_repquota."\nzabbix_sender path: ".$zabbix_sender."\n".'OS: '.$^O."\n";
  print "Zabbix server IP: ".$zabbix_server_ip.', Hostname: '.$hostname."\n";
}

my  $cmd;

if($^O eq 'linux')
{
  $zabbix_sender = '/usr/bin/zabbix_sender';
  $bin_repquota = '/usr/sbin/repquota';
  $cmd = "$bin_repquota -c -v -p -g /";
}
elsif($^O eq 'freebsd')
{
  $zabbix_sender = '/usr/local/bin/zabbix_sender';
  $bin_repquota = '/usr/sbin/repquota';
  $cmd = "$bin_repquota -v -g /";
}
else
{
  print "\nUnsupported OS: $^O";
}

my @rqout = ();
@rqout = split /\n/, `$cmd`;
if ($debug) { print Dumper(\@rqout); }

my $max_quota_use=0;

foreach my $line (@rqout)
{
   my @dat = split /\s+/, $line;
   next if (($#dat < 9) or ($dat[4] !~ /^\d+/));

   my ($quotaname, $quota_status, $quota_inuse, $quota_softlimit, $quota_hardlimit,$quota_grace) = ( $dat[0], $dat[1], $dat[2], $dat[3], $dat[4], $dat[5] );
   if ($quotaname =~ /#/)
   {
     $quotaname =~ s/#//g;
     $quotaname = "${quotaname}";
   }
   my $quotaname_perfdata = $quotaname; $quotaname_perfdata =~ s/^uid /uid/g;

   my $percent;
   if ($quota_hardlimit != 0)
   {
      $percent = int(($quota_inuse * 100) / $quota_hardlimit);
   }
   else
   {
     $percent=0;
   }
   if($percent != 0)
   {
     if($max_quota_use < $percent) { $max_quota_use = $percent; }
     if ($debug) { print $percent.'% '.$quotaname.",".$quota_status.",". $quota_inuse.",".$quota_softlimit.",".$quota_hardlimit.",".$quota_grace."\n"; }
   }
}

my @zabbix_server_ip_array = split(',', $zabbix_server_ip);
foreach my $server_ip (@zabbix_server_ip_array)
{
  my $trap_cmd = $zabbix_sender.' -vv -z '.$server_ip.' -s "'.$hostname.'" -k '.$zabbix_item_key.' -o '.$max_quota_use;
  if ($debug) {
    print "Max quota use: $max_quota_use".'%'."\n";
    print "Trap cmd: ".$trap_cmd."\n";
  };

  my @trapout = ();
  @trapout = split /\n/, `$trap_cmd`;
  if ($debug) { print Dumper(\@trapout); }
}

