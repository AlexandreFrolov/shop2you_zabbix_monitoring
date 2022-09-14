#!/usr/bin/perl
use strict;
use warnings;
use File::Slurp;
use Sys::Hostname;
use Data::Dumper;

my $lock_file = '/tmp/.rsync_lock';

sub analyze_log
{
  my ($log) = @_;
  my $action = {};
  my $errors = [];
  my $rc={};

  open( FILE, "<$log" );
  while (<FILE>)
  {
    if (m/recv_file_name/)
    {
      $action->{ recv_file_name }++;
    }
    elsif (m/recv_generator/)
    {
      $action->{ recv_generator }++;
    }
    elsif (m/recv_files/)
    {
      $action->{ recv_files }++;
    }
    elsif (m/is\suptodate/)
    {
      $action->{ is_uptodate }++;
    }
    elsif (m/\[generator\]\smake_file/)
    {
      $action->{ make_file }++;
    }
    elsif (m/delete_in_dir/)
    {
      $action->{ delete_in_dir }++;
    }
    elsif (m/Permission\sdenied/)
    {
      $action->{ permission_denied }++;
      push @$errors, $_;
    }
    elsif (m/is\snewer/)
    {
      $action->{ is_newer }++;
      push @$errors, $_;
    }
    elsif(m/opening\stcp\sconnection/
          || m/Connected\sto/
          || m/sending\sdaemon\sargs/
          || m/receiving\sfile\slist/
          || m/expand\sfile_list/
          || m/received\s\d+\snames/
          || m/done/
          || m/recv_file_list\sdone/
          || m/get_local_name\scount/
          || m/generator\sstarting\spid/
          || m/\[generator\]\spushing\slocal\sfilters\sfor/
          || m/\[generator\]\sprotecting\sfile/
          || m/\[generator\]\sprotecting\sdirectory/
          || m/\[generator\]\spopping\slocal\sfilters/
          || m/delta-transmission\senabled/
          || m/generate_files\sphase/
          || m/deleting\sin/
          || m/generate_files\sfinished/
          || m/sent\s\d+([\.,]\d+)*\sbytes/
          || m/total\ssize\sis/
          || m/_exit_cleanup/
          || m/set\smodtime\sof/
          || m/got\sfile_sum/
          || m/renaming/
          || m/delete_item/
          || m/deleting\s/
          || m/generating\sand\ssending\ssums/
          || m/count=/
          || m/recv\smapped/
          || m/parse_filter_file/
          || m/add_rule/

          # упоминания файлов и папок 
          || m/^[^(\s]+$/ # любые символы кроме скобок и пробелов (это имя папки или файла) 
          )
    {
      # nothing to do
    }
    # все остальное считаем ошибками
    else
    {
      $_ =~ s/^[\s\n\r\t]+//;
      $_ =~ s/[\s\n\r\t]+$//;
      if ($_)
      {
        $action->{ $_ }++;
        push @$errors, $_;
      }
    }
  }
  if ( scalar @$errors )
  {
    # use Data::Dumper;
    # print Dumper $errors;
    return { 'rc' => 'error', 'errors' => $errors };
  }
  return { 'rc' => 'ok', 'action' => $action };
}

sub _locked
{
  return 1 if ( -e $lock_file );
}
sub _lock
{
  open( FILE, ">$lock_file" );
  close FILE;
}
sub _unlock
{
  unlink($lock_file);
}

sub do_sync($$)
{
  my ($user, $master_server_ip) = @_;
  my $begin = time();

  my $log='/home/'.$user.'/data/rsync/rsync_log.txt';
  my $cmd = 'sudo -u '.$user.' /usr/bin/rsync -urltvvv --delete-after --password-file=/home/'
.$user.'/data/rsync.secrets '.$user.'@'.$master_server_ip.'::'.$user.' /home/'.$user.'/data --exclude-from /home/shopusr2/data/rsync/exclude_'.$user.'.txt --bwlimit=6000 > '.$log;

  print $cmd, "\n";

  my @rqout = ();
  @rqout = split /\n/, `$cmd`;
  my $status;
  my $rc;
  my $rsync_rc = $?;
  if($rsync_rc == 0)
  {
    $status = analyze_log($log);
    $rc="ok";
  }
  else
  {
    $rc=$rsync_rc;
  }

  my $end = time();
  my $diff = $end - $begin;
  return {'rc' => $rc, 'sync_status_from_log' => $status, 'sync_duration' => $diff, 'user' => $user,  'master_server_ip' => $master_server_ip};
}


# ========================================================================================
# START
# ========================================================================================

my $zabbix_sender_data_file = '';
my $debug = 0;
my $zabbix_sender;
my $zabbix_server_ip = $ARGV[0];
my $hostname = $ARGV[1];
if($ARGV[2] eq 'debug') { $debug = 1; } else { $debug = 0; }

if($^O eq 'linux')
{
  $zabbix_sender = '/usr/bin/zabbix_sender';
  $zabbix_sender_data_file = '/home/frolov/zabbix_rsynced_data.txt';
}
else
{
  print "\nUnsupported OS: $^O";
  exit(1);
}

if ($debug)
{
  print "Check Rsync status -- Zabbix trapper, v.0.1.3 (C) Alexandre Frolov, 2022, shop2you.ru\n";
  print "zabbix_sender path: ".$zabbix_sender."\n".'OS: '.$^O."\n";
  print "Zabbix server IP: ".$zabbix_server_ip.', Hostname: '.$hostname."\n";
}

# ==============================================================================
#  Get Keepalived Node Status
# ==============================================================================


# Node state file
my $node_keepalive_state_file = '/home/shopusr/node_keepalive_state.txt';
my $state_file_content = read_file($node_keepalive_state_file);
my $host = hostname; # host01master.domain.ru - MASTER, host01slave.domain.ru - BACKUP

if($host eq 'host01slave.domain.ru' and $state_file_content=~/INSTANCE_myshop_BACKUP/)
{
  if( $debug) { print "do replication \n"; }

  unless ( _locked() )
  {
    _lock();

    # Укажите адрес IP мастер-сервера
    # my $master_server_ip='xxx.xxx.xxx.xxx';
    my $sync_info;

    $sync_info = do_sync('shopusr2', $master_server_ip);
    if( $debug) { print Dumper($sync_info); }

    my $shopusr2_error_rc = 0;
    if($sync_info-> { rc } ne 'ok')
    {
      $shopusr2_error_rc = 1;
    }
    my $shopusr2_warning_rc = $sync_info->{sync_status_from_log }->{ rc };
    if($shopusr2_warning_rc eq 'error')
    {
      $shopusr2_warning_rc = 1;
    }
    else
    {
      $shopusr2_warning_rc = 0;
    }
    my $shopusr2_sync_duration = $sync_info-> { sync_duration };

    # ==============================================================================
    # All data was collected
    # ==============================================================================

    if ($debug) {
      print "shopusr2 sync error: ".$shopusr2_error_rc."\n";
      print "shopusr2 sync warning: ".$shopusr2_warning_rc."\n";
      print "shopusr2 sync duration: ".$shopusr2_sync_duration."\n";
    }

    # ==============================================================================
    # Prepare Zabbix Sender file
    # ==============================================================================

    open(my $fh, '>', $zabbix_sender_data_file) or die "Не могу открыть '$zabbix_sender_data_file' $!";
    print $fh $hostname." shopusr2_sync.Error ".$shopusr2_error_rc."\n";
    print $fh $hostname." shopusr2_sync.Warning ".$shopusr2_warning_rc."\n";
    print $fh $hostname." shopusr2_sync.SyncDuration ".$shopusr2_sync_duration."\n";
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
    _unlock();
  }
  else
  {
    print 'locked',"\n";
  }
}
else
{
  print 'Can run files replication only for BACKUP state and for host host01slave.domain.ru'."\n";
  print 'Host: '.$host.', state: '.$state_file_content."\n";
}











