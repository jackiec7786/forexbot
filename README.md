# forexbot

An MT4 Expert Advisor for **P's XAU/USD three-position method**. The method belongs to its owner. The default settings follow the owner's rules exactly. A risk-limited alternative is built in as a switch, so both can be compared on the same data.

**Nothing here is proven to make money.** Backtest first, then demo, before any real money.

## What's here

| Path | What it is |
|---|---|
| `mt4/XAUUSD_TrendScaler.mq4` | The EA. Everything the method needs runs inside MT4. |
| `server/`, `tradingview/`, `deploy/` | **Parked.** An earlier TradingView signal server with a news filter. The current EA doesn't use it. |

## The method, as coded

**Trend.** The EA checks closed 5-minute bars:
- price above its level 30 minutes ago **and** above its level 2 hours ago: BUY
- below both: SELL
- anything else (sideways or mixed): WAIT

**Position 1.** Opens in the trend direction at **0.04 lots** (always the smallest). There is no stop loss yet.

**Stop, then Position 2.** When price has moved $3 in your favour and Position 1 is in profit:
1. Position 1's stop goes to $0.50 past its entry, locking a small profit.
2. **Only once that stop is accepted** does Position 2 open, at **0.08 lots**.

**Stops, then Position 3.** As soon as price is $0.50 past Position 2's open, both stops move there: above it for a BUY, below it for a SELL. Once both are protected and price has moved another $3, Position 3 opens at **0.10 lots**.

**All three in.** All stops move $0.50 past Position 3's open, then every further $3 move lifts all stops by $3. That's the same `StepDollars` setting, so adding and stepping stay in sync. MT4 can't accept a profit stop on the newest position until price is past its entry, so $0.50 past is the earliest point.

**Trend turns against you.** If the trend confirms the opposite direction (for a BUY, price below its level both 30 min and 2 h ago), the EA closes every position that doesn't yet have a profit stop. This can mean taking a loss. Positions already locked in profit keep their stops. Switch it off with `ExitOnTrendReversal = false`.

**A stop is hit while another position is unprotected.** For example, Position 1 closes at its profit stop while Position 2 has no profit stop yet. The move has failed, so the EA closes the leftover too, usually a small net loss. No position is ever left behind without a stop. Earlier stops also aren't pulled up when a new position opens, so a small dip doesn't knock out Position 1 early.

**Rules that never change:**
- stops only move in your favour and are always in profit
- never add to a losing position
- three positions at most

**Session (per broker day):**
- at +10% equity, no new Position 1 (open trades keep running)
- at +25%, close everything and stop for the day

### Test assumptions (agreed, not proven)

| Setting | Value | Owner's wording |
|---|---|---|
| `TrendShortMinutes` / `TrendLongMinutes` | 30 / 120 (also test 180) | "observe 15–30 min, review 30 min to 2 h", "the prior two to three hours" |
| `StepDollars` | $3 | "several dollars" |
| `BufferDollars` | $0.50 | "slightly above break-even of Position 2's open" |
| Sizes | fixed 0.04 / 0.08 / 0.10 lots | "my first position should always be my lowest amount, say 0.04" |
| Session | resets each broker day; +10% only blocks new entries | the 10% vs 25% behaviour is undefined |

These are all inputs, so you can change them without editing code.

### Not built yet

- **Newsday mode** (0.10 / 0.10 / 0.10, +50% target). Its rules are still undefined.

## The risk you need to see before testing

The numbers below assume gold at $4,000, 100 oz per lot, and a broker that closes positions when margin level falls to 50%. Check your broker's real values.

| Leverage | Margin for Position 1 (0.04) | Margin for all three (0.22) | Balance to hold all three at 200% margin level |
|---|---|---|---|
| 1:50 | $320 | $1,760 | about $3,500 |
| 1:100 | $160 | $880 | about $1,760 |
| 1:500 | $32 | $176 | about $350 |

If margin is short, the EA skips the position and logs why. It never shrinks the sizes to make them fit.

