//+------------------------------------------------------------------+
//|                                          XAUUSD_TrendScaler.mq4  |
//|  Gold trend-flip EA with hard stop loss, risk-based sizing,      |
//|  daily loss limit, scale-in and step-trailing stops.             |
//+------------------------------------------------------------------+
#property strict
#property description "Trend-flip EA for XAUUSD. Every position has a hard stop loss."
#property description "Use SignalSource = LOCAL for the Strategy Tester (WebRequest does not work there)."

enum ENUM_SIGNAL_SOURCE
{
   SOURCE_LOCAL  = 0, // Local: compute the trend flip inside MT4
   SOURCE_SERVER = 1  // Server: ask the signal server (TradingView + news filter)
};

input string             _s1 = "===== Signal =====";
input ENUM_SIGNAL_SOURCE SignalSource    = SOURCE_LOCAL;
input ENUM_TIMEFRAMES    SignalTimeframe = PERIOD_H1;
input int                LookbackBars    = 3;     // Compare close now vs close N bars ago

input string _s2 = "===== Risk =====";
input double RiskPercentPerStack   = 1.0;   // % of balance lost if ALL positions hit their initial stop
input double StopLossDollars       = 10.0;  // Initial stop distance in price ($ per oz)
input double DailyLossLimitPercent = 3.0;   // Close everything and stop for the day at this loss
input double MaxSpreadDollars      = 0.60;  // Skip entries when spread is wider than this

input string _s3 = "===== Scaling & trailing =====";
input int    MaxPositions  = 3;     // Positions per direction, including the first
input double ScaleDistance = 3.0;   // $ move in favour before adding the next position
input double LockInDollars = 0.50;  // Profit locked per position once the stop starts trailing

input string _s4 = "===== Server (SignalSource = SERVER) =====";
input string ServerUrl       = "https://your-domain.example/api/signal";
input string ServerSecret    = "";   // Same value as SIGNAL_SECRET on the server
input int    PollSeconds     = 30;
input int    ServerTimeoutMs = 3000;

input string _s5 = "===== General =====";
input int MagicNumber    = 333333;
input int SlippagePoints = 30;

#define NO_SIGNAL -1

long     gLastSignalId     = 0;
datetime gLastPoll         = 0;
datetime gLastScaleAttempt = 0;
string   gKeyDay, gKeyDayStart, gKeyLastId;

