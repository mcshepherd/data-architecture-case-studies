#!/usr/bin/env bash
# Start both instances and install every setup script: the ERP login and generator,
# the linked server, the sync machinery, and the manifest. Then run build-erp.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env ]]; then
    gen() { echo "Aa1_$(openssl rand -hex 12)"; }
    sed -e "s/^SA_PASSWORD=.*/SA_PASSWORD=$(gen)/" -e "s/^READER_PASSWORD=.*/READER_PASSWORD=$(gen)/" .env.example > .env
    echo "generated .env"
fi
source scripts/lib.sh
docker compose up -d --wait
for f in sql/erp/[0-9]*.sql; do sql erp -i "/$f" >/dev/null; done
for f in sql/warehouse/[0-9]*.sql; do sql warehouse -i "/$f" >/dev/null; done
echo "up: erp on 127.0.0.1:14331, warehouse on 127.0.0.1:14332"
