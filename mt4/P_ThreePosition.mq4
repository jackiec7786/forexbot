//+------------------------------------------------------------------+
//|                                            P_ThreePosition.mq4   |
//|  P's XAU/USD three-position method, built from the original      |
//|  handoff (v1.0, Oct 18, 2026) only. No added exit rules.         |
//|                                                                  |
//|  BUY example (SELL is the mirror image):                         |
//|   1. Trend up (price above its level 30 min and 2 h ago): open   |
//|      Position 1, 0.04 lots. No stop.                             |
//|   2. Position 1 +$3: stop Position 1 at its entry + $0.50, and   |
//|      once MT4 accepts it, open Position 2 (0.08).                |
//|   3. Position 2 +$3: move both stops to Position 2's entry +     |
//|      $0.50, and once accepted, open Position 3 (0.10).           |
//|   4. Position 3 +$3: all stops to Position 3's entry + $0.50.    |
//|      Then every further $0.90, raise all stops $0.30.            |
//|   5. Session: +25% of the day's starting balance closes all.     |
//|  Stops are never negative and never move backward. Never add to  |
//|  a losing position. No fourth position.                          |
//|                                                                  |
//|  Not in P's rules, so NOT in this EA: a stop before a position   |
//|  is in profit, an exit when the trend turns, closing a leftover  |
//|  position, a daily loss limit. A losing position is held.        |
//+------------------------------------------------------------------+
#property strict
#property description "P's three-position method from the original handoff. No losing-side stops: a losing position is held."

input string          _s1 = "===== Trend (line graph) =====";
input ENUM_TIMEFRAMES TrendTimeframe    = PERIOD_M5;
input int             TrendShortMinutes = 30;    // Price beyond its level this many minutes ago...
input int             TrendLongMinutes  = 120;   // ...and this many (P: watch 30 min to 2 h)

input string _s2 = "===== Positions =====";
input double Lots1 = 0.04;   // Position 1 (always the smallest)
input double Lots2 = 0.08;   // Position 2
input double Lots3 = 0.10;   // Position 3

input string _s3 = "===== Profit stops =====";
input double StepDollars   = 3.0;   // "Comfortable / healthy profit": move before each stage
input double BufferDollars = 0.50;  // "Slightly above": stop distance past the newest entry
input double TrailEvery    = 0.90;  // With all three protected: every this many dollars...
input double TrailBy       = 0.30;  // ...raise all stops by this much

input string _s4 = "===== Session =====";
input double SessionProfitStopPercent = 25.0;  // Close everything and stop for the day at this gain

input string _s5 = "===== General =====";
input double MaxSpreadDollars = 0.60;
input int    MagicNumber      = 444444;
input int    SlippagePoints   = 30;

#define NONE -1

long     gLastBarTried  = 0;
datetime gLastStageTry  = 0;
datetime gLastTickLocal = 0;
string   gStatus = "Starting up";
string   gKeyDay, gKeyStart, gKeyLocked;