//+------------------------------------------------------------------+
int OnInit()
{
   if (LookbackBars < 1 || MaxPositions < 1 || StopLossDollars <= 0 ||
       RiskPercentPerStack <= 0 || ScaleDistance <= 0)
   {
      Print("Invalid inputs. Check LookbackBars, MaxPositions, StopLossDollars, RiskPercentPerStack, ScaleDistance.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if (SignalSource == SOURCE_SERVER && IsTesting())
   {
      Print("WebRequest does not work in the Strategy Tester. Use SignalSource = LOCAL to backtest.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if (SignalSource == SOURCE_SERVER && StringLen(ServerSecret) < 24)
   {
      Print("ServerSecret must be set (at least 24 characters, same as SIGNAL_SECRET on the server).");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Persist state in terminal global variables so a restart does not
   // reset the daily loss limit or re-trade a signal already used.
   string prefix = "TS_" + IntegerToString(MagicNumber) + "_" + Symbol() + "_";
   gKeyDay      = prefix + "day";
   gKeyDayStart = prefix + "daystart";
   gKeyLastId   = prefix + "lastid";
   if (!IsTesting() && GlobalVariableCheck(gKeyLastId))
      gLastSignalId = (long)GlobalVariableGet(gKeyLastId);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if (DailyLossLimitHit())
   {
      if (CountPositions(NO_SIGNAL) > 0)
      {
         Print("Daily loss limit of ", DoubleToString(DailyLossLimitPercent, 1), "% hit. Closing all positions until tomorrow.");
         CloseAll();
      }
      return;
   }

   int buys  = CountPositions(OP_BUY);
   int sells = CountPositions(OP_SELL);

   if (buys + sells == 0)
   {
      TryOpenFirst();
      return;
   }

   int type = (buys > 0) ? OP_BUY : OP_SELL;
   ManageTrailingStops(type);
   TryScaleIn(type, buys + sells);
}

//+------------------------------------------------------------------+
//| Daily loss limit (measured from balance at the start of the day) |
//+------------------------------------------------------------------+
bool DailyLossLimitHit()
{
   if (DailyLossLimitPercent <= 0) return false;

   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if (!GlobalVariableCheck(gKeyDay) || (datetime)GlobalVariableGet(gKeyDay) != today)
   {
      GlobalVariableSet(gKeyDay, (double)today);
      GlobalVariableSet(gKeyDayStart, AccountBalance());
   }
   double dayStart = GlobalVariableGet(gKeyDayStart);
   return AccountEquity() <= dayStart * (1.0 - DailyLossLimitPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Entries                                                          |
//+------------------------------------------------------------------+
void TryOpenFirst()
{
   long id = 0;
   int signal = GetSignal(id);
   if (signal == NO_SIGNAL || id == 0 || id == gLastSignalId) return;
   if (!SpreadOk()) return;   // Signal not used yet; retry on a later tick

   OpenPosition(signal, "entry");
   // One attempt per signal, success or not, so a failing order can never loop.
   RememberSignal(id);
}

void TryScaleIn(int type, int total)
{
   if (total >= MaxPositions) return;
   if (!AllPositionsInProfit()) return;
   if (TimeCurrent() < gLastScaleAttempt + 60) return;

   RefreshRates();
   double moved = (type == OP_BUY) ? Bid - HighestOpen(OP_BUY)
                                   : LowestOpen(OP_SELL) - Ask;
   if (moved < ScaleDistance) return;
   if (!SpreadOk()) return;

   gLastScaleAttempt = TimeCurrent();
   OpenPosition(type, "scale-in");
}

bool OpenPosition(int type, string tag)
{
   double lots = LotsForRisk();
   if (lots <= 0)
   {
      Print("Position size is below the broker minimum at this risk. Skipping. ",
            "Increase balance, or lower StopLossDollars / MaxPositions.");
      return false;
   }

   RefreshRates();
   double price = (type == OP_BUY) ? Ask : Bid;
   double sl    = NormalizeDouble((type == OP_BUY) ? price - StopLossDollars : price + StopLossDollars, Digits);
   color  clr   = (type == OP_BUY) ? clrBlue : clrRed;

   int ticket = OrderSend(Symbol(), type, lots, price, SlippagePoints, sl, 0, tag, MagicNumber, 0, clr);
   if (ticket >= 0) return true;

   int err = GetLastError();
   if (err != ERR_INVALID_STOPS)
   {
      Print("OrderSend failed. Error ", err);
      return false;
   }

   // Some ECN accounts reject a stop loss on market orders. Open without it,
   // then attach it at once. If that fails, close: never hold an unprotected trade.
   RefreshRates();
   price  = (type == OP_BUY) ? Ask : Bid;
   ticket = OrderSend(Symbol(), type, lots, price, SlippagePoints, 0, 0, tag, MagicNumber, 0, clr);
   if (ticket < 0)
   {
      Print("OrderSend (no SL) failed. Error ", GetLastError());
      return false;
   }
   if (!OrderSelect(ticket, SELECT_BY_TICKET)) return false;

   sl = NormalizeDouble((type == OP_BUY) ? OrderOpenPrice() - StopLossDollars
                                         : OrderOpenPrice() + StopLossDollars, Digits);
   if (OrderModify(ticket, OrderOpenPrice(), sl, 0, 0, clrGreen)) return true;

   Print("Could not attach stop loss (error ", GetLastError(), "). Closing the position.");
   RefreshRates();
   double closePrice = (type == OP_BUY) ? Bid : Ask;
   if (!OrderClose(ticket, OrderLots(), closePrice, SlippagePoints, clrWhite))
      Print("URGENT: failed to close unprotected ticket ", ticket, ". Error ", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Position size: each position risks RiskPercentPerStack/MaxPositions |
//+------------------------------------------------------------------+
double LotsForRisk()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double step      = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (tickValue <= 0 || tickSize <= 0 || step <= 0) return 0;

   double riskMoney  = AccountBalance() * RiskPercentPerStack / 100.0 / MaxPositions;
   double lossPerLot = StopLossDollars / tickSize * tickValue;
   double lots       = MathFloor(riskMoney / lossPerLot / step) * step;  // Round DOWN

   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if (lots > maxLot) lots = maxLot;
   if (lots < MarketInfo(Symbol(), MODE_MINLOT)) return 0;
   return NormalizeDouble(lots, 2);
}

bool SpreadOk()
{
   RefreshRates();
   return (Ask - Bid) <= MaxSpreadDollars;
}

//+------------------------------------------------------------------+
//| Signals                                                          |
//+------------------------------------------------------------------+
int GetSignal(long &id)
{
   if (SignalSource == SOURCE_LOCAL) return LocalSignal(id);
   return ServerSignal(id);
}

// Trend direction on a closed bar: close vs close LookbackBars earlier.
int Direction(int shift)
{
   double now  = iClose(Symbol(), SignalTimeframe, shift);
   double past = iClose(Symbol(), SignalTimeframe, shift + LookbackBars);
   if (now <= 0 || past <= 0) return NO_SIGNAL;
   if (now > past) return OP_BUY;
   if (now < past) return OP_SELL;
   return NO_SIGNAL;
}

// Signal only when the direction flips on the last closed bar.
// Matches tradingview/trend_flip_signal.pine.
int LocalSignal(long &id)
{
   id = (long)iTime(Symbol(), SignalTimeframe, 1);
   int d1 = Direction(1);
   int d2 = Direction(2);
   if (d1 != NO_SIGNAL && d1 != d2) return d1;
   return NO_SIGNAL;
}

// Server replies "BUY|<id>", "SELL|<id>" or "WAIT|0".
// The server already returns WAIT for stale signals and during news.
int ServerSignal(long &id)
{
   id = 0;
   if (TimeLocal() < gLastPoll + PollSeconds) return NO_SIGNAL;
   gLastPoll = TimeLocal();

   char   post[], result[];
   string responseHeaders;
   string headers = "X-Signal-Secret: " + ServerSecret + "\r\n";

   ResetLastError();
   int code = WebRequest("GET", ServerUrl, headers, ServerTimeoutMs, post, result, responseHeaders);
   if (code != 200)
   {
      Print("Signal server request failed. HTTP ", code, ", error ", GetLastError(),
            ". Is the server URL added in Tools > Options > Expert Advisors?");
      return NO_SIGNAL;
   }

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string parts[];
   if (StringSplit(body, '|', parts) != 2) return NO_SIGNAL;

   id = (long)StringToInteger(parts[1]);
   if (parts[0] == "BUY")  return OP_BUY;
   if (parts[0] == "SELL") return OP_SELL;
   return NO_SIGNAL;
}

void RememberSignal(long id)
{
   gLastSignalId = id;
   if (!IsTesting()) GlobalVariableSet(gKeyLastId, (double)id);
}

//+------------------------------------------------------------------+
//| Step-trailing stop. Stops only ever tighten, and only move once  |
//| they lock in LockInDollars of profit on that position.           |
//+------------------------------------------------------------------+
void ManageTrailingStops(int type)
{
   int total = CountPositions(type);
   if (total == 0) return;

   RefreshRates();
   double price     = (type == OP_BUY) ? Bid : Ask;
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double target;

   if (type == OP_BUY)
   {
      double front = HighestOpen(OP_BUY);
      double ref   = front;
      if (total >= MaxPositions && price > front)
         ref = front + MathFloor((price - front) / ScaleDistance) * ScaleDistance;
      target = NormalizeDouble(ref - ScaleDistance + LockInDollars, Digits);
      if (price - target < stopLevel) return;
   }
   else
   {
      double front = LowestOpen(OP_SELL);
      double ref   = front;
      if (total >= MaxPositions && price < front)
         ref = front - MathFloor((front - price) / ScaleDistance) * ScaleDistance;
      target = NormalizeDouble(ref + ScaleDistance - LockInDollars, Digits);
      if (target - price < stopLevel) return;
   }

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs() || OrderType() != type) continue;

      bool tighter;
      if (type == OP_BUY)
      {
         if (target < OrderOpenPrice() + LockInDollars) continue;
         tighter = (OrderStopLoss() == 0 || target > OrderStopLoss() + Point / 2.0);
      }
      else
      {
         if (target > OrderOpenPrice() - LockInDollars) continue;
         tighter = (OrderStopLoss() == 0 || target < OrderStopLoss() - Point / 2.0);
      }

      if (tighter && !OrderModify(OrderTicket(), OrderOpenPrice(), target, 0, 0, clrGreen))
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

// type = OP_BUY, OP_SELL, or NO_SIGNAL for both.
int CountPositions(int type)
{
   int count = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsOurs()) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (type == NO_SIGNAL || OrderType() == type) count++;
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
