//+------------------------------------------------------------------+
//|                                   GoldScalper_SR_Bounce.mq5     |
//|                     Gold S/R Bounce Scalper EA                   |
//|                                                                  |
//|  ALGORITHM SUMMARY                                               |
//|  ─────────────────                                               |
//|  1. Build S/R levels: previous-day H/L, round numbers,          |
//|     swing H/L from 15-min chart (or user-supplied CSV levels).  |
//|  2. On every new closed bar, check bar[1] for three patterns:   |
//|     a) Pin bar       – wick ≥ PinBarWickRatio × body            |
//|     b) Engulfing     – fully engulfs previous bar incl. wicks   |
//|     c) Inside bar    – bar[1] inside bar[2]; then wait for      |
//|                        tick-level price break                    |
//|  3. Pattern candle (or mother-bar for inside bar) must have     |
//|     its low/high within LevelTouchPips of a S/R level.          |
//|  4. SL = level ± stop-distance (fixed-pip or ATR-based).        |
//|     TP = entry ± actualStopDist × RiskRewardRatio.              |
//|  5. Trailing stop activates after TrailingStopActivationPips     |
//|     of profit and trails by TrailingStopDistancePips.           |
//|  6. Session filter, MaxTradesPerDay, and MaxConsecutiveLosses   |
//|     gate protect the account.                                    |
//+------------------------------------------------------------------+
#property copyright "GoldScalper_SR_Bounce"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//==========================================================================
// ██ INPUTS
//==========================================================================

//--- Trading Sessions (server/broker time)
input group "=== Trading Sessions (Server Time) ==="
input string   Session1Start                = "08:00";  // London session start
input string   Session1End                  = "10:00";  // London session end
input string   Session2Start                = "13:00";  // NY session start
input string   Session2End                  = "15:00";  // NY session end
input bool     UseSessionFilter             = true;     // Restrict trading to sessions above

//--- Risk & Reward
input group "=== Risk & Reward ==="
input double   RiskRewardRatio              = 1.0;      // TP distance = SL distance × this
input double   StopDistancePips             = 10.0;     // Fixed stop distance in pips
input double   PipSize                      = 0.10;     // 1 pip in price units (0.10 for XAUUSD)
input double   TrailingStopActivationPips   = 15.0;     // Profit in pips before trailing activates (0=off)
input double   TrailingStopDistancePips     = 5.0;      // Trailing distance in pips once active

//--- Trade Limits
input group "=== Trade Limits ==="
input int      MaxTradesPerDay              = 10;       // Max trades opened per calendar day
input int      MaxConsecutiveLosses         = 3;        // Halt after this many consecutive losses
input bool     ResetAfterManualIntervention = true;     // false = persist halt via GlobalVariable across restarts

//--- Lot Sizing
input group "=== Lot Sizing ==="
input double   ManualLotSize                = 0.0;      // >0 = fixed lot; 0 = automatic
input int      RiskType                     = 0;        // 0 = % of balance, 1 = fixed USD amount
input double   RiskPercent                  = 1.0;      // % of balance to risk (if RiskType=0)
input double   RiskAmountUSD                = 50.0;     // Fixed monetary risk (if RiskType=1)
input int      StopDistanceSource           = 0;        // 0 = StopDistancePips, 1 = ATR × multiplier
input double   ATR_Stop_Multiplier          = 1.5;      // ATR multiplier for stop (StopDistanceSource=1)
input double   SameDirectionLotMultiplier   = 1.0;      // Multiply lot when consecutive same-dir (1.0=unchanged)

//--- Support / Resistance Levels
input group "=== Support/Resistance Levels ==="
input bool     UseAutoLevels                = true;     // Auto-detect levels (false = use manual CSV)
input string   ManualSupportStr             = "2650.00,2645.00";    // Comma-separated support prices
input string   ManualResistanceStr          = "2655.00,2660.00";    // Comma-separated resistance prices
input double   LevelTouchPips               = 0.5;      // Tolerance in pips to consider price "at level"
input int      AutoLevelLookbackBars        = 100;      // Bars on M15 chart for swing detection
input double   RoundNumberStep              = 5.0;      // Round-number interval (e.g., every $5.00)
input int      RoundNumberRange             = 10;       // How many round levels above/below price

