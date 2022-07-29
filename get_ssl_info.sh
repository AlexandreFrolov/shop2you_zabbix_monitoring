#!/bin/sh
SERVER=$1
PORT=$2;
EXPIRE_DATE=`echo | openssl s_client -servername $SERVER -connect $SERVER:$PORT 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d'=' -f2`