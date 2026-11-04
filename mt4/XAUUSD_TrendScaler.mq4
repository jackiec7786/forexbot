//+------------------------------------------------------------------+
//|                                          XAUUSD_TrendScaler.mq4  |
//|  P's XAU/USD three-position method.                              |
//|                                                                  |
//|  Default inputs = the owner's method:                            |
//|    - Fixed position sizes 0.04 / 0.08 / 0.10 lots                |
//|    - No losing stop. Stops are only ever placed in profit.       |
//|  Optional alternative (for comparison in the Strategy Tester):   |
//|    SizingMode = RISK_PERCENT and SafetyStopDollars > 0.          |
//|                                                                  |
//|  Numbers marked [TEST] are test assumptions chosen with the      |
//|  owner, not proven values.                                       |
//+------------------------------------------------------------------+
#property strict
#property description "P's XAU/USD three-position method. Defaults follow the owner's rules (no losing stop)."
#property description "Set SizingMode = RISK_PERCENT and SafetyStopDollars > 0 to test the risk-limited alternative."

enum ENUM_SIZING_MODE
{
   SIZING_FIXED        = 0, // Fixed lots: 0.04 / 0.08 / 0.10 (owner's method)
   SIZING_RISK_PERCENT = 1  // Risk %: size from SafetyStopDollars (alternative)
};

input string          _s1 = "===== Trend (line graph) =====";
input ENUM_TIMEFRAMES TrendTimeframe    = PERIOD_M5;
input int             TrendShortMinutes = 30;   // [TEST] Price must be beyond its level this many minutes ago...
input int             TrendLongMinutes  = 120;  // [TEST] ...and beyond its level this many minutes ago

input string           _s2 = "===== Position sizes =====";
input ENUM_SIZING_MODE SizingMode      = SIZING_FIXED;
input double           Lots1           = 0.04;  // Position 1 lots (always the smallest)
input double           Lots2           = 0.08;  // Position 2 lots
input double           Lots3           = 0.10;  // Position 3 lots

input string _s3 = "===== Scaling and profit stops =====";
input double StepDollars   = 3.0;   // [TEST] "Several dollars": favourable move before the next position
input double BufferDollars = 0.50;  // [TEST] "Slightly": stop distance past the latest position's open
input bool   ExitOnTrendReversal = true;  // Close positions without a profit stop when the trend confirms the opposite way

input string _s4 = "===== Session (owner targets) =====";
input double SessionGoalPercent       = 10.0;  // At this gain: no new Position 1 (open trades keep running)
input double SessionProfitStopPercent = 25.0;  // At this gain: close everything, done for the day

input string _s5 = "===== Alternative: risk limits (0 = off) =====";
input double SafetyStopDollars     = 0.0;  // Losing stop on every position. 0 = owner's method (none)
input double RiskPercentPerStack   = 1.0;  // Used only with SIZING_RISK_PERCENT
input double DailyLossLimitPercent = 0.0;  // Close everything at this loss. 0 = off

input string _s6 = "===== General =====";
input double MaxSpreadDollars = 0.60;
input int    MagicNumber      = 333333;
input int    SlippagePoints   = 30;

#define NONE          -1
#define MAX_POSITIONS 3     // The method has exactly three positions. No fourth.

long     gLastSignalId     = 0;
datetime gLastScaleAttempt = 0;
datetime gLastTickLocal    = 0;
string   gStatus           = "Starting up";
string   gLastAttempt      = "none yet";
int      gLastCount        = 0;
string   gKeyDay, gKeyDayStart, gKeyLocked, gKeyLastId;

