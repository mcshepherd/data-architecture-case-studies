#!/usr/bin/env bash
# Design and build the stand-in ERP from a seed (default 7). About a minute.
# The committed manifest matches seed 7.
source "$(dirname "$0")/lib.sh"
seed="${1:-7}"
sql erp -d erp_sim -Q "EXEC dbo.usp_design @seed = $seed; EXEC dbo.usp_build;"
echo "built stand-in ERP from seed $seed"
