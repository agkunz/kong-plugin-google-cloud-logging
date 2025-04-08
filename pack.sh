#!/bin/sh
#
sudo luarocks make
luarocks pack kong-plugin-google-cloud-logging 0.1.1
