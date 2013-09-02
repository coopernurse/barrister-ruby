#!/bin/sh

set -e

git pull
make
rsync -avz docs/ james@barrister.bitmechanic.com:/home/james/barrister-site/api/ruby/latest/
