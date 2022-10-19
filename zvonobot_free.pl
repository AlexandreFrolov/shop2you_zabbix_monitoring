#!/usr/bin/perl
use strict;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use autouse 'Data::Dumper' => qw(Dumper);

#
# Set $api_key, $phone_number and $outgoingPhone before use this script
# See API Key in profile https://lk.zvonobot.ru/panel/profile
#

# =============================================================
# not_recently_called
# Wait for $delay seconds before next phone call
# =============================================================
sub not_recently_called
{
  my ($delay) = @_;
  use Cache::Memcached;
  my $calling_permition=0;

  my $memd = new Cache::Memcached
  {
    'servers' => ["127.0.0.1:11211"], 'debug' => 0, 'compress_threshold' => 10000,
  };

  my $call_state = $memd->get("Zabbix_phone_monitor");

  # Wait for $delay seconds before next phone call
  if($call_state ne "") 
  {
    $call_state = $memd->get("Zabbix_phone_monitor");
    $calling_permition=0;
  }
  else
  {
    $memd->set("Zabbix_phone_monitor", "Phone was called", $delay);
    $calling_permition=1;
  }
  return $calling_permition;
}

# =============================================================
# send_mail_messages
# =============================================================
sub send_mail_messages
{
  my ($email_to, $email_from, $email_from_name, $email_subject, $message) = @_;
  use ITMATRIX::Email;
  my $email = 'ITMATRIX::Email'->new();
  $email->set_email_params( to         => $email_to,
                            from_name  => $email_from_name,
                            from_email => $email_from,
                            subject    => $email_subject,
                            body       => $message,
                            );
  $email->set_content_type('text');
  $email->set_local_send();
  use ITMATRIX::Mailer;
  'ITMATRIX::Mailer'->new()->send($email);
}

# =================================================================
# phone_call_zvonobot
# =================================================================
sub phone_call_zvonobot
{
  my ($api_url, $api_key, $phone_number, $outgoingPhone, $message) = @_;

  my $ua  = LWP::UserAgent->new();
  my $json = JSON->new->allow_nonref;

  my $json_request = '{"apiKey": "'.$api_key.'", "phone": "'.$phone_number.'", "outgoingPhone": "'.$outgoingPhone.'", "record": { "text": "'.$message.'", "gender": 0 }}';
  my $req = HTTP::Request->new(POST => $api_url);
  $req->content_type('application/json');
  $req->content($json_request);
  my $ua = LWP::UserAgent->new;
  my $response = $ua->request($req);

  if ($response->is_success)
  {
    print "OK \n";
#    print Dumper( $response);
  }
  else
  {
    my $rc = $response->status_line;
    my $json_text   = $json->decode( $response->decoded_content );
    my $err_msg = $json_text->{ data }->{ message };
    print $err_msg;
  }
}

# =============================================================
# START
# =============================================================

open(my $fh, '>>', '/var/log/zabbix/zbx_disaster.log');

my $datestring = localtime();
my $problem  = $ARGV[1];
my $hostname = $ARGV[2];
my $message  = $hostname.". ".$problem;

if($problem =~ /Resolved/)
{
 print $fh $datestring." RESOLVED: ".$problem."\n";
}
else
{
  print $fh $datestring." PROBLEM: $message"."\n";

  my $api_url = 'https://lk.zvonobot.ru/apiCalls/create';
  my $api_key = '*******************';
  my $phone_number  = '************';
  my $outgoingPhone = '************';
  my $email_to = ['admin@my-domain.ru'];
  my $email_from = 'admin@my-domain.ru';
  my $email_from_name = 'Zabbix';
  my $email_subject = 'Zabbix DISASTER ERROR: '.$problem;

  if(not_recently_called(20*60))
  {
    send_mail_messages($email_to, $email_from, $email_from_name, $email_subject, $message);
    phone_call_zvonobot($api_url, $api_key, $phone_number, $outgoingPhone, $message);
  }
}
close $fh;

