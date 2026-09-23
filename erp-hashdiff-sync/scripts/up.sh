#!/usr/bin/env bash
# Start both instances and configure the ERP login and the linked server.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env ]]; then
    gen() { echo "Aa1_$(openssl rand -hex 12)"; }
    sed -e "s/^SA_PASSWORD=.*/SA_PASSWORD=$(gen)/" -e "s/^READER_PASSWORD=.*/READER_PASSWORD=$(gen)/" .env.example > .env
    echo "generated .env"
fi
source scripts/lib.sh
docker compose up -d --wait
sql erp -i /sql/erp/00_setup.sql
sql warehouse -i /sql/warehouse/00_linked_server.sql
echo "up: erp on 127.0.0.1:14331, warehouse on 127.0.0.1:14332"
