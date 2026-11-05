# XAU/USD Three-Position Method: Version 1.1

**Date:** November 5, 2026
**Baseline:** *XAU/USD Three-Position Method Handoff*, Version 1.0 (October 18, 2026)
**Applies to:** the EA running on the VPS (the Nov 4 build with the leftover rule). The repo's newest build adds the optional slower exit and safety-stop changes, which are not installed.
**Status:** Under demo test. **Not** proven profitable, **not** approved for live trading.

This document lists every rule the EA uses and where each one came from, as the v1.0 handoff requires (section 15.1: "explicitly version any changes and identify whether each rule comes from the creator, the user, a test hypothesis, or standard risk practice").

## Source labels

| Label | Meaning |
|---|---|
| **P** | Creator's own words (v1.0 handoff, P's tutorial text, P's messages of Oct 18 and Nov 4) |
| **USER** | Decided by the user (account owner), who may approve changes under v1.0 Gate F |
| **TEST** | A number chosen to stand in for an undefined P phrase. It's an input and can change |
| **SAFETY** | Standard engineering or risk practice, not part of the trading method itself |

---

## 1. Rules register

### Instrument and setup

| # | Rule | Source | EA input |
|---|---|---|---|
| 1.1 | XAU/USD only. The EA refuses to start on any other symbol | P / SAFETY | none |
| 1.2 | MT4 executes; the EA runs on a Windows VPS | P | none |
| 1.3 | Test leverage **1:50** | P (v1.0 §1) | broker account |
| 1.4 | Trend read from MT4 prices only (line graph = closing prices). TradingView, cTrader and Myfxbook aren't needed: "MT4 will have all that we need" | P (Nov 4) | none |

### Trend: BUY / SELL / WAIT

| # | Rule | Source | EA input |
|---|---|---|---|
| 2.1 | Follow the trend in either direction; never predict a reversal | P | none |
| 2.2 | **BUY** when the last closed 5-minute price is above its level **30 min and 2 h** ago. **SELL** when it's below both. Otherwise **WAIT** | TEST, for P's "watch 30 min to 2 h", "prior two to three hours" | `TrendShortMinutes = 30`, `TrendLongMinutes = 120` |
| 2.3 | At most one entry attempt per closed 5-minute bar | SAFETY | none |
| 2.4 | No entry while the spread is above $0.60 | SAFETY | `MaxSpreadDollars = 0.60` |

### Position sizes

| # | Rule | Source | EA input |
|---|---|---|---|
| 3.1 | **Fixed** sizes: Position 1 = **0.04**, Position 2 = **0.08**, Position 3 = **0.10** lots | P (tutorial: "my first position should always be my lowest amount, say 0.04"), chosen by USER on Nov 4 | `Lots1`, `Lots2`, `Lots3` |
| 3.2 | If a size isn't affordable (margin) or isn't allowed by the broker, **skip and log the reason**. Never shrink it | P (v1.0 §12) | none |
| 3.3 | Three positions at most, never a fourth | P | none |

**Change from v1.0:** v1.0 said Position 1 = 0.04 lots **per $100 of balance**. P's tutorial text says a fixed 0.04. The user chose **fixed** on Nov 4. Reason: per-$100 sizing can't open even Position 1 at 1:50 at any balance (it needs about 3.2× the balance in margin at $4,000 gold).

### Staging and profit stops

| # | Rule | Source | EA input |
|---|---|---|---|
| 4.1 | Never add to a losing position. Add only after a favourable move with every open position in profit | P | none |
| 4.2 | "Several dollars" / "comfortable position" = **$3** move in the trend direction beyond the latest entry | TEST | `StepDollars = 3.0` |
| 4.3 | Position 1 reaches $3: **first** its stop goes to entry **+ $0.50** (− for SELL). **Only after MT4 accepts it** does Position 2 open | P (tutorial: "add my stop loss then add my 2nd position"), USER confirmed Nov 4 | `BufferDollars = 0.50` |
| 4.4 | Once price allows, both stops move to **Position 2's open + $0.50** (− for SELL) | P (Oct 18 / Nov 4: "slightly above the break even of the position 2's open") | `BufferDollars` |
| 4.5 | Position 3 opens only after Positions 1 and 2 both have accepted profit stops and price moves another $3 | P | `StepDollars` |
| 4.6 | With all three open: stops go to Position 3's open + $0.50, then rise by $3 with every further $3 move | P ("add a stop loss for all three at the new profit line"), step size TEST | `StepDollars`, `BufferDollars` |
| 4.7 | Stops are **never negative** and only ever tighten | P | none |
| 4.8 | Earlier stops aren't pulled up when a new position opens (so a small dip can't knock out Position 1 and strand Position 2) | SAFETY, after the Nov 4 demo | none |

### Exits