//--- Pattern Detection
input group "=== Pattern Detection ==="
input double   PinBarWickRatio              = 2.0;      // Lower/upper wick must be >= this × body
input bool     UseInsideBar                 = true;     // Enable inside-bar breakout signal
input int      InsideBarExpireBars          = 3;        // Cancel inside-bar pending after N new bars

//--- General
input group "=== General ==="
input int      MagicNumber                  = 20240401;
input bool     PrintLogs                    = true;

//==========================================================================
// ██ GLOBAL VARIABLES
//==========================================================================

CTrade   trade;

int      h_ATR    = INVALID_HANDLE;   // ATR on signal timeframe (for stop/trail)
int      h_ATR15  = INVALID_HANDLE;   // ATR on M15 (used internally in BuildLevels)

//--- Level arrays
double   g_Support[];     // Support levels (buy zone)
double   g_Resist[];      // Resistance levels (sell zone)

//--- Daily state
datetime g_TodayMidnight    = 0;
int      g_TradesToday      = 0;
int      g_ConsecLosses     = 0;
bool     g_Halted           = false;
string   g_HaltKey;               // GlobalVariable name for persisting halt state

//--- Direction tracking (for SameDirectionLotMultiplier)
int      g_LastDir          = 0;  // 1=last was long, -1=last was short, 0=none

//--- Inside Bar pending state (tick-level breakout entry)
bool     g_IB_BullActive    = false;
bool     g_IB_BearActive    = false;
double   g_IB_BullTrigger   = 0;  // Ask must exceed this to trigger long
double   g_IB_BearTrigger   = 0;  // Bid must fall below this to trigger short
double   g_IB_BullSL        = 0;  // Pre-calculated SL price for IB long
double   g_IB_BearSL        = 0;  // Pre-calculated SL price for IB short
int      g_IB_BarsLeft      = 0;  // Countdown: cancel when it reaches 0

//--- New-bar time gate
static datetime g_LastBarTime = 0;

//==========================================================================
// ██ OnInit
//==========================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(DetectFillMode());   // Broker-safe fill mode detection

   //--- Indicator handles
   h_ATR   = iATR(_Symbol, PERIOD_CURRENT, 14);
   h_ATR15 = iATR(_Symbol, PERIOD_M15,     14);
   if(h_ATR == INVALID_HANDLE || h_ATR15 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handles.");
      return INIT_FAILED;
   }

   //--- Halt persistence: if ResetAfterManualIntervention=false, halt survives re-attach
   g_HaltKey = StringFormat("GSB_Halt_%s_%d", _Symbol, MagicNumber);
   if(!ResetAfterManualIntervention && GlobalVariableCheck(g_HaltKey))
      g_Halted = (GlobalVariableGet(g_HaltKey) > 0.5);
   // If ResetAfterManualIntervention=true, g_Halted stays false (reset by re-attaching)

   BuildLevels();

   if(PrintLogs)
      PrintFormat("GoldScalper_SR_Bounce | %s %s | Pip=%.2f | S=%d R=%d | Halt=%s",
                  _Symbol, EnumToString(PERIOD_CURRENT), PipSize,
                  ArraySize(g_Support), ArraySize(g_Resist),
                  g_Halted ? "YES" : "NO");
   return INIT_SUCCEEDED;
}

//==========================================================================
// ██ OnDeinit
//==========================================================================
void OnDeinit(const int reason)
{
   if(h_ATR   != INVALID_HANDLE) IndicatorRelease(h_ATR);
   if(h_ATR15 != INVALID_HANDLE) IndicatorRelease(h_ATR15);
}

