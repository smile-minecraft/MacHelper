#!/bin/bash
# Model-test entry point. The implementation lives in run-isolated-tests.sh, which builds a
# throwaway package with no remote dependencies and still checks that no preference file was
# created under the real home.
#
# Usage: Tests/UI/run-model-tests.sh
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/run-isolated-tests.sh" --model-only
