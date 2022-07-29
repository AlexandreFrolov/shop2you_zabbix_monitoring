#!/usr/bin/perl
######################################################################
# Не запускайте эту программу, она требует модификации для вашей CRM
exit();
######################################################################

use strict;
use Date::Parse;
use Net::Whois::Parser;
use Zabbix::Tiny;
use File::Slurp;
use YAML::XS 'LoadFile';
use Encode qw(decode);
use utf8;
use URI::UTF8::Punycode;
use Net::DNS;
use Data::Dumper;

my $debug = 0;
my $zabbix_sender;
my $bin_openssl = '';
my $ssl_check_host = 'ssl_check_host';
my $z;


# ==============================================================================
# w1251_to_utf8
# ==============================================================================
sub w1251_to_utf8($)
{
  my $str = shift @_;
  Encode::from_to($str, 'windows-1251', 'utf-8');
  $str = decode('utf8',$str);
  return($str);
}


# ==============================================================================
# zabbix_open
# ==============================================================================
sub zabbix_open($)
{
  my $z = shift @_;
  my $zabbix = Zabbix::Tiny->new(
     server   => $z->{ zabbix_server_url },
     password => $z->{ zabbix_server_password },
     user     => $z->{ zabbix_server_login },
     ip     => $z->{ zabbix_server_ip },
 );
  return $zabbix;
}

# ==============================================================================
# get_domains_for_ssl_check
# ==============================================================================
sub get_domains_for_ssl_check($$)
{
  my $z = shift @_;
  my $ssl_check_host = shift @_; 

  my $params = {
    output => ['key_','name'],
    filter => { host => $ssl_check_host }
  };
  my $result = $z->do(
   'item.get',  
   $params
  );


  my @domains=[];
  my $item_count = 0;
  foreach my $item (@$result)
  {
    my ($key_head, $port) = split(/_/, $item->{ 'key_' });
    my $domain = $item->{ 'name' };
    $domains[$item_count] =
    {
      domain => $domain,
      port => $port,
      key => $item->{ 'key_' }
    };
    $item_count++;
  }
  return \@domains;
}

# ==============================================================================
# get_group_id
# ==============================================================================
sub get_group_id($$)
{
  my $z = shift @_;
  my $group_name = shift @_;
  my $params = {
    output => [qw(groupid name)],
    filter => { name => [$group_name]  }
  };
  my $result = $z->do(
   'hostgroup.get', 
   $params
  );
  return $result->[0]->{ groupid };
}

# ==============================================================================
# get_group_hosts
# ==============================================================================
sub get_group_hosts($$)
{
  my $z = shift @_;
  my $group_name = shift @_;

  my $gid = get_group_id($z, $group_name);
  my $params = {
    output => [qw(hostid name host)],
    groupids => [$gid],
  };
  my $result = $z->do(
   'host.get',
   $params
  );
  return $result;
}

# ==============================================================================
# get_template_id
# ==============================================================================
sub get_template_id($$)
{
  my $z = shift @_;
  my $template_name = shift @_;
  my $params = {
    output => [qw(templateid name)],
    filter => { name => [$template_name]  }
  };
  my $result = $z->do(
   'template.get',
   $params
  );
  return $result->[0]->{ templateid };
}

# ==============================================================================
# create_host
#
# my $host_name='frolov-lib2.ru';
# my $hsts = create_host($z, $host_name, $domains_group_name, $domains_template_name);
# print Dumper($hsts);
# ==============================================================================
sub create_host($$$$$)
{
  my $z = shift @_;
  my $host_name = shift @_;
  my $name = shift @_;
  my $group_name = shift @_;
  my $template_name = shift @_;

  my $gid = get_group_id($z, $group_name);
  my $template_id = get_template_id($z, $template_name);

  my $params = {
    host => $host_name,
    name => $name,
    interfaces => [{type => 1, main => 1, useip => 1, ip => '127.0.0.1', dns => "", port => '443'}],
    groups => [{ groupid => $gid }],
    templates => [{ templateid => $template_id }],
  };
  my $result = $z->do(
   'host.create',
   $params
  );
  return $result;
}