//==========================================================================
// ██ DetectFillMode
// Queries broker support for FOK → IOC → RETURN fallback
//==========================================================================
ENUM_ORDER_TYPE_FILLING DetectFillMode()
{
   uint fm = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//==========================================================================
// ██ OnTick
//==========================================================================
void OnTick()
{
   //--- 1. Trailing stop: must run on every tick for tight trailing
   RunTrailingStop();

   //--- 2. Inside bar breakout: intrabar tick-level entry
   RunInsideBarCheck();

   //--- 3. New bar gate: all signal logic runs once per closed bar only
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   //--- 4. New-day reset: trade counter and level rebuild
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(today != g_TodayMidnight)
   {
      g_TodayMidnight = today;
      g_TradesToday   = 0;
      BuildLevels();   // Rebuild on new day to capture new prev-day H/L
      if(PrintLogs) Print("New day: trade counter reset, levels rebuilt.");
   }

   //--- 5. Decrement inside bar expiry counter (set to InsideBarExpireBars when armed)
   if(g_IB_BullActive || g_IB_BearActive)
   {
      if(--g_IB_BarsLeft <= 0)
      {
         if(PrintLogs) Print("InsideBar pending expired (bar timeout).");
         ClearIB();
      }
   }

   //--- 6. Guard conditions: halt, daily cap, session, existing position
   if(g_Halted)
   {
      if(PrintLogs) Print("EA HALTED. Consecutive loss limit hit. Manual reset required.");
      return;
   }
   if(g_TradesToday >= MaxTradesPerDay)
   {
      if(PrintLogs) PrintFormat("Daily cap reached (%d trades).", MaxTradesPerDay);
      return;
   }
   if(UseSessionFilter && !IsInSession())
   {
      ClearIB();   // Don't hold stale inside bar signals across session gap
      return;
   }
   if(CountPositions() > 0) return;   // One position at a time

   //--- 7. Fetch last two fully-closed candles (shift 1 = last closed, shift 2 = prior)
   double o1 = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double l1 = iLow  (_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double o2 = iOpen (_Symbol, PERIOD_CURRENT, 2);
   double h2 = iHigh (_Symbol, PERIOD_CURRENT, 2);
   double l2 = iLow  (_Symbol, PERIOD_CURRENT, 2);
   double c2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   if(c1 == 0 || c2 == 0) return;   // Insufficient bar data

   //--- 8. ATR from last closed bar (shift 1) for stop/lot calculations
   double atrBuf[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, atrBuf) < 1) return;
   double atr = atrBuf[0];

   //--- 9. Evaluate bullish and bearish setups
   CheckLong (o1, h1, l1, c1, o2, h2, l2, c2, atr);
   CheckShort(o1, h1, l1, c1, o2, h2, l2, c2, atr);
}

//==========================================================================
// ██ OnTradeTransaction
// Tracks opened trades (count) and closed trades (profit for loss streak)
//==========================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal))           return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;

   ENUM_DEAL_ENTRY ent = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   //--- Trade opened: increment today's count and record direction
   if(ent == DEAL_ENTRY_IN)
   {
      g_TradesToday++;
      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      g_LastDir = (dtype == DEAL_TYPE_BUY) ? 1 : -1;
      if(PrintLogs)
         PrintFormat("Trade #%d opened | Dir=%s | Today=%d",
                     (int)trans.deal, (g_LastDir == 1) ? "LONG" : "SHORT", g_TradesToday);
   }

   //--- Trade closed: evaluate profit and update consecutive loss counter
   else if(ent == DEAL_ENTRY_OUT || ent == DEAL_ENTRY_INOUT)
   {
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
      if(pnl < 0.0)
      {
         g_ConsecLosses++;
         if(PrintLogs)
            PrintFormat("Loss (%.2f). Consecutive losses: %d/%d", pnl, g_ConsecLosses, MaxConsecutiveLosses);

         if(g_ConsecLosses >= MaxConsecutiveLosses)
         {
            g_Halted = true;
            //--- Persist halt state if ResetAfterManualIntervention = false
            if(!ResetAfterManualIntervention)
               GlobalVariableSet(g_HaltKey, 1.0);
            PrintFormat(">>> EA HALTED after %d consecutive losses. Manual reset required.", MaxConsecutiveLosses);
         }
      }
      else
      {
         if(g_ConsecLosses > 0 && PrintLogs)
            PrintFormat("Win (%.2f). Consecutive loss streak reset.", pnl);
         g_ConsecLosses = 0;
      }
   }
}

