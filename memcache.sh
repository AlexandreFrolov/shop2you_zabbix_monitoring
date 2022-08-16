#!/bin/bash
echo -e "stats\nquit" | nc 127.0.0.1 11211 | grep "STAT $1 " | awk '{print $3}' 