# ==============================================================================
# get_host_id
#
# my $hid = get_host_id($z, 'frolov-lib2.ru');
# my $rc = delete_host($z, $hid);
# ==============================================================================
sub get_host_id($$)
{
  my $z = shift @_;
  my $host_name = shift @_;
  my $params = {
    output => [qw(hostid name)],
    filter => { name => [$host_name]  }
  };
  my $result = $z->do(
   'host.get',
   $params
  );
  return $result->[0]->{ hostid };
}

# ==============================================================================
# delete_host
# ==============================================================================
sub delete_host($$)
{
  my $z = shift @_;
  my $hostid = shift @_;
  my $params = [ $hostid ];
  my $result = $z->do(
   'host.delete',
   $params
  );
  return $result;
}

# ==============================================================================
# get_all_monitored_domains
#
# my $all_monitored_domains = get_all_monitored_domains($z, $domains_group_name);
# print Dumper($all_monitored_domains);
# ==============================================================================
sub get_all_monitored_domains($$)
{
  my $z = shift @_;
  my $group_name = shift @_;
  return get_group_hosts($z, $group_name);
}


# ==============================================================================
# get_domain_punycode
# ==============================================================================
sub get_domain_punycode
{
#  my $this        = shift @_;
  my $domain_name = shift @_;
  my $punycode    = '';
  if ( $domain_name =~ m/[ÀÁÂÃÄÅ¨ÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäå¸æçèéêëìíîïðñòóôõö÷øùúûüýþÿ]/ )
  {
    my @parts = split( '\.', $domain_name );
    foreach my $part (@parts)
    {
      if ( $part =~ m/[ÀÁÂÃÄÅ¨ÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäå¸æçèéêëìíîïðñòóôõö÷øùúûüýþÿ]/ )
      {
        $punycode .= '.'.puny_enc($part);
      }
      else
      {
        $punycode .= '.'.$part;
      }
    }
    $punycode =~ s/^\.//;
  }
  else
  {
    $punycode = '';
  }
  return $punycode;
}


# ==============================================================================
# get_domain_info_from_dns
# ==============================================================================
sub get_domain_info_from_dns($)
{
  my $domain = shift @_;
#  my $res   = Net::DNS::Resolver->new(debug => 1);
  my $res   = Net::DNS::Resolver->new;

  my $dinfo = {};
  my @mx = mx($res, $domain);
  if(@mx != 0)
  {
    $dinfo->{ mx_found } = 1;
    $dinfo->{ mx } = \@mx; 
  }
  else
  {
    $dinfo->{ mx_found } = 0;
    $dinfo->{ mx_error } = $res->errorstring;
  }

  my $addr=();
  my $rr = {};
  my $query = {};
  $dinfo->{ a_found } = 0;

  $query = $res->search($domain);
  if ($query)
  {
    foreach $rr ($query->answer)
    {
       next unless ($rr->type eq "A");
       push @$addr, $rr->address;
       $dinfo->{ a_found } = 1;
    }
  }
  $dinfo->{ address } = $addr;
  return($dinfo);
}