//==========================================================================
// ██ CheckLong  –  Bullish signal evaluation (runs once per bar)
// Checks bar[1] for:
//   1. Bullish pin bar with LOW near support
//   2. Bullish engulfing with LOW near support
//   3. Inside bar (bar[1] inside bar[2]) with either bar's LOW near support
//==========================================================================
void CheckLong(double o1, double h1, double l1, double c1,
               double o2, double h2, double l2, double c2, double atr)
{
   bool sameDir = (g_LastDir == 1);   // For lot multiplier logic

   //--- Pattern A: Bullish Pin Bar
   //    Bar[1] low must be within LevelTouchPips of a support level
   double lvl = 0;
   if(IsNearSupport(l1, lvl) && IsBullPinBar(o1, h1, l1, c1))
   {
      if(PrintLogs) PrintFormat("LONG SIGNAL: Bullish Pin Bar | Support=%.2f", lvl);
      ExecLong(lvl, atr, sameDir);
      return;
   }

   //--- Pattern B: Bullish Engulfing
   //    Engulfing bar's (bar[1]) low engulfs and reaches support level
   if(IsNearSupport(l1, lvl) && IsBullEngulf(o1, h1, l1, c1, o2, h2, l2, c2))
   {
      if(PrintLogs) PrintFormat("LONG SIGNAL: Bullish Engulfing | Support=%.2f", lvl);
      ExecLong(lvl, atr, sameDir);
      return;
   }

   //--- Pattern C: Inside Bar (set pending tick-level breakout)
   //    Inside bar (bar[1]) must be inside mother bar (bar[2]).
   //    Either bar's LOW touching support is acceptable.
   if(UseInsideBar && IsInsideBar(h1, l1, h2, l2) && !g_IB_BullActive)
   {
      double lvlFromBar1 = 0, lvlFromBar2 = 0;
      bool nearBar1 = IsNearSupport(l1, lvlFromBar1);
      bool nearBar2 = IsNearSupport(l2, lvlFromBar2);

      if(nearBar1 || nearBar2)
      {
         double ibLvl    = nearBar1 ? lvlFromBar1 : lvlFromBar2;
         double stopDist = CalcStopDist(atr);

         g_IB_BullActive  = true;
         g_IB_BullTrigger = h1;   // Enter when Ask breaks ABOVE inside bar HIGH
         g_IB_BullSL      = NormalizeDouble(ibLvl - stopDist, _Digits);
         g_IB_BarsLeft    = InsideBarExpireBars;

         if(PrintLogs)
            PrintFormat("LONG PENDING (InsideBar) | Support=%.2f Trigger=%.5f SL=%.5f Expires in %d bars",
                        ibLvl, h1, g_IB_BullSL, InsideBarExpireBars);
      }
   }
}

//==========================================================================
// ██ CheckShort  –  Bearish signal evaluation (runs once per bar)
// Mirror logic of CheckLong at resistance levels.
//==========================================================================
void CheckShort(double o1, double h1, double l1, double c1,
                double o2, double h2, double l2, double c2, double atr)
{
   bool sameDir = (g_LastDir == -1);

   //--- Pattern A: Bearish Pin Bar
   double lvl = 0;
   if(IsNearResist(h1, lvl) && IsBearPinBar(o1, h1, l1, c1))
   {
      if(PrintLogs) PrintFormat("SHORT SIGNAL: Bearish Pin Bar | Resistance=%.2f", lvl);
      ExecShort(lvl, atr, sameDir);
      return;
   }

   //--- Pattern B: Bearish Engulfing
   if(IsNearResist(h1, lvl) && IsBearEngulf(o1, h1, l1, c1, o2, h2, l2, c2))
   {
      if(PrintLogs) PrintFormat("SHORT SIGNAL: Bearish Engulfing | Resistance=%.2f", lvl);
      ExecShort(lvl, atr, sameDir);
      return;
   }

   //--- Pattern C: Inside Bar at Resistance (pending tick-level breakdown)
   if(UseInsideBar && IsInsideBar(h1, l1, h2, l2) && !g_IB_BearActive)
   {
      double lvlFromBar1 = 0, lvlFromBar2 = 0;
      bool nearBar1 = IsNearResist(h1, lvlFromBar1);
      bool nearBar2 = IsNearResist(h2, lvlFromBar2);

      if(nearBar1 || nearBar2)
      {
         double ibLvl    = nearBar1 ? lvlFromBar1 : lvlFromBar2;
         double stopDist = CalcStopDist(atr);

         g_IB_BearActive  = true;
         g_IB_BearTrigger = l1;  // Enter when Bid breaks BELOW inside bar LOW
         g_IB_BearSL      = NormalizeDouble(ibLvl + stopDist, _Digits);
         g_IB_BarsLeft    = InsideBarExpireBars;

         if(PrintLogs)
            PrintFormat("SHORT PENDING (InsideBar) | Resistance=%.2f Trigger=%.5f SL=%.5f Expires in %d bars",
                        ibLvl, l1, g_IB_BearSL, InsideBarExpireBars);
      }
   }
}

