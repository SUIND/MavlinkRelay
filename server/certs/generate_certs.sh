#!/bin/bash
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 365 -noenc -keyout key.pem -out cert.pem \
  -subj "/CN=mavlink-relay"
echo "Certificates generated: cert.pem, key.pem"