# ==============================================================================
# get_domain_info
# ==============================================================================
sub get_domain_info($$)
{
  my $domain_name = shift @_;
  my $ssl_port = shift @_;

  my $domain_info={};

  $domain_info->{ domain_name } = $domain_name;


  my $cmd = 'openssl s_client -servername '.$domain_name.' -connect '.$domain_name.':'.$ssl_port.' </dev/null 2>/dev/null';
  my @rqout = ();
  @rqout = split /\n/, `$cmd`;
  if(scalar(@rqout) == 0)
  {
    $domain_info->{ domain_has_ssl }=0;
  }
  else
  {
    $domain_info->{ domain_has_ssl }=1;

    my $cmd_subj='echo | openssl s_client -servername '.$domain_name.' -connect '.$domain_name.':'.$ssl_port.' 2>/dev/null | openssl x509 -noout -subject';
    my @subjout = ();
    @subjout = split /\n/, `$cmd_subj`;
    if(scalar(@subjout) != 0)
    {
      my $cn=@subjout[0];
      if($cn=~/$domain_name/)
      {
        $domain_info->{ domain_ssl_matches }=1;
      }
      else
      {
        $domain_info->{ domain_ssl_matches }=0;
      }
    }

    $cmd = 'echo | openssl s_client -servername '.$domain_name.' -connect '.$domain_name.':'.$ssl_port." 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d'=' -f2";
    my @rqout2 = ();
    @rqout2 = split /\n/, `$cmd`;

    my $expires_data = str2time(@rqout2[0]);
    my $current_data = time();
    my $days_before_expire = int(($expires_data - $current_data) / 86400);
    if($days_before_expire <= 0) { $days_before_expire = 0;}
    $domain_info->{ days_before_ssl_expire }=$days_before_expire;
  }

  my $info = parse_whois( domain => $domain_name );

  my $domain_expiration_date='';
  $domain_info->{ whois_ok } = 1;
  if($info->{ paid_till })
  {
    $domain_expiration_date = $info->{ paid_till };
  }
  elsif ( $info->{ expiration_date })
  {
    $domain_expiration_date = $info->{ expiration_date };
  }
  elsif ( $info->{ registry_expiry_date })
  {
    $domain_expiration_date = $info->{ registry_expiry_date };
  }
  elsif ( $info->{ 'Registry Expiry Date' })
  {
    $domain_expiration_date = $info->{ 'Registry Expiry Date' };
  }
  else
  {
    $domain_info->{ whois_ok } = 0;
  }

  my $expires_data = str2time($domain_expiration_date);
  my $current_data = time();
  my $days_before_expire = int(($expires_data - $current_data) / 86400);
  $domain_info->{ days_before_domain_expire } = $days_before_expire;

  if($days_before_expire < 0)
  {
    $domain_info->{ whois_ok } = 0;
  }

  my $dns_info=get_domain_info_from_dns($domain_name);

  if($dns_info->{ a_found })
  {
    my $a_str="";
    my $a_counter=0;
    my $dns_a_ref = $dns_info->{ address };
    foreach my $dns_a (@$dns_a_ref)
    {
      if($a_counter > 0)
      {
        $a_str = $a_str.', '.$dns_a;
      }
      else
      {
        $a_str = $a_str.$dns_a;
      }
      $a_counter++;
    }
    $domain_info->{ a_found } = 1;
    $domain_info->{ a } = $a_str;
  }
  else
  {
    $domain_info->{ a_found } = 0;
  }

  if($dns_info->{ mx_found })
  {
    my $mx_str="";
    my $mx_counter=0;
    my $mx_ref = $dns_info->{ mx };
    foreach my $record (@$mx_ref)
    {
      my $pr = $record->preference;
      my $ex = $record->exchange;
      if($mx_counter > 0)
      {
        $mx_str = $mx_str.', '.$pr.' '.$ex;
      }
      else
      {
        $mx_str = $mx_str.$pr.' '.$ex;
      }
      $mx_counter++;
    }
    $domain_info->{ mx_found } = 1;
    $domain_info->{ mx } = $mx_str;
  }
  else
  {
    $domain_info->{ mx_found } = 0;
  };

  return $domain_info;
}