//+------------------------------------------------------------------+
int OnInit()
{
   string sym = Symbol();
   StringToUpper(sym);
   if (StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
   {
      Alert("P_ThreePosition only runs on a gold (XAUUSD) chart. This chart is ", Symbol(), ".");
      return INIT_FAILED;
   }
   int tf = PeriodSeconds(TrendTimeframe) / 60;
   if (tf <= 0 || TrendShortMinutes < tf || TrendLongMinutes <= TrendShortMinutes ||
       TrendShortMinutes % tf != 0 || TrendLongMinutes % tf != 0 ||
       StepDollars <= 0 || BufferDollars <= 0 || BufferDollars >= StepDollars ||
       TrailEvery <= 0 || TrailBy < 0)
   {
      Print("Invalid inputs. Check trend minutes and the stop settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   string prefix = "P3_" + IntegerToString(AccountNumber()) + "_" + IntegerToString(MagicNumber) + "_" + Symbol() + "_";
   gKeyDay = prefix + "day";
   gKeyStart = prefix + "start";
   gKeyLocked = prefix + "locked";

   gLastTickLocal = TimeLocal();
   if (!IsTesting()) EventSetTimer(10);
   ShowStatus();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   int quiet = (int)(TimeLocal() - gLastTickLocal);
   if (quiet >= 120)
   {
      gStatus = "No price updates for " + IntegerToString(quiet / 60) + " min. Market closed or no connection.";
      ShowStatus();
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   gLastTickLocal = TimeLocal();
   Run();
   ShowStatus();
}

void Run()
{
   if (!IsTradeAllowed()) { gStatus = "Trading is OFF. Turn on AutoTrading and 'Allow live trading'."; return; }
   if (!SessionOpen())    { gStatus = "Done for today: +" + DoubleToString(SessionProfitStopPercent, 0) + "% session stop reached."; return; }

   int type  = OpenDirection();
   int stage = HighestStage(type);

   if (type == NONE)
   {
      TryPosition1();
      return;
   }

   gStatus = "Managing " + (type == OP_BUY ? "BUY" : "SELL") + " stack, highest position " + IntegerToString(stage) + ".";
   AdvanceStage(type, stage);
}

//+------------------------------------------------------------------+
//| Session: from the broker day's opening balance                   |
//+------------------------------------------------------------------+
bool SessionOpen()
{
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if (!GlobalVariableCheck(gKeyDay) || (datetime)GlobalVariableGet(gKeyDay) != today)
   {
      GlobalVariableSet(gKeyDay, (double)today);
      GlobalVariableSet(gKeyStart, AccountBalance());
      GlobalVariableSet(gKeyLocked, 0);
   }
   if (GlobalVariableGet(gKeyLocked) > 0) return false;

   if (SessionProfitStopPercent > 0 &&
       AccountEquity() >= GlobalVariableGet(gKeyStart) * (1.0 + SessionProfitStopPercent / 100.0))
   {
      Print("Session profit stop reached. Closing all positions for today.");
      CloseAll();
      GlobalVariableSet(gKeyLocked, 1);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Trend: closed bars, price beyond its level 30 min AND 2 h ago    |
//+------------------------------------------------------------------+
int Trend()
{
   int tf = PeriodSeconds(TrendTimeframe) / 60;
   double now  = iClose(Symbol(), TrendTimeframe, 1);
   double s    = iClose(Symbol(), TrendTimeframe, 1 + TrendShortMinutes / tf);
   double l    = iClose(Symbol(), TrendTimeframe, 1 + TrendLongMinutes / tf);
   if (now <= 0 || s <= 0 || l <= 0) return NONE;
   if (now > s && now > l) return OP_BUY;
   if (now < s && now < l) return OP_SELL;
   return NONE;
}

//+------------------------------------------------------------------+
//| Position 1                                                       |
//+------------------------------------------------------------------+
void TryPosition1()
{
   long bar = (long)iTime(Symbol(), TrendTimeframe, 1);
   if (bar == 0) { gStatus = "Loading 5-minute price history."; return; }
   if (bar == gLastBarTried) { gStatus = "Waiting for the next 5-minute bar."; return; }

   int t = Trend();
   if (t == NONE) { gStatus = "No clear trend (30 min and 2 h disagree). WAIT."; return; }
   if (!SpreadOk()) { gStatus = "Trend found, spread too wide. Waiting."; return; }

   gLastBarTried = bar;
   if (Open(t, 1)) gStatus = "Opened Position 1 " + (t == OP_BUY ? "BUY" : "SELL") + ".";
}

//+------------------------------------------------------------------+
//| Stages: at each +$Step beyond the newest entry, protect every    |
//| open position at newest entry + Buffer, then (stages 1-2) add    |
//| the next position once MT4 has accepted the stops. With Position |
//| 3 protected, trail: +TrailBy for every TrailEvery further move.  |
//+------------------------------------------------------------------+
void AdvanceStage(int type, int stage)
{
   if (stage < 1) return;   // only positions without a stage label: hold them

   RefreshRates();
   double price = (type == OP_BUY) ? Bid : Ask;
   double front = NewestEntry(type, stage);
   double moved = (type == OP_BUY) ? price - front : front - price;
   if (moved < StepDollars) return;   // stage not reached yet: no new stop, no new position

   double offset = BufferDollars;
   if (stage >= 3)
      offset += MathFloor((moved - StepDollars) / TrailEvery) * TrailBy;
   double target = NormalizeDouble((type == OP_BUY) ? front + offset : front - offset, Digits);

   SetStopsTo(type, target);

   if (stage >= 3) return;
   if (!AllAtOrBeyond(type, target)) { gStatus = "Stops not accepted yet. Next position waits."; return; }
   if (!AllInProfit()) return;           // never add to a losing position
   if (TimeCurrent() < gLastStageTry + 60) return;
   if (!SpreadOk()) return;

   gLastStageTry = TimeCurrent();
   if (Open(type, stage + 1))
      gStatus = "Protected the stack and opened Position " + IntegerToString(stage + 1) + ".";
}

// Move every position's stop to target, only if that tightens it and it is in profit.
void SetStopsTo(int type, double target)
{
   RefreshRates();
   double price   = (type == OP_BUY) ? Bid : Ask;
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if ((type == OP_BUY && price - target < minDist) || (type == OP_SELL && target - price < minDist)) return;

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !Ours() || OrderType() != type) continue;
      bool inProfit = (type == OP_BUY) ? target > OrderOpenPrice() : target < OrderOpenPrice();
      bool tighter  = OrderStopLoss() == 0 ||
                      ((type == OP_BUY) ? target > OrderStopLoss() + Point / 2 : target < OrderStopLoss() - Point / 2);
      if (inProfit && tighter && !OrderModify(OrderTicket(), OrderOpenPrice(), target, 0, 0, clrGreen))
         Print("Stop update failed on ticket ", OrderTicket(), ". Error ", GetLastError());
   }
}

bool Open(int type, int stage)
{
   double lots = (stage == 1) ? Lots1 : (stage == 2) ? Lots2 : Lots3;
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (step > 0) lots = NormalizeDouble(MathFloor(lots / step + 1e-9) * step, 2);
   if (lots < MarketInfo(Symbol(), MODE_MINLOT) || lots > MarketInfo(Symbol(), MODE_MAXLOT))
   {
      gStatus = "Position " + IntegerToString(stage) + " size not allowed by the broker. Skipped.";
      return false;
   }

   ResetLastError();
   if (AccountFreeMarginCheck(Symbol(), type, lots) <= 0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   {
      gStatus = "Position " + IntegerToString(stage) + " skipped: not enough margin for " + DoubleToString(lots, 2) + " lots.";
      Print(gStatus);
      return false;
   }

   RefreshRates();
   double price = (type == OP_BUY) ? Ask : Bid;
   string tag   = "Pos " + IntegerToString(stage);
   int ticket = OrderSend(Symbol(), type, lots, price, SlippagePoints, 0, 0, tag, MagicNumber, 0,
                          type == OP_BUY ? clrBlue : clrRed);
   if (ticket < 0)
   {
      int err = GetLastError();
      gStatus = tag + " rejected by the broker. Error " + IntegerToString(err) + ".";
      Print(gStatus);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool Ours() { return OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber; }

bool SpreadOk() { RefreshRates(); return (Ask - Bid) <= MaxSpreadDollars; }

int StageOf()
{
   string c = OrderComment();
   if (StringFind(c, "Pos 1") == 0) return 1;
   if (StringFind(c, "Pos 2") == 0) return 2;
   if (StringFind(c, "Pos 3") == 0) return 3;
   if (MathAbs(OrderLots() - Lots1) < 0.0001) return 1;   // if a broker drops comments
   if (MathAbs(OrderLots() - Lots2) < 0.0001) return 2;
   if (MathAbs(OrderLots() - Lots3) < 0.0001) return 3;
   return 0;
}

// Direction of our open positions, or NONE if flat.
int OpenDirection()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && Ours() && (OrderType() == OP_BUY || OrderType() == OP_SELL))
         return OrderType();
   return NONE;
}

int HighestStage(int type)
{
   int best = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && Ours() && OrderType() == type)
         best = MathMax(best, StageOf());
   return best;
}

double NewestEntry(int type, int stage)
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && Ours() && OrderType() == type && StageOf() == stage)
         return OrderOpenPrice();
   return 0;
}

bool AllAtOrBeyond(int type, double target)
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !Ours() || OrderType() != type) continue;
      double sl = OrderStopLoss();
      if (sl == 0) return false;
      if (type == OP_BUY  && sl < target - Point / 2) return false;
      if (type == OP_SELL && sl > target + Point / 2) return false;
   }
   return true;
}

