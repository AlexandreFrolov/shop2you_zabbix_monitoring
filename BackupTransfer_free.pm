package ITMATRIX::BackupTransfer;

=pod

=encoding utf8

=head1 NAME

ITMATRIX::BackupTransfer - Копирование готовых бекапов на удаленные сервера

=head1 SYNOPSIS

  my $object = ITMATRIX::BackupTransfer->new(
    config => $path
  );
  $object->transfer();

=head1 DESCRIPTION

Утилита для копирования существующих бекапов на удаленные сервера. Все параметры задаются в файле конфигурации в формате YAML. Работа с удаленным сервером происходит по ftp.

=head1 METHODS

=cut

use 5.008009;
use strict;
use warnings;
use Config::YAML;
use Net::FTP;
use Memoize;
memoize('_connect');
use Date::Calc qw(Today Add_Delta_Days Week_of_Year Monday_of_Week Add_Delta_YM);
use autouse 'Data::Dumper' => qw(Dumper);
our $VERSION = '0.04';

=pod

=head2 new

  my $object = ITMATRIX::BackupTransfer->new(
    config => $path [ , test => 1, ftp_debug => 1 ]
  );

Режим работы test - отключает все действия при работе по ftp (удаление бекапов, перекачку и тп)
Режим работы ftp_debug - включает режим debug для работы по ftp

=cut

sub new
{
  my $class = shift;
  my $self = bless { @_ }, $class;
  if ( !$self->{ config } ) { die 'I need config file path' }
  $self->_load_config();
  @{ $self->{ today } } = Today;

  $self->{ log }   = [];
  $self->{ error } = [];
  return $self;
}

sub _log
{
  my $this = shift;
  push @{ $this->{ log } }, shift;
  return;
}

sub export_log
{
  my $this = shift;
  my $log = join( "<br>", @{ $this->{ log } } );
  return $log;
}

sub _error
{
  my $this = shift;
  push @{ $this->{ error } }, shift;
  return;
}

sub export_errors
{
  my $this = shift;
  my $log = join( "<br>", @{ $this->{ error } } );
  return $log;
}

sub _load_config
{
  my $this = shift;

  $this->{ _settings } = 'Config::YAML'->new( config => $this->{ config } );
  $this->check_config();
  return;
}

=pod

=head2 check_config

Функция проверки конфигурационного файла

	$object->check_config();

=cut

sub check_config
{
  my $this = shift;
  return 1;
}

sub get_config
{
  my $this = shift;
  return $this->{ _settings };
}

sub get_today
{
  my $this = shift;
  return $this->{ today };
}

=pod

=head2 transfer

Запуск процедуры перекачки бекапов

  $object->transfer();

=cut

sub transfer
{
  my $this = shift;

  $this->remove_backups();
  $this->transfer_backups();
  $this->_check_transfered_backups();
  $this->_check_existed_backups_for_users();
  
  return 1;
}

sub _connect
{
  my $this = shift;

  my $ip       = $this->get_config->{ ftp }->{ ip };
  my $login    = $this->get_config->{ ftp }->{ login };
  my $password = $this->get_config->{ ftp }->{ password };

  my $debug = $this->{ ftp_debug } ? 1 : 0;
  my $ftp = 'Net::FTP'->new( $ip, Debug => $debug ) or die "Cannot connect to $ip: $@";
  $ftp->login( $login, $password ) or die "Cannot login ", $ftp->message;
  $ftp->binary();
  return $ftp;
}

=pod

=head2 remove_backups

Процедура удаления бекапов на удаленном сервере

  $object->remove_backups();

=cut

sub remove_backups
{
  my $this    = shift;
  my $days    = $this->get_days_for_backups_to_store();
  my $connect = $this->_connect;
  $connect->cwd('backup');

	my $prefix = $this->get_config->{ local_host_name }."rmt_";

  my @nodes = $connect->ls();
  for my $node (@nodes)
  {
    if ($node =~ m/$prefix/ && $node =~ m/(\d{4}_\d{2}_\d{2})/)
    {
			if ($1)
			{
				my $node_date = $1;
				if ( !exists $days->{ $node_date } )
				{
					if ( !$this->{ test } )
					{
						$connect->rmdir( $node, 'recursive' );
					}
					$this->_log("<b>Remove</b> $node");
				}
			}
		}
  }

  return 1;
}

=pod

=head2 transfer_backups

Перекачка бекапов на удаленный сервер

  $object->transfer_backups

=cut