# ==============================================================================
# get_opened_domains_from_billing
# ==============================================================================
sub get_opened_domains_from_billing()
{
  my $all_sites = {};
  # Запишите в $all_sites информацию о доменах, которые нужно контролировать 
  # Цикл по доменам 
  # {
    # $domain_pcode = get_domain_punycode($domain_name_from_billing);
    # if($domain_pcode ne '')
    # {
    #     $domain_name=$domain_pcode;
    # }
    # else
    # {
    #    $domain_name=$domain_name_from_billing;
    # }

    # $domain_info=get_domain_info($domain_name, 443);
    # if($domain_pcode ne '')
    # {
    #   $domain_info->{ punycode } = $domain_pcode;
    #   $domain_info->{ punycode_used } = 1;
    #   $domain_info->{ domain_name_from_billing } = $domain_name_from_billing;
    # }
    # else
    # {
    #   $domain_info->{ punycode_used } = 0;
    # }
  # }    
  return($all_sites);
}


# ==============================================================================
# create_monitored_hosts
# ==============================================================================
sub create_monitored_hosts($$$$)
{
  my $z = shift @_;
  my $domains_group_name = shift @_;
  my $domains_template_name = shift @_;
  my $hosts = shift @_;

  my $domains_group_id = get_group_id($z, $domains_group_name);

  foreach my $key (keys %$hosts)
  {
    my $host_name;
    my $name;
    if($key)
    {
      $host_name = $hosts->{$key}->{domain_name};
      my $pcode_used = $hosts->{$key}->{punycode_used};

      if($pcode_used)
      {
        $name = $hosts->{$key}->{domain_name_from_billing};
      }
      else
      {
        $name = $hosts->{$key}->{domain_name};
      }
      Encode::_utf8_on($name);
      my $hsts = create_host($z, $host_name, $name, $domains_group_name, $domains_template_name);
    }
  }
}

# ==============================================================================
# find_in_monitored_domains
# ==============================================================================
sub find_in_monitored_domains($$)
{
  my $domain=shift @_; 
  my $all_monitored_domains=shift @_; 

  my $found=0;
  my $zbx_hostid=0;

  foreach my $arg (@$all_monitored_domains)
  {
    my $cdomain = $arg->{host};
    $zbx_hostid = $arg->{hostid};
    if($cdomain eq $domain)
    {
      $found=1;
      last;
    }
    else
    {
      $found=0;
      $zbx_hostid=0;
    }
  }
  return($found, $zbx_hostid);
}

# ==============================================================================
# create_missing_domain_in_zabbix
# ==============================================================================
sub create_missing_domain_in_zabbix($$$$$)
{
  my $z=shift @_;
  my $domains_group_name=shift @_;
  my $domains_template_name=shift @_;
  my $domains_from_billing=shift @_; 
  my $domains_from_zabbix=shift @_; 

  foreach my $key (keys %$domains_from_billing)
  {
    my $host_name;
    my $name;
    if($key)
    {
      $host_name = $domains_from_billing->{$key}->{domain_name};
      my $pcode_used = $domains_from_billing->{$key}->{punycode_used};

      if($pcode_used)
      {
        $name = $domains_from_billing->{$key}->{domain_name_from_billing};
      }
      else
      {
        $name = $domains_from_billing->{$key}->{domain_name};
      }

      my ($found, $zbx_hostid) = find_in_monitored_domains($host_name, $domains_from_zabbix);
      if($found == 0)
      {
        print("$name to be CREATED \n");

        Encode::_utf8_on($name);
        my $hsts = create_host($z, $host_name, $name, $domains_group_name, $domains_template_name);
        print Dumper($hsts);
      }
    }
  }
}


# ==============================================================================
# delete_closed_domains_from_zabbix
# ==============================================================================
sub delete_closed_domains_from_zabbix($$$$$)
{
  my $z=shift @_;
  my $domains_group_name=shift @_;
  my $domains_template_name=shift @_;
  my $domains_from_billing=shift @_; 
  my $domains_from_zabbix=shift @_; 

  foreach my $arg (@$domains_from_zabbix)
  {
    my $cdomain = $arg->{host};
    my $zbx_hostid = $arg->{hostid};

    my $found_in_billing=find_domain_in_billing($cdomain, $domains_from_billing);
    if($found_in_billing == 0)
    {
      print("$cdomain NOT found in Billing, to be REMOVED. zbx_hostid = $zbx_hostid \n");
      my $rc = delete_host($z, $zbx_hostid);
    }
  }
}

