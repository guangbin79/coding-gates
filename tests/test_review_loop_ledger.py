# 欠债账本三断言冒烟的 pytest 入口（gt-f23e94 裁决产物随迁，ag-9901d0）——
# 本体 review-loop/e2e/review-loop-trigger.test.ts（bun 自建临时 git 仓，不触真实配置）
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def test_debt_ledger_three_assertions():
    r = subprocess.run(
        ["bun", "review-loop/e2e/review-loop-trigger.test.ts"],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    assert "ledger smoke: PASS" in r.stdout