sub transfer_backups
{
  my $this = shift;

  my $remote_working_dir = $this->get_remote_working_dir();

  if ( !$this->{ test } )
  {
    $this->_connect->mkdir($remote_working_dir);
  }
  $this->_log("Created $remote_working_dir");

  my $system_dir = "root";
  my $path_to    = $remote_working_dir;

  my $local_backup_path = $this->get_config->{ local_backup_dir };
  opendir( my $local_backup_dir, $local_backup_path );
  while ( defined( my $user_name = readdir($local_backup_dir) ) )
  {
    my $_path = $local_backup_path."/".$user_name;
    if ( -d $_path && $this->_is_copied_dir($user_name) )
    {
      my $last_file = $this->_search_user_last_file($_path);
      my $path_from = $_path."/".$last_file;

      $this->_transfer_file( $path_from, $path_to, $user_name );
      $this->_save_size_of_copied_file( $path_from, $user_name, $last_file );
      my $sys_last_files = $this->_search_system_file( $local_backup_path."/".$system_dir, $user_name );
      foreach my $file ( @{ $sys_last_files } )
      {
        my $path_from = $local_backup_path."/".$system_dir."/".$file;
        $this->_transfer_file( $path_from, $path_to, $user_name );
        $this->_save_size_of_copied_file( $path_from, $user_name, $file );
      }
    }
  }
  return;

}

sub _is_copied_dir
{
  my $this = shift;
  my $dir  = shift;

  if ( $dir =~ m/^\./ )
  {
    return 0;
  }
  my $need_copy = 1;

  for my $no_dir ( @{ $this->get_config->{ no_copy_backup_dir } }, qw(root) )
  {
    if ( $dir eq $no_dir )
    {
      $need_copy = 0;
      last;
    }
  }

  return $need_copy ? 1 : 0;
}

=pod

=head2 get_days_for_backups_to_store

Просчет дат, за которые нужно сохранить бекапы. Возвращает массив дат в формате YYYY-mm-dd.

  my $days = $object->get_days_for_backups_to_store

=cut

sub get_days_for_backups_to_store
{
  my $this = shift;

  my $config = $this->get_config();
  # настройки сроков, за которые нужно хранить бекапы
  my $s_day   = $config->{ copies }->{ day };
  my $s_week  = $config->{ copies }->{ week };
  my $s_month = $config->{ copies }->{ month };

  # текущая дата
  my $t_year  = $this->get_today->[0];
  my $t_month = $this->get_today->[1];
  my $t_day   = $this->get_today->[2];

  my $days = [];
  # ежедневная копия считается от сегодняшнего дня
  for my $_day ( 0 .. $s_day - 1 )
  {
    my ( $year, $month, $day ) = Add_Delta_Days( $t_year, $t_month, $t_day, -$_day );
    push @$days, [$year, $month, $day];
  }

  # если задано хранение за недели
  if ($s_week)
  {
    # недельная копия делается в понедельник
    # текущая неделя
    my ( $current_week, $current_year ) = Week_of_Year( $t_year, $t_month, $t_day );
    my ( $w_year, $w_month, $w_day ) = Monday_of_Week( $current_week, $t_year );

    # начинается отсчет от текущей недели
    for my $week ( 0 .. $s_week-1 )
    {
      my ( $year, $month, $day ) = Add_Delta_Days( $w_year, $w_month, $w_day, -$week * 7 );
      push @$days, [$year, $month, $day];
    }
  }

  # месячная копия делается 1-го числа каждого месяца
  if ($s_month)
  {
    for my $month ( 0 .. $s_month - 1 )
    {
      my ( $year, $month, $day ) = Add_Delta_YM( $t_year, $t_month, $t_day, 0, -$month );
      push @$days, [$year, $month, 1];
    }
  }

  my $datas = {};
  for my $day_array (@$days)
  {
    my ( $year, $month, $day ) = @$day_array;
    $month = sprintf( "%02s", $month );
    $day   = sprintf( "%02s", $day );
    $datas->{ $year."_".$month."_".$day } = 1;
  }
  return $datas;
}

sub _search_user_last_file
{
  my $this = shift;
  my $dir  = shift;

  opendir( UDIR, $dir ) || die "cant open $dir";
  my $last_file = '';
  while ( defined( my $file = readdir(UDIR) ) )
  {
    next if $file =~ m/^\..*/;
    $last_file = $file if ( $last_file eq '' );
    my $path_last = $dir.'/'.$last_file;
    my $path_f    = $dir.'/'.$file;
    $last_file = $file if ( -M $path_f < -M $path_last );
  }
  return $last_file;
}