**Position 1 has no losing stop.** At 0.04 lots, every $1 gold moves against it costs $4. At 1:50, the broker's stop-out comes after roughly:
- a **$85 move** against you on a $500 account
- **$210** on $1,000
- **$1,210** on $5,000

Gold can move $50 or more in a day.

That's why the alternative exists. The backtest should show which version survives.

## Step 1: Backtest both versions

1. Copy `mt4/XAUUSD_TrendScaler.mq4` into MT4's `MQL4/Experts` folder (File → Open Data Folder) and compile it in MetaEditor.
2. Strategy Tester: XAUUSD, model **Every tick**, **at least 2 years**, the same dates for both runs.
   - **Run A (owner's method):** default inputs.
   - **Run B (risk-limited):** `SizingMode = RISK_PERCENT`, `SafetyStopDollars = 10`, `RiskPercentPerStack = 1`, `DailyLossLimitPercent = 3`.
3. Set the tester's deposit and leverage to what you'd really use (1:50 is P's tutorial setting; see the table above for the balance it needs).
4. Compare:
   - **Number of trades:** 100 or more before the result means anything.
   - **Profit factor:** below 1.2 means no real edge after costs.
   - **Max drawdown,** and whether the account ever hit a margin stop-out.
   - **Out-of-sample check:** tune on 2023–2024 only, then run 2025 unchanged.
5. If both fail, stop. Change the idea, not the code.

## If the bot isn't trading

The top-left corner of the chart shows a status panel with AutoTrading, trend, spread, today's result, and a **Status** line that says what the bot is waiting for. Common causes:

| Status / symptom | Fix |
|---|---|
| No panel at all | The EA isn't running. Check the Experts tab for a load or compile error, and that the EA is attached to an XAUUSD chart. |
| "Trading is OFF" | Turn on the **AutoTrading** button in the toolbar and tick **Allow live trading** in the EA's settings (Common tab). The face in the chart corner should smile. |
| "No price updates…" | The market is closed (gold stops Friday night to Sunday night, plus holidays) or MT4 is disconnected (check the bottom-right corner). |
| "No clear trend" | Normal. The bot only trades when 30 min and 2 h agree. |
| "Spread … above MaxSpreadDollars" | The broker's spread is wider than $0.60. Wait, or raise `MaxSpreadDollars` a little. |
| "not enough margin" | Leverage is too low for the formula (see the table above). |
| "rejected by the broker. Error N" | Look up the error number in the Experts tab and send it to us. |

## Step 2: Demo account for at least 1 month

Attach the EA to an XAUUSD chart on a **demo** account with the version that passed. Check that it trades the way the backtest did.

### Track it with Myfxbook

Myfxbook is only for tracking. It never affects trades.

1. Create a free account at myfxbook.com.
2. Go to **Portfolio → Add account → MetaTrader 4** and choose the **auto-update** option. You'll need your broker's server name, your account number and your **investor password**. Nothing gets installed in MT4.
3. Keep the account **private** until the results are worth showing.

Rules:
- **Only use the investor (read-only) password.** Never give any website your main trading password. Your broker can show or reset the investor password.
- **Give the bot its own account.** Manual trades or other bots on the same account get mixed into the stats.

After a month, compare against the backtest:

| Metric | What to look for |
|---|---|
| Max drawdown | Close to the backtest. Much worse means the backtest was too optimistic. |
| Profit factor and number of trades | Roughly in line with the backtest. |
| Biggest loss | Run A: how close it came to a stop-out. Run B: capped near the $10 safety stop. |

## Parked: signal server

`server/` holds a FastAPI server. It takes TradingView alerts, ignores signals older than 15 minutes and blocks trading 30 minutes around high-impact USD news. It's tested (`cd server && pytest`) but **not connected to the current EA**: the method reads the trend in MT4 itself. `deploy/` has its systemd and Caddy files. The news filter could come back later as an optional check if a backtest shows it helps.