| # | Rule | Source | EA input |
|---|---|---|---|
| 5.1 | Profit stops close positions in profit | P | none |
| 5.2 | **Trend reversal:** if the trend reading (30 min and 2 h, the same as entry) points against an open position, close every position that has no profit stop yet (this can be a loss) | USER (Nov 4, "it has to follow the trend") | `ExitOnTrendReversal = true` |
| 5.3 | **Leftover:** if a position closes at its stop while another has no profit stop yet, close that one too | USER (Nov 4), answers v1.0 question 9 | none |

**Known weakness, not installed fix:** because the exit uses the same reading as the entry, it flip-flops in sideways markets. On Nov 4 it produced 8 small losses in a row (−$176). A slower exit (2 h and 3 h, inputs `ExitShortMinutes` / `ExitLongMinutes`) is in the repo version of the EA. **The user chose not to install it** (Nov 5), so the VPS runs the 30 min / 2 h exit.

### Session

| # | Rule | Source | EA input |
|---|---|---|---|
| 6.1 | A session = one broker day; it starts from that day's opening balance (separate per account) | TEST (v1.0 left it undefined) | none |
| 6.2 | At **+10%** equity: no new Position 1; open trades keep running | P goal; behaviour TEST | `SessionGoalPercent = 10` |
| 6.3 | At **+25%** equity: close everything, no more trades that day | P | `SessionProfitStopPercent = 25` |

### Losses and risk limits

| # | Rule | Source | EA input |
|---|---|---|---|
| 7.1 | **No losing-side stop.** Position 1 has no stop until it's $3 in profit | P ("we never set a negative stop loss"), kept by USER Nov 5 | `SafetyStopDollars = 0` |
| 7.2 | No daily loss limit | USER (kept P pure, Nov 5) | `DailyLossLimitPercent = 0` |
| 7.3 | *Optional, off:* safety stop on every position (suggested $10) and daily loss limit (suggested 3%) | SAFETY alternative, **not approved** | same inputs |

**Known exposure under 7.1:** at 0.04 lots, every $1 that gold moves against Position 1 costs $4. Only rules 5.2 and 5.3, or the broker's margin stop-out, end a losing trade.

---

## 2. Not built yet

| Item | Why |
|---|---|
| **Newsday mode** (0.10 / 0.10 / 0.10, +50% target) | P hasn't defined what makes a day a "Newsday", when to enter, or its exits |
| News filter | The parked `server/` code can pause trading around high-impact USD news. Not connected, and not part of P's method |

## 3. Open questions for P

1. Is **1:50** still the leverage to judge the method on, and does any result at 1:100 count?
2. Is **$3** close to what P means by "several dollars"? Would P test $2 or $5?
3. Is **$0.50** what P means by "slightly"? This number sets the size of most wins (Position 2 usually locks only $4).
4. P's rules give no exit for a trade that goes against you before it's $3 in profit. Are rules 5.2 and 5.3 acceptable to P?
5. At +10%, should the bot stop for the day, or keep going toward +25%?

## 4. Demo results so far

MetaQuotes-Demo account 176678082, $5,000 deposit, **1:100** (not yet the 1:50 baseline), Nov 4–5, 2026.

| Measure | Value |
|---|---|
| Closed gold trades | 84 |
| Net closed profit | **+$270** |
| Profit factor | 1.53 |
| Win rate | 79% |
| Average win / average loss | +$11.70 / −$28.44 |
| Maximum drawdown | 4.11% |
| Trades closed at a profit stop | 66, **all wins**, +$782 |
| Trades closed with no stop | 18, **all losses**, −$512 |

This is 1.5 days, mostly one strong uptrend and one sideways day. It isn't enough to judge the method. Run several weeks on unchanged settings, ideally at 1:50, and track the results with Myfxbook.

## 5. Change log

| Date | Change | Source |
|---|---|---|
| Oct 18 | v1.0 handoff | P |
| Nov 2 | EA built around the method: trend rule, sizes, profit stops, session targets | P + TEST |
| Nov 4 | Fixed sizes 0.04 / 0.08 / 0.10 | P tutorial, USER |
| Nov 4 | Position 1 gets its stop **before** Position 2 opens | P tutorial, USER |
| Nov 4 | Gold-only check; per-account session; status panel | SAFETY |
| Nov 4 | Trend-reversal exit (rule 5.2) | USER |
| Nov 4 | Leftover close (rule 5.3); earlier stops no longer pulled up (rule 4.8) | USER, SAFETY |
| Nov 5 | Optional safety stop also covers open positions (off) | SAFETY alternative |
| Nov 5 | Slower trend-reversal exit (2 h / 3 h) written; **not installed** by USER | SAFETY proposal |
| Nov 5 | Kept P's no-negative-stop rule; failsafe stays off | USER |