sub _transfer_file
{
  my $this      = shift;
  my $path_from = shift;
  my $path_to   = shift @_;
  my $user_name = shift @_;

  $this->_log("<br>User <b>$user_name</b>");
  if ( !$this->{ test } )
  {
    $this->_connect->cwd($path_to);
    $this->_connect->mkdir($user_name);
  }
  $this->_log( "Created ".$path_to."/".$user_name );
  if ( !$this->{ test } )
  {
    $this->_connect->cwd($user_name);
    $this->_connect->put($path_from);
  }
  $this->_log("Transfered $path_from");

  return 1;
}

sub _save_size_of_copied_file
{
  my $this      = shift;
  my $full_path = shift @_;
  my $user_name = shift @_;
  my $file_name = shift @_;

  my $size = ( stat($full_path) )[7];
  $this->{ copied_files_local }->{ $user_name }->{ $file_name } = $size;
  return;
}

sub _search_system_file
{
  my $this      = shift;
  my $dir       = shift @_;
  my $user_name = shift @_;
  opendir( RDIR, $dir ) || die "cant open $dir";
  my $full_found_last = '';
  my $sys_found_last  = '';
  while ( defined( my $file = readdir(RDIR) ) )
  {

    if ( $file =~ m/.*Full\s?$user_name.*/i )
    {
      $full_found_last = $file if ( $full_found_last eq '' );
      my $path_last = $dir.'/'.$full_found_last;
      my $path_f    = $dir.'/'.$file;
      $full_found_last = $file if ( -M $path_f < -M $path_last );
    }
    elsif ( $file =~ m/_$user_name-/ )
    {
      $sys_found_last = $file if ( $sys_found_last eq '' );
      my $path_last = $dir.'/'.$sys_found_last;
      my $path_f    = $dir.'/'.$file;
      $sys_found_last = $file if ( -M $path_f < -M $path_last );
    }
  }
  closedir RDIR;

  my $sys = [];
  push( @$sys, $full_found_last ) if $full_found_last ne '';
  push( @$sys, $sys_found_last )  if $sys_found_last  ne '';
  return $sys;
}

sub _check_transfered_backups
{
  my $this = shift;

  my $ftp                = $this->_connect();
  my $remote_working_dir = $this->get_remote_working_dir();

  for my $user ( keys %{ $this->{ copied_files_local } } )
  {
    for my $file ( keys %{ $this->{ copied_files_local }->{ $user } } )
    {
      my $size = $ftp->size( $remote_working_dir."/".$user."/".$file ) || 0;
      my $local_size = $this->{ copied_files_local }->{ $user }->{ $file };
      if ( $size != $local_size )
      {
        $this->_error("ERROR for $user/$file: local size $local_size, remote size $size");
      }
    }
  }
}

sub _check_existed_backups_for_users
{
  my $this = shift;

  my $user_dir         = "/usr/home/";
  my $local_backup_dir = $this->get_config->{ local_backup_dir };
  opendir( DIR, $user_dir );
  while ( defined( my $user = readdir(DIR) ) )
  {
    if ( -d "$user_dir$user" && $user !~ m/^\./ && !$this->_in_nochecking_list($user) )
    {
      my $check_dir = $local_backup_dir."/".$user;

      if ( !( -d $check_dir ) )
      {
        $this->_error("USER $user: cant find backup DIR");
      }
      else
      {
        my $last_file = $this->_search_user_last_file($check_dir);
        if ( $last_file eq '' )
        {
          $this->_error("USER $user: cant find backup files");
        }
      }
    }
  }
  return;
}

sub _in_nochecking_list
{
  my $this      = shift;
  my $user_name = shift;

  my $in_list = 0;

  for my $no_check_user ( @{ $this->get_config->{ no_check_user } }, qw(httpd-logs httpd-cert nginx-logs) )
  {
    if ( $no_check_user eq $user_name )
    {
      $in_list = 1;
      last;
    }
  }
  return $in_list ? 1 : 0;
}

sub get_remote_working_dir
{
  my $this = shift;

  my $t_year  = $this->get_today->[0];
  my $t_month = $this->get_today->[1];
  $t_month = sprintf( "%02s", $t_month );

  my $t_day = $this->get_today->[2];
  $t_day = sprintf( "%02s", $t_day );

  my $backup_dir = $this->get_config->{ local_host_name }."rmt_".$t_year."_".$t_month."_".$t_day;
  return '/backup/'.$backup_dir;
}
1;

=pod

=head1 CHANGES

=head2 Version 0.04

Savenkova Natalya, изменен алгоритм расчета недельных копий. Теперь недельная копия считается и для текущей недели тоже.
Изменен алгоритм удаления устаревших бекапов, чтобы не удалялись другие бекапы, не имеющие отношения к этому.

=head2 Version 0.03

Savenkova Natalya, bugs fixed

=head1 AUTHOR

Copyright 2013 Savenkova Natalya.

=cut