//+------------------------------------------------------------------+
int OnInit()
{
   int tfMinutes = PeriodSeconds(TrendTimeframe) / 60;
   if (tfMinutes <= 0 || TrendShortMinutes < tfMinutes || TrendLongMinutes <= TrendShortMinutes ||
       TrendShortMinutes % tfMinutes != 0 || TrendLongMinutes % tfMinutes != 0)
   {
      Print("Trend minutes must be multiples of the trend timeframe, with Long > Short.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if (StepDollars <= 0 || BufferDollars <= 0 || BufferDollars >= StepDollars)
   {
      Print("Need StepDollars > BufferDollars > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if (SizingMode == SIZING_RISK_PERCENT && (SafetyStopDollars <= 0 || RiskPercentPerStack <= 0))
   {
      Print("RISK_PERCENT sizing needs SafetyStopDollars > 0 and RiskPercentPerStack > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Gold only: the dollar steps and buffers are sized for gold prices.
   string sym = Symbol();
   StringToUpper(sym);
   if (StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
   {
      Alert("XAUUSD_TrendScaler only runs on a gold chart (XAUUSD). This chart is ", Symbol(), ".");
      return INIT_FAILED;
   }

   // Per account, so switching accounts never reuses another account's day start.
   string prefix = "TS_" + IntegerToString(AccountNumber()) + "_" + IntegerToString(MagicNumber) + "_" + Symbol() + "_";
   gKeyDay      = prefix + "day";
   gKeyDayStart = prefix + "daystart";
   gKeyLocked   = prefix + "locked";
   gKeyLastId   = prefix + "lastid";
   if (!IsTesting() && GlobalVariableCheck(gKeyLastId))
      gLastSignalId = (long)GlobalVariableGet(gKeyLastId);

   if (SafetyStopDollars <= 0)
      Print("Owner's method: no losing stop. A trade that goes against you stays open until it recovers or the broker's margin stop-out closes it.");

   gLastTickLocal = TimeLocal();
   if (!IsTesting()) EventSetTimer(10);   // Keeps the status panel honest when no prices arrive
   ShowStatus();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   gLastTickLocal = TimeLocal();
   RunStrategy();
   gLastCount = CountPositions(NONE);
   ShowStatus();
}

void RunStrategy()
{
   if (!IsTradeAllowed())
   {
      SetStatus("Trading is OFF. Turn on the AutoTrading button and tick 'Allow live trading' in the EA settings.");
      return;
   }
   if (!SessionAllowsTrading())
   {
      SetStatus("Done for today: session profit stop or loss limit reached.");
      return;
   }

   int buys  = CountPositions(OP_BUY);
   int sells = CountPositions(OP_SELL);

   // A position just closed (its profit stop was hit) while another one
   // still has no profit stop: the move failed, so close the leftover too.
   if (buys + sells > 0 && buys + sells < gLastCount)
   {
      int left = (buys > 0) ? OP_BUY : OP_SELL;
      if (!AllPositionsProtected(left) && CloseUnprotected(left, "A stop was hit and the rest had no profit stop"))
         return;
   }

   if (buys + sells == 0)
   {
      TryOpenPosition1();
      return;
   }

   int type = (buys > 0) ? OP_BUY : OP_SELL;
   SetStatus("Managing " + IntegerToString(buys + sells) + " " + (type == OP_BUY ? "BUY" : "SELL") + " position(s).");

   // Follow the trend both ways: if it confirms the opposite direction,
   // close whatever is not yet protected by a profit stop.
   int against = (type == OP_BUY) ? OP_SELL : OP_BUY;
   if (ExitOnTrendReversal && TrendDirection() == against &&
       CloseUnprotected(type, string("Trend turned ") + (type == OP_BUY ? "DOWN" : "UP"))) return;
   ManageProfitStops(type);
   TryScaleIn(type, buys + sells);
}

// No ticks means the market is closed or the connection is down. Say so.
void OnTimer()
{
   int quietSeconds = (int)(TimeLocal() - gLastTickLocal);
   if (quietSeconds >= 120)
   {
      gStatus = "No price updates for " + IntegerToString(quietSeconds / 60) +
                " min. Market closed (weekend/holiday) or no connection to the broker.";
      ShowStatus();
   }
}

//+------------------------------------------------------------------+
//| Status panel (top-left of the chart) and log                     |
//+------------------------------------------------------------------+
void SetStatus(string text)
{
   if (text != gStatus && !IsTesting()) Print("Status: ", text);
   gStatus = text;
}

void ShowStatus()
{
   if (IsTesting() && !IsVisualMode()) return;

   int    trend  = TrendDirection();
   string trendText = (trend == OP_BUY) ? "UP (buy)" : (trend == OP_SELL) ? "DOWN (sell)" : "unclear (wait)";
   double start  = GlobalVariableCheck(gKeyDayStart) ? GlobalVariableGet(gKeyDayStart) : AccountBalance();
   double dayPct = (start > 0) ? (AccountEquity() / start - 1.0) * 100.0 : 0;

   Comment("XAUUSD three-position EA  |  ", (SafetyStopDollars > 0 ? "risk-limited" : "owner's method"), "\n",
           "AutoTrading: ", (IsTradeAllowed() ? "ON" : "OFF"), "\n",
           "Trend (30 min & 2 h): ", trendText, "\n",
           "Spread: $", DoubleToString(Ask - Bid, 2), "  (max $", DoubleToString(MaxSpreadDollars, 2), ")\n",
           "Today: ", DoubleToString(dayPct, 2), "%  (goal +", DoubleToString(SessionGoalPercent, 0),
           "%, stop +", DoubleToString(SessionProfitStopPercent, 0), "%)\n",
           "Status: ", gStatus);
}

//+------------------------------------------------------------------+
//| Session: resets at the start of each broker day.                 |
//| +Goal%: no new Position 1. +ProfitStop%: close all, lock the day.|
//| Optional -DailyLoss%: close all, lock the day.                   |
//+------------------------------------------------------------------+
bool SessionAllowsTrading()
{
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if (!GlobalVariableCheck(gKeyDay) || (datetime)GlobalVariableGet(gKeyDay) != today)
   {
      GlobalVariableSet(gKeyDay, (double)today);
      GlobalVariableSet(gKeyDayStart, AccountBalance());
      GlobalVariableSet(gKeyLocked, 0);
   }
   if (GlobalVariableGet(gKeyLocked) > 0) return false;

   double start  = GlobalVariableGet(gKeyDayStart);
   double equity = AccountEquity();

   if (SessionProfitStopPercent > 0 && equity >= start * (1.0 + SessionProfitStopPercent / 100.0))
   {
      Print("Session profit stop (+", DoubleToString(SessionProfitStopPercent, 1), "%) reached. Closing all, done for today.");
      CloseAll();
      GlobalVariableSet(gKeyLocked, 1);
      return false;
   }
   if (DailyLossLimitPercent > 0 && equity <= start * (1.0 - DailyLossLimitPercent / 100.0))
   {
      Print("Daily loss limit (-", DoubleToString(DailyLossLimitPercent, 1), "%) hit. Closing all, done for today.");
      CloseAll();
      GlobalVariableSet(gKeyLocked, 1);
      return false;
   }
   return true;
}

bool SessionGoalReached()
{
   if (SessionGoalPercent <= 0) return false;
   return AccountEquity() >= GlobalVariableGet(gKeyDayStart) * (1.0 + SessionGoalPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Trend: on closed bars, price above its level both TrendShort and |
//| TrendLong minutes ago = BUY; below both = SELL; else WAIT.       |
//+------------------------------------------------------------------+
int TrendDirection()
{
   int tfMinutes = PeriodSeconds(TrendTimeframe) / 60;
   double now   = iClose(Symbol(), TrendTimeframe, 1);
   double pastShort = iClose(Symbol(), TrendTimeframe, 1 + TrendShortMinutes / tfMinutes);
   double pastLong  = iClose(Symbol(), TrendTimeframe, 1 + TrendLongMinutes / tfMinutes);
   if (now <= 0 || pastShort <= 0 || pastLong <= 0) return NONE;

   if (now > pastShort && now > pastLong) return OP_BUY;
   if (now < pastShort && now < pastLong) return OP_SELL;
   return NONE;   // Sideways or conflicting: WAIT
}

//+------------------------------------------------------------------+
//| Entries                                                          |
//+------------------------------------------------------------------+
void TryOpenPosition1()
{
   if (SessionGoalReached())
   {
      SetStatus("Session goal reached: no new Position 1 today.");
      return;
   }

   long barId = (long)iTime(Symbol(), TrendTimeframe, 1);
   if (barId == 0)
   {
      SetStatus("Loading 5-minute price history. If this stays, open an M5 chart of this symbol once.");
      return;
   }
   if (barId == gLastSignalId)
   {
      SetStatus("Waiting for the next 5-minute bar. Last attempt: " + gLastAttempt);
      return;   // At most one entry per closed bar
   }

   int trend = TrendDirection();
   if (trend == NONE)
   {
      SetStatus("No clear trend (30 min and 2 h disagree). Waiting.");
      return;
   }
   if (!SpreadOk())
   {
      SetStatus("Trend found but spread $" + DoubleToString(Ask - Bid, 2) + " is above MaxSpreadDollars. Waiting.");
      return;
   }

   if (OpenPosition(trend, 1))
      SetStatus("Opened Position 1 " + (trend == OP_BUY ? "BUY" : "SELL") + ".");
   gLastAttempt = gStatus;   // Keep the result (or failure reason) on the panel
   RememberSignal(barId);   // One attempt per bar, success or not
}

// Owner's sequence: favourable move of StepDollars beyond the latest
// position and every position in profit -> protect the earlier
// position(s) with a profit stop FIRST -> only then open the next one.
void TryScaleIn(int type, int total)
{
   if (total >= MAX_POSITIONS) return;
   if (TimeCurrent() < gLastScaleAttempt + 60) return;
   if (!AllPositionsInProfit()) return;
   if (total >= 2 && !AllPositionsProtected(type)) return;

   RefreshRates();
   double moved = (type == OP_BUY) ? Bid - HighestOpen(OP_BUY) : LowestOpen(OP_SELL) - Ask;
   if (moved < StepDollars) return;
   if (!SpreadOk()) return;

   if (total == 1 && !AllPositionsProtected(type))
   {
      ProtectPosition1(type);
      if (!AllPositionsProtected(type))
      {
         SetStatus("Position 1 is in profit but its stop was not accepted yet. Position 2 waits.");
         return;
      }
   }

   gLastScaleAttempt = TimeCurrent();
   if (OpenPosition(type, total + 1))
      ManageProfitStops(type);   // Move stops at once if price already allows
}

// Position 1's first stop: BufferDollars past its own entry, in profit.
void ProtectPosition1(int type)
{
   RefreshRates();
   double price   = (type == OP_BUY) ? Bid : Ask;
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs() || OrderType() != type) continue;
      double target = NormalizeDouble((type == OP_BUY) ? OrderOpenPrice() + BufferDollars
                                                       : OrderOpenPrice() - BufferDollars, Digits);
      bool legal = (type == OP_BUY) ? price - target >= minDist : target - price >= minDist;
      if (!legal) continue;
      if (OrderModify(OrderTicket(), OrderOpenPrice(), target, 0, 0, clrGreen))
         SetStatus("Position 1 protected at " + DoubleToString(target, Digits) + ". Opening Position 2.");
      else
         Print("Position 1 stop failed. Error ", GetLastError());
   }
}

bool OpenPosition(int type, int stage)
{
   double lots = LotsForStage(stage);
   if (lots <= 0) return false;

   ResetLastError();
   if (AccountFreeMarginCheck(Symbol(), type, lots) <= 0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   {
      Print("Position ", stage, " skipped: not enough margin for ", DoubleToString(lots, 2),
            " lots at this leverage. The formula size was not reduced.");
      SetStatus("Position " + IntegerToString(stage) + " skipped: not enough margin for " + DoubleToString(lots, 2) +
                " lots. Leverage too low for the formula.");
      return false;
   }

   RefreshRates();
   double price = (type == OP_BUY) ? Ask : Bid;
   double sl    = 0;
   if (SafetyStopDollars > 0)
      sl = NormalizeDouble((type == OP_BUY) ? price - SafetyStopDollars : price + SafetyStopDollars, Digits);

   string tag = "Pos " + IntegerToString(stage);
   color  clr = (type == OP_BUY) ? clrBlue : clrRed;

   int ticket = OrderSend(Symbol(), type, lots, price, SlippagePoints, sl, 0, tag, MagicNumber, 0, clr);
   if (ticket >= 0) return true;

   int err = GetLastError();
   if (sl == 0 || err != ERR_INVALID_STOPS)
   {
      Print(tag, " OrderSend failed. Error ", err);
      SetStatus(tag + " rejected by the broker. Error " + IntegerToString(err) + ".");
      return false;
   }

   // Some ECN accounts reject a stop on market orders: open, then attach
   // the safety stop. If that fails, close: never leave it unprotected
   // when the safety stop is switched on.
   RefreshRates();
   price  = (type == OP_BUY) ? Ask : Bid;
   ticket = OrderSend(Symbol(), type, lots, price, SlippagePoints, 0, 0, tag, MagicNumber, 0, clr);
   if (ticket < 0)
   {
      Print(tag, " OrderSend (no SL) failed. Error ", GetLastError());
      return false;
   }
   if (!OrderSelect(ticket, SELECT_BY_TICKET)) return false;

   sl = NormalizeDouble((type == OP_BUY) ? OrderOpenPrice() - SafetyStopDollars
                                         : OrderOpenPrice() + SafetyStopDollars, Digits);
   if (OrderModify(ticket, OrderOpenPrice(), sl, 0, 0, clrGreen)) return true;

   Print("Could not attach safety stop (error ", GetLastError(), "). Closing ", tag, ".");
   RefreshRates();
   if (!OrderClose(ticket, OrderLots(), (type == OP_BUY) ? Bid : Ask, SlippagePoints, clrWhite))
      Print("URGENT: failed to close ticket ", ticket, ". Error ", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Sizes                                                            |
//+------------------------------------------------------------------+
double StageWeight(int stage)
{
   if (stage == 1) return Lots1;
   if (stage == 2) return Lots2;
   return Lots3;
}

double LotsForStage(int stage)
{
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if (step <= 0) return 0;

   double wanted;
   if (SizingMode == SIZING_FIXED)
   {
      wanted = StageWeight(stage);
   }
   else
   {
      // Total loss if all three positions hit SafetyStopDollars = RiskPercentPerStack,
      // split in the same 0.04 : 0.08 : 0.10 proportions as the formula.
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
      if (tickValue <= 0 || tickSize <= 0) return 0;
      double share      = StageWeight(stage) / (Lots1 + Lots2 + Lots3);
      double riskMoney  = AccountBalance() * RiskPercentPerStack / 100.0 * share;
      double lossPerLot = SafetyStopDollars / tickSize * tickValue;
      wanted = riskMoney / lossPerLot;
   }

   double lots = MathFloor(wanted / step + 1e-9) * step;
   if (MathAbs(lots - wanted) > 1e-9)
      Print("Position ", stage, ": wanted ", DoubleToString(wanted, 4), " lots, broker lot step allows ",
            DoubleToString(lots, 2), ".");
   if (lots > maxLot)
   {
      Print("Position ", stage, ": ", DoubleToString(lots, 2), " lots is above the broker maximum. Skipped.");
      SetStatus("Position " + IntegerToString(stage) + " skipped: size above the broker maximum.");
      return 0;
   }
   if (lots < minLot)
   {
      Print("Position ", stage, ": ", DoubleToString(wanted, 4), " lots is below the broker minimum. Skipped.");
      SetStatus("Position " + IntegerToString(stage) + " skipped: size below the broker minimum.");
      return 0;
   }
   return NormalizeDouble(lots, 2);
}

bool SpreadOk()
{
   RefreshRates();
   return (Ask - Bid) <= MaxSpreadDollars;
}

void RememberSignal(long id)
{
   gLastSignalId = id;
   if (!IsTesting()) GlobalVariableSet(gKeyLastId, (double)id);
}

//+------------------------------------------------------------------+
//| Profit stops (owner's rule). Stop levels form a ladder:          |
//|   latest position's open +/- BufferDollars, +/- whole StepDollars.|
//| The EA always uses the highest rung MT4 accepts right now:       |
//|  - Earlier stops are NOT pulled up when a new position opens, so |
//|    a small dip can't knock out Position 1 and strand Position 2. |
//|  - Once price is BufferDollars past the newest open, all stops   |
//|    move there (Position 2's open + $0.50 for a BUY).             |
//|  - With all three open, every further StepDollars move lifts all |
//|    stops by StepDollars.                                         |
//| Stops only ever tighten and are always in profit.                |
//+------------------------------------------------------------------+
void ManageProfitStops(int type)
{
   int total = CountPositions(type);
   if (total < 2) return;   // Position 1 alone: its first stop is set in ProtectPosition1

   RefreshRates();
   double price   = (type == OP_BUY) ? Bid : Ask;
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double front   = (type == OP_BUY) ? HighestOpen(OP_BUY) : LowestOpen(OP_SELL);
   double moved   = (type == OP_BUY) ? price - front : front - price;

   // Highest rung that can legally be placed right now.
   double steps = MathFloor((moved - BufferDollars - minDist) / StepDollars);
   if (total < MAX_POSITIONS && steps > 0) steps = 0;   // Stepping starts with all three in
   if (steps < 0) return;
   double offset = steps * StepDollars + BufferDollars;
   double target = NormalizeDouble((type == OP_BUY) ? front + offset : front - offset, Digits);

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs() || OrderType() != type) continue;

      bool inProfit, tighter;
      if (type == OP_BUY)
      {
         inProfit = target > OrderOpenPrice();
         tighter  = OrderStopLoss() == 0 || target > OrderStopLoss() + Point / 2.0;
      }
      else
      {
         inProfit = target < OrderOpenPrice();
         tighter  = OrderStopLoss() == 0 || target < OrderStopLoss() - Point / 2.0;
      }

      if (inProfit && tighter && !OrderModify(OrderTicket(), OrderOpenPrice(), target, 0, 0, clrGreen))
         Print("OrderModify failed on ticket ", OrderTicket(), ". Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsOurs()
{
   return OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber;
}

// type = OP_BUY, OP_SELL, or NONE for both.
int CountPositions(int type)
{
   int count = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs()) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (type == NONE || OrderType() == type) count++;
   }
   return count;
}

double HighestOpen(int type)
{
   double highest = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && IsOurs() && OrderType() == type)
         highest = MathMax(highest, OrderOpenPrice());
   return highest;
}

double LowestOpen(int type)
{
   double lowest = DBL_MAX;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && IsOurs() && OrderType() == type)
         lowest = MathMin(lowest, OrderOpenPrice());
   return lowest;
}

bool AllPositionsInProfit()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && IsOurs())
         if (OrderProfit() + OrderSwap() + OrderCommission() <= 0) return false;
   return true;
}

// Every position has a stop on the profit side of its open price.
bool AllPositionsProtected(int type)
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs() || OrderType() != type) continue;
      if (OrderStopLoss() == 0) return false;
      if (type == OP_BUY  && OrderStopLoss() <= OrderOpenPrice()) return false;
      if (type == OP_SELL && OrderStopLoss() >= OrderOpenPrice()) return false;
   }
   return true;
}

// Closes positions of this type whose stop is missing or not in profit.
// Returns true if anything was closed.
bool CloseUnprotected(int type, string reason)
{
   bool   closedAny = false;
   double result    = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs() || OrderType() != type) continue;
      bool protectedStop = OrderStopLoss() != 0 &&
                           ((type == OP_BUY  && OrderStopLoss() > OrderOpenPrice()) ||
                            (type == OP_SELL && OrderStopLoss() < OrderOpenPrice()));
      if (protectedStop) continue;

      double pnl = OrderProfit() + OrderSwap() + OrderCommission();
      RefreshRates();
      double price = (type == OP_BUY) ? Bid : Ask;
      if (OrderClose(OrderTicket(), OrderLots(), price, SlippagePoints, clrOrange))
      {
         closedAny = true;
         result   += pnl;
      }
      else
         Print("Trend-reversal close failed on ticket ", OrderTicket(), ". Error ", GetLastError());
   }
   if (closedAny)
      SetStatus(reason + ": closed unprotected position(s), result $" + DoubleToString(result, 2) + ".");
   return closedAny;
}

void CloseAll()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs()) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      RefreshRates();
      double price = (OrderType() == OP_BUY) ? Bid : Ask;
      if (!OrderClose(OrderTicket(), OrderLots(), price, SlippagePoints, clrWhite))
         Print("OrderClose failed on ticket ", OrderTicket(), ". Error ", GetLastError());
   }
}
//+------------------------------------------------------------------+