//==========================================================================
// ██ RunInsideBarCheck  –  Runs on EVERY tick
// Monitors live Ask/Bid for inside bar breakout/breakdown triggers.
// SL was pre-calculated at signal detection time (level ± stopDist).
//==========================================================================
void RunInsideBarCheck()
{
   if(!g_IB_BullActive && !g_IB_BearActive) return;

   //--- If a position opened from another signal, clear stale pending IB
   if(CountPositions() > 0) { ClearIB(); return; }

   //--- Respect halt and daily cap (but do not decrement bar counter here –
   //    that happens in the new-bar gate in OnTick)
   if(g_Halted || g_TradesToday >= MaxTradesPerDay) return;
   if(UseSessionFilter && !IsInSession()) return;

   //--- Bullish inside bar breakout: Ask > inside bar high
   if(g_IB_BullActive)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > g_IB_BullTrigger)
      {
         double actualSD = ask - g_IB_BullSL;
         if(actualSD <= 0) { if(PrintLogs) Print("IB LONG: SL >= entry. Skipped."); ClearIB(); return; }

         double tp   = NormalizeDouble(ask + actualSD * RiskRewardRatio, _Digits);
         double lots = CalcLots(actualSD, g_LastDir == 1);

         if(PrintLogs)
            PrintFormat("IB LONG triggered | Ask=%.5f SL=%.5f TP=%.5f Lots=%.2f",
                        ask, g_IB_BullSL, tp, lots);

         if(!trade.Buy(lots, _Symbol, 0, g_IB_BullSL, tp, "IB_LONG"))
            if(PrintLogs)
               PrintFormat("IB LONG failed | Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());

         ClearIB();
      }
   }

   //--- Bearish inside bar breakdown: Bid < inside bar low
   if(g_IB_BearActive)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid < g_IB_BearTrigger)
      {
         double actualSD = g_IB_BearSL - bid;
         if(actualSD <= 0) { if(PrintLogs) Print("IB SHORT: SL <= entry. Skipped."); ClearIB(); return; }

         double tp   = NormalizeDouble(bid - actualSD * RiskRewardRatio, _Digits);
         double lots = CalcLots(actualSD, g_LastDir == -1);

         if(PrintLogs)
            PrintFormat("IB SHORT triggered | Bid=%.5f SL=%.5f TP=%.5f Lots=%.2f",
                        bid, g_IB_BearSL, tp, lots);

         if(!trade.Sell(lots, _Symbol, 0, g_IB_BearSL, tp, "IB_SHORT"))
            if(PrintLogs)
               PrintFormat("IB SHORT failed | Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());

         ClearIB();
      }
   }
}

//--- Clear all inside bar pending state
void ClearIB()
{
   g_IB_BullActive = g_IB_BearActive = false;
   g_IB_BullTrigger = g_IB_BearTrigger = 0;
   g_IB_BullSL = g_IB_BearSL = 0;
   g_IB_BarsLeft = 0;
}

