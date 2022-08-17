#!/usr/bin/perl

use strict;
use Data::Dumper;

my $debug = 0;
my $bin_redis_cli;
my $zabbix_sender;
my $zabbix_server_ip = $ARGV[0];
my $hostname = $ARGV[1];
my $zabbix_sender_data_file = '';

if($ARGV[2] eq 'debug') { $debug = 1; } else { $debug = 0; }

my  $cmd;
if($^O eq 'linux')
{
  $zabbix_sender = '/usr/bin/zabbix_sender';
  $zabbix_sender_data_file = '/home/frolov/zabbix_redis/zabbix_data.txt';
  $bin_redis_cli = '/usr/bin/redis-cli';
  $cmd = $bin_redis_cli.' info';
}
else
{
  print "\nUnsupported OS: $^O";
}

if ($debug)
{
  print 'Check Redis -- Zabbix trapper. (C) Alexandre Frolov, 2022, alexandre@frolov.pp.ru, shop2you.ru'."\n";
  print "zabbix_sender path: ".$zabbix_sender."\n".'OS: '.$^O."\n";
  print "Zabbix server IP: ".$zabbix_server_ip.', Hostname: '.$hostname."\n";
}

my @rqout = ();
@rqout = split /\n/, `$cmd`;
open(my $fh, '>', $zabbix_sender_data_file) or die "Не могу открыть '$zabbix_sender_data_file' $!";
foreach my $line (@rqout)
{
   next if (substr($line, 0, 1) eq "#");
   next unless ($line =~ /:/);

   my @dat = split(':', $line);
   if ($debug) {   print $dat[0]. ':'. $dat[1]."\n"; }

  my $key = $dat[0];
  my $value = $dat[1];
  print $fh $hostname.' '.$key.' '.$value."\n";
}
close $fh;

# ==============================================================================
# All data was collected
# Zabbix Sender file is ready for send
# ==============================================================================

my $trap_cmd = $zabbix_sender.' -vv -z '.$zabbix_server_ip.' -i '.$zabbix_sender_data_file;
if ($debug) {
  print "Trap cmd: ".$trap_cmd."\n";
};
my @trapout = ();
@trapout = split /\n/, `$trap_cmd`;
if ($debug) { print Dumper(\@trapout); }
