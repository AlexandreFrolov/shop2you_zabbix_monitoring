#!/usr/bin/perl
use strict;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use autouse 'Data::Dumper' => qw(Dumper);

#
# Set $api_key and $phone_number before use this script
# See API Key on page https://admin.p1sms.ru/panel/apiinfo
#

# =================================================================
# send_p1sms
# =================================================================
sub sendp1sms
{
  my ($message) = @_;

  my $api_url = 'https://admin.p1sms.ru/apiSms/create';
  my $api_key = '**********************';
  my $phone_number = '*********';

  my $ua  = LWP::UserAgent->new();
  my $json = JSON->new->allow_nonref;

  my $json_request = '{"apiKey": "'.$api_key.'","phone": "'.$phone_number.'","sms": [{ "phone": "'.$phone_number.'","sender": "VIRTA","channel": "char","text": "'.$message.'"}]}';
  my $req = HTTP::Request->new(POST => $api_url);
  $req->content_type('application/json');
  $req->content($json_request);
  my $ua = LWP::UserAgent->new;
  my $response = $ua->request($req);

  if ($response->is_success)
  {
    return("OK", $json_request);
  }
  else
  {
    my $rc = $response->status_line;
    my $json_text   = $json->decode( $response->decoded_content );
    my $err_msg = $json_text->{ data }->{ message };
    return($err_msg, $json_request);
  }
}

# =============================================================
# START
# =============================================================

open(my $fh, '>>', '/var/log/zabbix/zbx_p1sms.ru.log');
my $datestring = localtime();
my $problem  = $ARGV[1];
my $hostname = $ARGV[2];
my $message  = $hostname;
if($problem =~ /Resolved/)
{
 print $fh $datestring." RESOLVED: ".$problem."\n";
}
else
{
  my ($rc,$json_request)=sendp1sms($message);
  print $fh $datestring." PROBLEM: $message rc: ".$rc."\n";
}
close $fh;
