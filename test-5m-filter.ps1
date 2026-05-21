# 5m 信号过滤测试（纯 mock，不调 API）
. "$PSScriptRoot\pump-5m.ps1"

function MockCandles-ShortWeak {
    # 3根都小阳、高点抬高 -> 无做空确认
    @(
        [PSCustomObject]@{ instId='X'; candleTs=3000; open=100; high=101; low=99.5; close=100.8; volume=1 }
        [PSCustomObject]@{ instId='X'; candleTs=2000; open=99; high=100.5; low=98.5; close=100.2; volume=1 }
        [PSCustomObject]@{ instId='X'; candleTs=1000; open=98; high=99.5; low=97.5; close=99.5; volume=1 }
    )
}

function MockCandles-ShortConfirm {
    @(
        [PSCustomObject]@{ instId='X'; candleTs=3000; open=100; high=100.5; low=97; close=98; volume=1 }
        [PSCustomObject]@{ instId='X'; candleTs=2000; open=101; high=101.2; low=99; close=99.5; volume=1 }
        [PSCustomObject]@{ instId='X'; candleTs=1000; open=102; high=102.5; low=100; close=100.5; volume=1 }
    )
}

$minScore = 14
$base = 16

$weak = Build-5mContext -Candles (MockCandles-ShortWeak) -Side short -BaseScore $base -MinScore $minScore
if (-not $weak.Block) { throw '普通空(无5m确认)应被过滤' }
Write-Host "OK 无5m确认拒空: $($weak.FilterReason)" -ForegroundColor Green

$ok = Build-5mContext -Candles (MockCandles-ShortConfirm) -Side short -BaseScore $base -MinScore $minScore
$plan = [PSCustomObject]@{ Side='short'; Score=$base; Reason='test' }
$plan2 = Apply-5mToPlan -Plan $plan -Ctx $ok
if (-not $plan2) { throw '有5m确认应通过' }
Write-Host "OK 有5m确认通过: Score=$($plan2.Score) 结构=$($plan2.M5Structure)" -ForegroundColor Green
