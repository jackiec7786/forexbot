//+------------------------------------------------------------------+
//|                                          XAUUSD_TrendScaler.mq4  |
//|  P's XAU/USD three-position method.                              |
//|                                                                  |
//|  Default inputs = the owner's method:                            |
//|    - Position sizes 0.04 / 0.08 / 0.10 lots per $100 balance     |
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
   SIZING_FORMULA      = 0, // Formula: lots per $100 of balance (owner's method)
   SIZING_RISK_PERCENT = 1  // Risk %: size from SafetyStopDollars (alternative)
};

input string          _s1 = "===== Trend (line graph) =====";
input ENUM_TIMEFRAMES TrendTimeframe    = PERIOD_M5;
input int             TrendShortMinutes = 30;   // [TEST] Price must be beyond its level this many minutes ago...
input int             TrendLongMinutes  = 120;  // [TEST] ...and beyond its level this many minutes ago

input string           _s2 = "===== Position sizes =====";
input ENUM_SIZING_MODE SizingMode      = SIZING_FORMULA;
input double           Lots1Per100     = 0.04;  // Position 1 lots per $100 balance
input double           Lots2Per100     = 0.08;  // Position 2 lots per $100 balance
input double           Lots3Per100     = 0.10;  // Position 3 lots per $100 balance

input string _s3 = "===== Scaling and profit stops =====";
input double StepDollars   = 3.0;   // [TEST] "Several dollars": favourable move before the next position
input double BufferDollars = 0.50;  // [TEST] "Slightly": stop distance past the latest position's open

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

   string prefix = "TS_" + IntegerToString(MagicNumber) + "_" + Symbol() + "_";
   gKeyDay      = prefix + "day";
   gKeyDayStart = prefix + "daystart";
   gKeyLocked   = prefix + "locked";
   gKeyLastId   = prefix + "lastid";
   if (!IsTesting() && GlobalVariableCheck(gKeyLastId))
      gLastSignalId = (long)GlobalVariableGet(gKeyLastId);

   if (SafetyStopDollars <= 0)
      Print("Owner's method: no losing stop. A trade that goes against you stays open until it recovers or the broker's margin stop-out closes it.");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if (!SessionAllowsTrading()) return;

   int buys  = CountPositions(OP_BUY);
   int sells = CountPositions(OP_SELL);

   if (buys + sells == 0)
   {
      TryOpenPosition1();
      return;
   }

   int type = (buys > 0) ? OP_BUY : OP_SELL;
   ManageProfitStops(type);
   TryScaleIn(type, buys + sells);
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
   if (SessionGoalReached()) return;

   long barId = (long)iTime(Symbol(), TrendTimeframe, 1);
   if (barId == 0 || barId == gLastSignalId) return;   // At most one entry per closed bar

   int trend = TrendDirection();
   if (trend == NONE) return;
   if (!SpreadOk()) return;

   OpenPosition(trend, 1);
   RememberSignal(barId);   // One attempt per bar, success or not
}

// Gate: favourable move of StepDollars beyond the latest position,
// every position in profit, and (from Position 3) every position
// already protected by a profit stop.
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

   gLastScaleAttempt = TimeCurrent();
   OpenPosition(type, total + 1);
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
   if (stage == 1) return Lots1Per100;
   if (stage == 2) return Lots2Per100;
   return Lots3Per100;
}

double LotsForStage(int stage)
{
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if (step <= 0) return 0;

   double wanted;
   if (SizingMode == SIZING_FORMULA)
   {
      wanted = StageWeight(stage) * AccountBalance() / 100.0;
   }
   else
   {
      // Total loss if all three positions hit SafetyStopDollars = RiskPercentPerStack,
      // split in the same 0.04 : 0.08 : 0.10 proportions as the formula.
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
      if (tickValue <= 0 || tickSize <= 0) return 0;
      double share      = StageWeight(stage) / (Lots1Per100 + Lots2Per100 + Lots3Per100);
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
      return 0;
   }
   if (lots < minLot)
   {
      Print("Position ", stage, ": ", DoubleToString(wanted, 4), " lots is below the broker minimum. Skipped.");
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
//| Profit stops (owner's rule): once Position 2 is open, all stops  |
//| go BufferDollars past the latest position's open (above for BUY, |
//| below for SELL), as soon as price is far enough to place them.   |
//| With all three open, the level steps on every StepDollars move.  |
//| Stops only ever tighten and are always in profit.                |
//+------------------------------------------------------------------+
void ManageProfitStops(int type)
{
   int total = CountPositions(type);
   if (total < 2) return;   // Position 1 alone: no stop under the owner's rule

   RefreshRates();
   double price   = (type == OP_BUY) ? Bid : Ask;
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double front   = (type == OP_BUY) ? HighestOpen(OP_BUY) : LowestOpen(OP_SELL);
   double moved   = (type == OP_BUY) ? price - front : front - price;

   // Highest step level that can legally be placed right now.
   double room = moved - BufferDollars - minDist;
   if (room < 0) return;
   double steps = (total >= MAX_POSITIONS) ? MathFloor(room / StepDollars) : 0;
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