//==========================================================================
// ██ ExecLong / ExecShort
// Market order execution for pin bar and engulfing signals.
// SL is placed StopDistance beyond the level; TP uses actual entry-SL dist × RRR.
//==========================================================================
void ExecLong(double supportLvl, double atr, bool sameDir)
{
   double stopDist = CalcStopDist(atr);
   double sl       = NormalizeDouble(supportLvl - stopDist, _Digits);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double actualSD = ask - sl;    // Actual distance from live Ask to SL

   if(actualSD <= 0)
   {
      if(PrintLogs) PrintFormat("LONG skipped: SL(%.5f) >= Ask(%.5f).", sl, ask);
      return;
   }

   double tp   = NormalizeDouble(ask + actualSD * RiskRewardRatio, _Digits);
   double lots = CalcLots(actualSD, sameDir);

   if(PrintLogs)
      PrintFormat("Exec LONG | Ask=%.5f SL=%.5f TP=%.5f Lots=%.2f | StopDist=%.5f",
                  ask, sl, tp, lots, actualSD);

   if(!trade.Buy(lots, _Symbol, 0, sl, tp, "SR_LONG"))
      if(PrintLogs)
         PrintFormat("LONG failed | Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
}

void ExecShort(double resistLvl, double atr, bool sameDir)
{
   double stopDist = CalcStopDist(atr);
   double sl       = NormalizeDouble(resistLvl + stopDist, _Digits);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double actualSD = sl - bid;

   if(actualSD <= 0)
   {
      if(PrintLogs) PrintFormat("SHORT skipped: SL(%.5f) <= Bid(%.5f).", sl, bid);
      return;
   }

   double tp   = NormalizeDouble(bid - actualSD * RiskRewardRatio, _Digits);
   double lots = CalcLots(actualSD, sameDir);

   if(PrintLogs)
      PrintFormat("Exec SHORT | Bid=%.5f SL=%.5f TP=%.5f Lots=%.2f | StopDist=%.5f",
                  bid, sl, tp, lots, actualSD);

   if(!trade.Sell(lots, _Symbol, 0, sl, tp, "SR_SHORT"))
      if(PrintLogs)
         PrintFormat("SHORT failed | Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
}

//==========================================================================
// ██ RunTrailingStop  –  Runs on EVERY tick
// Activates after profit >= TrailingStopActivationPips.
// Trails by TrailingStopDistancePips. SL only moves in trade's favour.
//==========================================================================
void RunTrailingStop()
{
   if(TrailingStopActivationPips <= 0) return;   // Feature disabled

   double actDist   = TrailingStopActivationPips * PipSize;
   double trailDist = TrailingStopDistancePips   * PipSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      ENUM_POSITION_TYPE pType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(pType == POSITION_TYPE_BUY)
      {
         //--- Activate only once profit threshold is reached
         if(bid - openPrice < actDist) continue;
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         //--- Only improve SL (never move against trade)
         if(newSL > curSL + _Point)
         {
            if(PrintLogs) PrintFormat("Trail BUY #%d: SL %.5f → %.5f", ticket, curSL, newSL);
            trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(pType == POSITION_TYPE_SELL)
      {
         if(openPrice - ask < actDist) continue;
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < curSL - _Point)
         {
            if(PrintLogs) PrintFormat("Trail SELL #%d: SL %.5f → %.5f", ticket, curSL, newSL);
            trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//==========================================================================
// ██ PATTERN DETECTION
//==========================================================================

//--- Bullish Pin Bar: lower wick ≥ PinBarWickRatio × body, close above midpoint
bool IsBullPinBar(double o, double h, double l, double c)
{
   double body    = MathAbs(c - o);
   if(body < _Point) return false;   // Doji: not a pin bar
   double loWick  = MathMin(o, c) - l;
   double midpoint = l + (h - l) * 0.5;
   return (loWick >= PinBarWickRatio * body) && (c > midpoint);
}

//--- Bearish Pin Bar: upper wick ≥ PinBarWickRatio × body, close below midpoint
bool IsBearPinBar(double o, double h, double l, double c)
{
   double body    = MathAbs(c - o);
   if(body < _Point) return false;
   double hiWick  = h - MathMax(o, c);
   double midpoint = l + (h - l) * 0.5;
   return (hiWick >= PinBarWickRatio * body) && (c < midpoint);
}

//--- Bullish Engulfing: green bar completely engulfs prior red bar (body + wicks)
bool IsBullEngulf(double o, double h, double l, double c,
                   double po, double ph, double pl, double pc)
{
   bool curGreen  = (c > o);
   bool prevRed   = (pc < po);
   bool engulfs   = (h >= ph) && (l <= pl);
   return curGreen && prevRed && engulfs;
}

//--- Bearish Engulfing: red bar completely engulfs prior green bar (body + wicks)
bool IsBearEngulf(double o, double h, double l, double c,
                   double po, double ph, double pl, double pc)
{
   bool curRed    = (c < o);
   bool prevGreen = (pc > po);
   bool engulfs   = (h >= ph) && (l <= pl);
   return curRed && prevGreen && engulfs;
}

//--- Inside Bar: current bar's range is contained within prior bar's range
bool IsInsideBar(double curH, double curL, double prevH, double prevL)
{
   return (curH < prevH) && (curL > prevL);
}

//==========================================================================
// ██ LEVEL PROXIMITY CHECKS
//==========================================================================

//--- Returns true if 'price' is within LevelTouchPips of any support level.
//    Sets 'foundLvl' to the nearest matching level.
bool IsNearSupport(double price, double &foundLvl)
{
   double tol = LevelTouchPips * PipSize;
   for(int i = 0; i < ArraySize(g_Support); i++)
   {
      if(MathAbs(price - g_Support[i]) <= tol)
      {
         foundLvl = g_Support[i];
         return true;
      }
   }
   return false;
}

//--- Returns true if 'price' is within LevelTouchPips of any resistance level.
bool IsNearResist(double price, double &foundLvl)
{
   double tol = LevelTouchPips * PipSize;
   for(int i = 0; i < ArraySize(g_Resist); i++)
   {
      if(MathAbs(price - g_Resist[i]) <= tol)
      {
         foundLvl = g_Resist[i];
         return true;
      }
   }
   return false;
}

//==========================================================================
// ██ BUILD LEVELS
// Called on init and once per new trading day.
//==========================================================================
void BuildLevels()
{
   ArrayResize(g_Support, 0);
   ArrayResize(g_Resist,  0);

   if(!UseAutoLevels)
   {
      //--- Manual mode: parse user-supplied CSV strings
      ParseLevels(ManualSupportStr,    g_Support);
      ParseLevels(ManualResistanceStr, g_Resist);
      if(PrintLogs)
         PrintFormat("Manual levels: %d support | %d resistance",
                     ArraySize(g_Support), ArraySize(g_Resist));
      return;
   }

   //--- AUTO LEVEL 1: Previous day's high (resistance) and low (support)
   double pdH = iHigh(_Symbol, PERIOD_D1, 1);
   double pdL = iLow (_Symbol, PERIOD_D1, 1);
   if(pdH > 0) { Append(g_Resist,  pdH); }
   if(pdL > 0) { Append(g_Support, pdL); }
   if(PrintLogs && pdH > 0)
      PrintFormat("PrevDay: H=%.2f (Resist) L=%.2f (Support)", pdH, pdL);

   //--- AUTO LEVEL 2: Round numbers near current price
   //    Add to both arrays – a round number can be either S or R depending on approach direction
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double base = MathFloor(bid / RoundNumberStep) * RoundNumberStep;
   for(int i = -RoundNumberRange; i <= RoundNumberRange; i++)
   {
      double lvl = NormalizeDouble(base + i * RoundNumberStep, 2);
      Append(g_Support, lvl);
      Append(g_Resist,  lvl);
   }

   //--- AUTO LEVEL 3: Swing highs/lows from 15-minute chart
   int barsAvail = iBars(_Symbol, PERIOD_M15);
   int lookback  = MathMin(AutoLevelLookbackBars, barsAvail - 3);

   if(lookback >= 3)
   {
      double swH[], swL[];
      //--- AS_SERIES=true: index 0 = most recent (bar at shift 1 on M15)
      ArraySetAsSeries(swH, true);
      ArraySetAsSeries(swL, true);

      int copied = CopyHigh(_Symbol, PERIOD_M15, 1, lookback + 1, swH);
      int copiedL = CopyLow(_Symbol,  PERIOD_M15, 1, lookback + 1, swL);

      if(copied > 2 && copiedL > 2)
      {
         int sz = MathMin(ArraySize(swH), ArraySize(swL));
         //--- Pivot high: swH[i] > both immediate neighbours (i-1 = more recent, i+1 = older)
         //--- Pivot low:  swL[i] < both immediate neighbours
         for(int i = 1; i < sz - 1; i++)
         {
            if(swH[i] > swH[i-1] && swH[i] > swH[i+1])
               Append(g_Resist, swH[i]);
            if(swL[i] < swL[i-1] && swL[i] < swL[i+1])
               Append(g_Support, swL[i]);
         }
      }
   }

   //--- Deduplicate levels that are within 2× tolerance of each other
   Dedup(g_Support);
   Dedup(g_Resist);

   if(PrintLogs)
      PrintFormat("Auto levels built: %d support | %d resistance",
                  ArraySize(g_Support), ArraySize(g_Resist));
}

//--- Parse a comma-separated price string and append values to arr[]
void ParseLevels(string str, double &arr[])
{
   string parts[];
   int n = StringSplit(str, ',', parts);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringLen(parts[i]) > 0)
         Append(arr, StringToDouble(parts[i]));
   }
}

//--- Append a single value to a dynamic array
void Append(double &arr[], double v)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = v;
}

//--- Remove levels that are within 2 × LevelTouchPips of each other
void Dedup(double &arr[])
{
   int n = ArraySize(arr);
   if(n < 2) return;

   double tol = LevelTouchPips * PipSize * 2.0;
   double tmp[];
   ArrayResize(tmp, n);
   int k = 0;

   for(int i = 0; i < n; i++)
   {
      bool dup = false;
      for(int j = 0; j < k && !dup; j++)
         if(MathAbs(arr[i] - tmp[j]) <= tol) dup = true;
      if(!dup) tmp[k++] = arr[i];
   }

   ArrayResize(arr, k);
   ArrayCopy(arr, tmp, 0, 0, k);
}

//==========================================================================
// ██ LOT SIZING & STOP DISTANCE
//==========================================================================

//--- Compute stop distance in price units based on StopDistanceSource
double CalcStopDist(double atr)
{
   return (StopDistanceSource == 1) ? (atr * ATR_Stop_Multiplier) : (StopDistancePips * PipSize);
}

//--- Calculate lot size with full risk management logic
double CalcLots(double stopDist, bool sameDir)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lots = 0;

   if(ManualLotSize > 0.0)
   {
      //--- Manual mode: user-specified fixed lot
      lots = ManualLotSize;
   }
   else
   {
      //--- Automatic mode: risk-based calculation
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(stopDist <= 0 || tickSize <= 0 || tickVal <= 0)
      {
         if(PrintLogs) Print("WARNING: Invalid params for lot calc. Falling back to minLot.");
         return mn;
      }

      //--- Risk amount in account currency
      double riskAmt = (RiskType == 0)
         ? AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0
         : RiskAmountUSD;

      //--- Value per lot for this stop distance:
      //    stopTicks = stop distance / tick size
      //    valuePerLot = stopTicks × tick value
      double stopTicks = stopDist / tickSize;
      double valPerLot = stopTicks * tickVal;
      if(valPerLot <= 0) { if(PrintLogs) Print("WARNING: valPerLot=0."); return mn; }

      lots = riskAmt / valPerLot;

      if(PrintLogs)
         PrintFormat("LotCalc | StopDist=%.5f Ticks=%.2f VPL=%.4f Risk=%.2f Lots(raw)=%.4f",
                     stopDist, stopTicks, valPerLot, riskAmt, lots);
   }

   //--- Apply same-direction multiplier (e.g., reduce size on consecutive same-dir trades)
   if(sameDir && SameDirectionLotMultiplier > 0 && SameDirectionLotMultiplier != 1.0)
   {
      lots *= SameDirectionLotMultiplier;
      if(PrintLogs) PrintFormat("SameDir multiplier ×%.2f applied.", SameDirectionLotMultiplier);
   }

   //--- Normalize to lot step, clamp to [min, max]
   lots = MathFloor(lots / step) * step;
   if(lots < mn)
   {
      if(PrintLogs) PrintFormat("WARNING: Calculated lots (%.4f) below minLot (%.4f). Using minLot.", lots, mn);
      lots = mn;
   }
   lots = MathMin(lots, mx);
   return NormalizeDouble(lots, 2);
}

//==========================================================================
// ██ SESSION FILTER
//==========================================================================

//--- Returns true if current server time falls within either defined session
bool IsInSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 60 + dt.min;

   int s1s = T2M(Session1Start), s1e = T2M(Session1End);
   int s2s = T2M(Session2Start), s2e = T2M(Session2End);

   bool inS1 = (now >= s1s && now < s1e);
   bool inS2 = (now >= s2s && now < s2e);
   return inS1 || inS2;
}

//--- Convert "HH:MM" string to minutes-since-midnight integer
int T2M(string t)
{
   int col = StringFind(t, ":");
   if(col < 0) return 0;
   int h = (int)StringToInteger(StringSubstr(t, 0, col));
   int m = (int)StringToInteger(StringSubstr(t, col + 1));
   return h * 60 + m;
}

//==========================================================================
// ██ UTILITY
//==========================================================================

//--- Count open positions for this EA on this symbol
int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| END OF FILE                                                      |
//+------------------------------------------------------------------+