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

**Position 1.** Opens in the trend direction at `0.04 × balance / $100` lots. There is no stop loss.

**Position 2.** Opens when price has moved $3 in your favour beyond Position 1 and Position 1 is in profit. The size is `0.08 × balance / $100`.

**Profit stops.**
- The moment Position 2 opens, Position 1's stop goes to about $0.50 above its own entry, so it's locked in profit at once.
- As soon as price is $0.50 past Position 2's open, both stops move there: above it for a BUY, below it for a SELL. Position 1 then locks about $3.50 and Position 2 about $0.50.
- MT4 can't accept a profit stop on the newest position until price is past its entry. $0.50 past is the earliest point.

**Position 3.** Opens only after both earlier positions have a profit stop and price has moved another $3. The size is `0.10 × balance / $100`. The same pattern repeats: earlier positions are protected the moment it opens, then all stops move $0.50 past Position 3's open. After that, every further $3 move lifts all stops by $3. That's the same `StepDollars` setting, so adding and stepping stay in sync.

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
| Sizes 2 and 3 | grow with balance, same as Position 1 | scaling formula unconfirmed |
| Session | resets each broker day; +10% only blocks new entries | the 10% vs 25% behaviour is undefined |

These are all inputs, so you can change them without editing code.

### Not built yet

- **Newsday mode** (0.10 / 0.10 / 0.10, +50% target). Its rules are still undefined.
- **An exit when a trade goes against you or the trend fails** (open item 6 in the handoff).

## The risk you need to see before testing

The numbers below use the handoff's own example: gold at $4,000, 100 oz per lot, and a broker that closes positions when margin level falls to 50%. Check your broker's real values.

| Leverage | Margin for Position 1 | Margin for all three | Can the formula run? |
|---|---|---|---|
| 1:50 | 3.2 × balance | 17.6 × balance | **No.** Position 1 is rejected at any balance. |
| 1:500 | 0.32 × balance | 1.76 × balance | Positions 1 and 2 only. Position 3 is skipped. |
| 1:1000 | 0.16 × balance | 0.88 × balance | Yes, but margin level is very thin. |

The EA never shrinks the formula to make it fit. It skips the position and logs why.

**With no losing stop, Position 1 alone loses about 4% of the balance per $1 gold moves against it.** At 1:500 or 1:1000, the broker's stop-out comes after roughly a **$21–23 move against you**, which wipes most of the account. Gold can move that much in a single day.

That's why the alternative exists. The backtest should show which version survives.

## Step 1: Backtest both versions

1. Copy `mt4/XAUUSD_TrendScaler.mq4` into MT4's `MQL4/Experts` folder (File → Open Data Folder) and compile it in MetaEditor.
2. Strategy Tester: XAUUSD, model **Every tick**, **at least 2 years**, the same dates for both runs.
   - **Run A (owner's method):** default inputs.
   - **Run B (risk-limited):** `SizingMode = RISK_PERCENT`, `SafetyStopDollars = 10`, `RiskPercentPerStack = 1`, `DailyLossLimitPercent = 3`.
3. Set the tester's deposit and leverage to what you'd really use. At 1:50, Run A will skip every trade (see the table above).
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
