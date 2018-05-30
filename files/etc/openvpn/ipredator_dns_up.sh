#!/bin/bash
cp /etc/resolv.conf /tmp/resolv.conf
echo "nameserver 46.246.46.46" > /etc/resolv.conf
echo "nameserver 194.132.32.23" >> /etc/resolv.conf
