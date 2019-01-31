#!/usr/bin/env bash

flutter clean
git clean -xdf

cd ..
7z a -t7z -mx=9 -ms=200m -mf -mhc -mhcf -mmt -r -stl web_image.7z web_image/
cd -