bool AllInProfit()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && Ours())
         if (OrderProfit() + OrderSwap() + OrderCommission() <= 0) return false;
   return true;
}

void CloseAll()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !Ours()) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      RefreshRates();
      if (!OrderClose(OrderTicket(), OrderLots(), OrderType() == OP_BUY ? Bid : Ask, SlippagePoints, clrWhite))
         Print("Close failed on ticket ", OrderTicket(), ". Error ", GetLastError());
   }
}

void ShowStatus()
{
   if (IsTesting() && !IsVisualMode()) return;
   int t = Trend();
   double start = GlobalVariableCheck(gKeyStart) ? GlobalVariableGet(gKeyStart) : AccountBalance();
   double day = (start > 0) ? (AccountEquity() / start - 1.0) * 100.0 : 0;
   Comment("P's three-position method (original handoff)\n",
           "AutoTrading: ", (IsTradeAllowed() ? "ON" : "OFF"), "\n",
           "Trend (30 min & 2 h): ", (t == OP_BUY ? "UP (buy)" : t == OP_SELL ? "DOWN (sell)" : "unclear (wait)"), "\n",
           "Spread: $", DoubleToString(Ask - Bid, 2), "\n",
           "Today: ", DoubleToString(day, 2), "%  (session stop +", DoubleToString(SessionProfitStopPercent, 0), "%)\n",
           "Status: ", gStatus);
}
//+------------------------------------------------------------------+