# ==============================================================================
# send_value_to_zabbix
# ==============================================================================
sub send_value_to_zabbix($$$$$)
{
  my $zabbix_sender=shift @_;
  my $zabbix_server_ip=shift @_;
  my $host_name=shift @_;
  my $zkey=shift @_;
  my $zvalue=shift @_;

  my $trap_cmd = $zabbix_sender.' -z '.$zabbix_server_ip.' -s '.$host_name.' -k '.$zkey.' -o "'.$zvalue.'"';
  my @trapout = (); @trapout = split /\n/, `$trap_cmd`;
  if ($debug)
  {
    print Dumper(\@trapout);
    print $host_name.' '.$zkey.' '.$zvalue."\n";
  }
}


# ==============================================================================
#  BEGIN
# ==============================================================================

if($ARGV[0] && $ARGV[0] eq 'debug') { $debug = 1; } else { $debug = 0; }

if($^O eq 'linux')
{
  $zabbix_sender = '/usr/bin/zabbix_sender';
}
else
{
  print "\nUnsupported OS: $^O";
  exit(1);
}
if ($debug)
{
  print 'Check Domain and SSL -- Zabbix trapper, v.2.1. (C) Alexandre Frolov, 2020, alexandre@frolov.pp.ru, shop2you.ru'."\n";
  print "zabbix_sender path: ".$zabbix_sender."\n".'OS: '.$^O."\n";
}

my $zbx = LoadFile('/home/frolov/zabbix_domain_monitoring/config/zabbix-server.yaml');
my $zabbix_server_ip = $zbx->{ zabbix_server_ip };
my $z = zabbix_open($zbx);
if ($debug) {
  print Dumper($zbx);
}

my $all_sites;
$all_sites = get_opened_domains_from_billing($dbh);

my $domains_group_name = 'Shop2YOU Domains';
my $domains_template_name = 'Shop2YOU Domains Monitor';

if($debug) { print('Get all monitored hosts...', "\n"); }
my $all_monitored_domains = get_all_monitored_domains($z, $domains_group_name);

if($debug) { print('Create missing hosts in Zabbix...', "\n"); }
create_missing_domain_in_zabbix($z, $domains_group_name, $domains_template_name, $all_sites, $all_monitored_domains);
delete_closed_domains_from_zabbix($z, $domains_group_name, $domains_template_name, $all_sites, $all_monitored_domains);

# ==============================================================================
# All data was collected
# ==============================================================================

foreach my $key (keys %$all_sites)
{
  my $zkey;
  my $zvalue;
  my $trap_cmd;
  if($key)
  {
    my $host_name = $all_sites->{$key}->{domain_name};

    if($debug)
    {
      print Dumper($all_sites->{$key});
    }

    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'days_before_domain_expire', $all_sites->{$key}->{ 'days_before_domain_expire' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'days_before_ssl_expire', $all_sites->{$key}->{ 'days_before_ssl_expire' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'domain_ssl_matches', $all_sites->{$key}->{ 'domain_ssl_matches' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'domain_has_ssl', $all_sites->{$key}->{ 'domain_has_ssl' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'whois_ok', $all_sites->{$key}->{ 'whois_ok' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'a_found', $all_sites->{$key}->{ 'a_found' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'dns_a', $all_sites->{$key}->{ 'a' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'mx_found', $all_sites->{$key}->{ 'mx_found' });
    send_value_to_zabbix($zabbix_sender, $zabbix_server_ip, $host_name, 'dns_mx', $all_sites->{$key}->{ 'mx' });
  }
}
