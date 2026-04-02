//+------------------------------------------------------------------+
//|                                       AlligatorStrategy_v3.mq5  |
//|              Alligator Cascading Cross EA – Version 3            |
//|                                                                  |
//|  Key changes from v2:                                            |
//|  - Crossover now requires THREE cascading crosses (not one):     |
//|      Lips/Teeth, Lips/Jaw, Teeth/Jaw – any order, all required  |
//|  - Stacking is implicit: all three crosses = fully stacked       |
//|  - Dual risk mode: RiskType 0 = % balance, 1 = fixed $amount    |
//|  - StopDistanceSource: 0 = signal bar H/L, 1 = ATR × multiplier |
//|  - All v2 logic retained: abandon-on-fail, age gate, timeout,   |
//|    same-direction lot multiplier, diverging confluence           |
//+------------------------------------------------------------------+
#property copyright "AlligatorStrategy EA v3"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==========================================================================
// INPUT PARAMETERS
//==========================================================================

//--- Alligator Settings
input group "=== Alligator Settings ==="
input int    Alligator_Jaw_Period      = 13;          // Jaw period
input int    Alligator_Jaw_Shift       = 8;           // Jaw shift
input int    Alligator_Teeth_Period    = 8;           // Teeth period
input int    Alligator_Teeth_Shift     = 5;           // Teeth shift
input int    Alligator_Lips_Period     = 5;           // Lips period
input int    Alligator_Lips_Shift      = 3;           // Lips shift

//--- Confluence Toggles
input group "=== Confluence Toggles ==="
input bool   UseMA_Confluence          = true;        // Enable MA trend filter
input bool   UseCCI_Confluence         = true;        // Enable CCI momentum filter
input bool   UseDiverging_Confluence   = true;        // Enable diverging Alligator filter

//--- Crossover / Timing
input group "=== Crossover Timing ==="
input int    MinCrossoverAgeBars       = 2;           // Min bars after FINAL cross before activation
input int    MaxBarsWithoutEntry       = 50;          // Abandon setup if no entry after this many bars

//--- MA Settings
input group "=== Moving Average Settings ==="
input int    MA_Period                 = 200;         // MA period
input ENUM_MA_METHOD  MA_Method        = MODE_SMA;   // MA smoothing method
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE; // MA applied price

//--- CCI Settings
input group "=== CCI Settings ==="
input int    CCI_Period                = 14;          // CCI period
input double CCI_Overbought            = 100.0;       // Long: CCI must be < this
input double CCI_Oversold              = -100.0;      // Short: CCI must be > this

//--- Lot Sizing
input group "=== Lot Sizing ==="
input double ManualLotSize             = 0.0;         // Fixed lot size (0 = use automatic)
input int    RiskType                  = 0;           // 0 = % of balance, 1 = fixed amount
input double RiskPercent               = 2.0;         // Risk % of balance (RiskType=0)
input double RiskAmountUSD             = 100.0;       // Fixed risk amount in account currency (RiskType=1)
input int    StopDistanceSource        = 0;           // 0 = signal bar H/L, 1 = ATR × multiplier
input double ATR_Stop_Multiplier       = 1.5;         // ATR multiplier for stop (StopDistanceSource=1)
input double RiskRewardRatio           = 2.0;         // Take Profit = SL distance × this ratio
input double SameDirectionLotMultiplier = 0.5;        // Lot multiplier for same-direction consecutive trades (0=skip)

//--- Trailing Stop
input group "=== Trailing Stop ==="
input bool   UseTrailingStop           = true;        // Enable trailing stop management
input double TrailingActivation        = 1.5;         // Activate after profit >= X × initial SL distance
input double TrailingStep              = 0.5;         // Trail distance = X × ATR

//--- General
input group "=== General Settings ==="
input int    MaxPositions              = 1;           // Maximum simultaneous open positions
input int    MagicNumber               = 20240401;    // EA identifier
input bool   PrintLogs                 = true;        // Enable debug logging

//==========================================================================
// GLOBAL VARIABLES
//==========================================================================

//--- Indicator handles
int  h_Alligator  = INVALID_HANDLE;
int  h_CCI        = INVALID_HANDLE;
int  h_MA         = INVALID_HANDLE;
int  h_ATR        = INVALID_HANDLE;

//--- Trade object
CTrade trade;

//--- New-bar tracking
static datetime g_LastBarTime = 0;

//--- Global bar counter – incremented on each new bar, used for age tracking
int  g_BarCount = 0;

//--------------------------------------------------------------------------
// BEARISH (SHORT) STATE MACHINE
// Tracks the three cascading crosses independently.
// All three must be true before crossover_complete can be set.
//--------------------------------------------------------------------------
bool  bear_LipsCrossedTeeth    = false; // Cross 1: Lips dropped below Teeth
bool  bear_LipsCrossedJaw      = false; // Cross 2: Lips dropped below Jaw
bool  bear_TeethCrossedJaw     = false; // Cross 3: Teeth dropped below Jaw (FINAL)
bool  bear_CrossoverComplete   = false; // All three crosses done → fully stacked
int   bear_FinalCrossBarIndex  = -1;    // Bar count when final cross (Teeth<Jaw) occurred
bool  bear_CrossoverValid      = false; // Age gate passed (MinCrossoverAgeBars elapsed)
bool  bear_ConditionsArmed     = false; // All conditions true; awaiting entry candle
double bear_SignalBarHigh      = 0.0;   // Signal bar high for SL (StopDistanceSource=0)

//--------------------------------------------------------------------------
// BULLISH (LONG) STATE MACHINE
//--------------------------------------------------------------------------
bool  bull_LipsCrossedTeeth    = false; // Cross 1: Lips rose above Teeth
bool  bull_LipsCrossedJaw      = false; // Cross 2: Lips rose above Jaw
bool  bull_TeethCrossedJaw     = false; // Cross 3: Teeth rose above Jaw (FINAL)
bool  bull_CrossoverComplete   = false;
int   bull_FinalCrossBarIndex  = -1;
bool  bull_CrossoverValid      = false;
bool  bull_ConditionsArmed     = false;
double bull_SignalBarLow       = 0.0;   // Signal bar low for SL (StopDistanceSource=0)

//--- Last trade direction: 1 = long, -1 = short, 0 = none
int  g_LastTradeDirection = 0;

//==========================================================================
// OnInit
//==========================================================================
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   //--- Alligator (SMMA, PRICE_MEDIAN)
   h_Alligator = iAlligator(_Symbol, PERIOD_CURRENT,
                             Alligator_Jaw_Period,   Alligator_Jaw_Shift,
                             Alligator_Teeth_Period, Alligator_Teeth_Shift,
                             Alligator_Lips_Period,  Alligator_Lips_Shift,
                             MODE_SMMA, PRICE_MEDIAN);
   if(h_Alligator == INVALID_HANDLE)
     { Print("ERROR: Alligator handle failed. Error=", GetLastError()); return INIT_FAILED; }

   h_CCI = iCCI(_Symbol, PERIOD_CURRENT, CCI_Period, PRICE_TYPICAL);
   if(h_CCI == INVALID_HANDLE)
     { Print("ERROR: CCI handle failed. Error=", GetLastError()); return INIT_FAILED; }

   h_MA = iMA(_Symbol, PERIOD_CURRENT, MA_Period, 0, MA_Method, MA_AppliedPrice);
   if(h_MA == INVALID_HANDLE)
     { Print("ERROR: MA handle failed. Error=", GetLastError()); return INIT_FAILED; }

   h_ATR = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(h_ATR == INVALID_HANDLE)
     { Print("ERROR: ATR handle failed. Error=", GetLastError()); return INIT_FAILED; }

   if(PrintLogs)
      PrintFormat("AlligatorStrategy v3 initialized | Symbol=%s TF=%s",
                  _Symbol, EnumToString(PERIOD_CURRENT));
   return INIT_SUCCEEDED;
  }

//==========================================================================
// OnDeinit
//==========================================================================
void OnDeinit(const int reason)
  {
   if(h_Alligator != INVALID_HANDLE) IndicatorRelease(h_Alligator);
   if(h_CCI       != INVALID_HANDLE) IndicatorRelease(h_CCI);
   if(h_MA        != INVALID_HANDLE) IndicatorRelease(h_MA);
   if(h_ATR       != INVALID_HANDLE) IndicatorRelease(h_ATR);

   if(PrintLogs) PrintFormat("EA deinitialized. Reason=%d", reason);
  }

//==========================================================================
// OnTick
//==========================================================================
void OnTick()
  {
   //--- Trailing stop runs on every tick for precise execution
   if(UseTrailingStop) ManageTrailingStops();

   //--- All other logic: once per new closed bar only
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_LastBarTime) return;
   g_LastBarTime = currentBarTime;
   g_BarCount++;

   //--- Fetch values from closed bar (shift 1) and prior bar (shift 2)
   double jaw1, teeth1, lips1;
   double jaw2, teeth2, lips2;
   double cci1, ma1, atr1;

   if(!GetAlligatorValues(1, jaw1, teeth1, lips1)) return;
   if(!GetAlligatorValues(2, jaw2, teeth2, lips2)) return;
   if(!GetSingleValue(h_CCI, 1, cci1, "CCI"))     return;
   if(!GetSingleValue(h_MA,  1, ma1,  "MA"))       return;
   if(!GetSingleValue(h_ATR, 1, atr1, "ATR"))      return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open1  = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double high1  = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double low1   = iLow  (_Symbol, PERIOD_CURRENT, 1);

   if(PrintLogs)
      PrintFormat("[Bar %d] O=%.5f H=%.5f L=%.5f C=%.5f | Jaw=%.5f Teeth=%.5f Lips=%.5f | CCI=%.2f MA=%.5f ATR=%.5f",
                  g_BarCount, open1, high1, low1, close1,
                  jaw1, teeth1, lips1, cci1, ma1, atr1);

   //=== STEP 1: Detect individual cascading crosses ========================
   DetectCascadingCrosses(lips1, teeth1, jaw1, lips2, teeth2, jaw2);

   //=== STEP 2: Promote crossovers to valid once age gate is passed ========
   PromoteCrossoverValidity();

   //=== STEP 3: Abandon setups that have exceeded the bar timeout ==========
   CheckTimeouts();

   //=== STEP 4: Evaluate all conditions and manage entries =================
   ProcessBearishLogic(lips1, teeth1, jaw1, lips2, teeth2, jaw2,
                       close1, open1, high1, low1, cci1, ma1, atr1);

   ProcessBullishLogic(lips1, teeth1, jaw1, lips2, teeth2, jaw2,
                       close1, open1, high1, low1, cci1, ma1, atr1);
  }

//==========================================================================
// DetectCascadingCrosses
//
// For BEARISH: we need all three of:
//   a) Lips crossed below Teeth  (lips1 < teeth1 AND lips2 >= teeth2)
//   b) Lips crossed below Jaw    (lips1 < jaw1   AND lips2 >= jaw2)
//   c) Teeth crossed below Jaw   (teeth1 < jaw1  AND teeth2 >= jaw2) ← FINAL
//
// For BULLISH: symmetric (> instead of <).
//
// Each cross is latched (set to true once, never re-evaluated until reset).
// When the FINAL cross (Teeth vs Jaw) is detected, crossover_complete is set
// and the bar index is recorded.
//
// If a new crossover in the same direction supersedes an existing one
// (e.g., already had partial crosses, now final cross occurs), the bar
// index is updated. If the market reverses direction, the opposite cycle
// is reset and the new one starts fresh.
//==========================================================================
void DetectCascadingCrosses(double lips1, double teeth1, double jaw1,
                             double lips2, double teeth2, double jaw2)
  {
   //--------------------------------------------------------------------------
   // BEARISH: each cross fires once when bar[1] crosses and bar[2] was above
   //--------------------------------------------------------------------------
   if(!bear_CrossoverComplete)
     {
      //--- Cross a: Lips below Teeth
      if(!bear_LipsCrossedTeeth && lips1 < teeth1 && lips2 >= teeth2)
        {
         bear_LipsCrossedTeeth = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bear cross A: Lips crossed below Teeth", g_BarCount);
        }

      //--- Cross b: Lips below Jaw
      if(!bear_LipsCrossedJaw && lips1 < jaw1 && lips2 >= jaw2)
        {
         bear_LipsCrossedJaw = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bear cross B: Lips crossed below Jaw", g_BarCount);
        }

      //--- Cross c (FINAL): Teeth below Jaw – completes the stacking
      if(!bear_TeethCrossedJaw && teeth1 < jaw1 && teeth2 >= jaw2)
        {
         bear_TeethCrossedJaw = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bear cross C: Teeth crossed below Jaw (FINAL)", g_BarCount);
        }

      //--- Check if all three crosses have now occurred
      if(bear_LipsCrossedTeeth && bear_LipsCrossedJaw && bear_TeethCrossedJaw)
        {
         bear_CrossoverComplete  = true;
         bear_FinalCrossBarIndex = g_BarCount;
         bear_CrossoverValid     = false;   // Must wait for age gate
         if(PrintLogs)
            PrintFormat(">>> BEARISH CASCADE COMPLETE at bar %d. Awaiting age validation.",
                        g_BarCount);

         //--- Also reset the bullish cycle since a full bearish stacking
         //    logically invalidates any in-progress bullish setup
         ResetBullCycle();
        }
     }

   //--------------------------------------------------------------------------
   // BULLISH: symmetric detection
   //--------------------------------------------------------------------------
   if(!bull_CrossoverComplete)
     {
      //--- Cross a: Lips above Teeth
      if(!bull_LipsCrossedTeeth && lips1 > teeth1 && lips2 <= teeth2)
        {
         bull_LipsCrossedTeeth = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bull cross A: Lips crossed above Teeth", g_BarCount);
        }

      //--- Cross b: Lips above Jaw
      if(!bull_LipsCrossedJaw && lips1 > jaw1 && lips2 <= jaw2)
        {
         bull_LipsCrossedJaw = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bull cross B: Lips crossed above Jaw", g_BarCount);
        }

      //--- Cross c (FINAL): Teeth above Jaw
      if(!bull_TeethCrossedJaw && teeth1 > jaw1 && teeth2 <= jaw2)
        {
         bull_TeethCrossedJaw = true;
         if(PrintLogs) PrintFormat("[Bar %d] Bull cross C: Teeth crossed above Jaw (FINAL)", g_BarCount);
        }

      //--- All three bulls done
      if(bull_LipsCrossedTeeth && bull_LipsCrossedJaw && bull_TeethCrossedJaw)
        {
         bull_CrossoverComplete  = true;
         bull_FinalCrossBarIndex = g_BarCount;
         bull_CrossoverValid     = false;
         if(PrintLogs)
            PrintFormat(">>> BULLISH CASCADE COMPLETE at bar %d. Awaiting age validation.",
                        g_BarCount);

         //--- Invalidate any in-progress bearish setup
         ResetBearCycle();
        }
     }
  }

//==========================================================================
// PromoteCrossoverValidity
// Converts a complete crossover to "valid" once MinCrossoverAgeBars have
// elapsed since the final cross bar.
//==========================================================================
void PromoteCrossoverValidity()
  {
   if(bear_CrossoverComplete && !bear_CrossoverValid)
     {
      int age = g_BarCount - bear_FinalCrossBarIndex;
      if(age >= MinCrossoverAgeBars)
        {
         bear_CrossoverValid = true;
         if(PrintLogs)
            PrintFormat(">>> Bearish crossover VALID (age=%d bars since final cross)", age);
        }
     }

   if(bull_CrossoverComplete && !bull_CrossoverValid)
     {
      int age = g_BarCount - bull_FinalCrossBarIndex;
      if(age >= MinCrossoverAgeBars)
        {
         bull_CrossoverValid = true;
         if(PrintLogs)
            PrintFormat(">>> Bullish crossover VALID (age=%d bars since final cross)", age);
        }
     }
  }

//==========================================================================
// CheckTimeouts
// Abandons a setup that has been valid for more than MaxBarsWithoutEntry
// bars without producing an entry.
//==========================================================================
void CheckTimeouts()
  {
   if(bear_CrossoverValid)
     {
      int validSince    = bear_FinalCrossBarIndex + MinCrossoverAgeBars;
      int barsAsValid   = g_BarCount - validSince;
      if(barsAsValid > MaxBarsWithoutEntry)
        {
         if(PrintLogs)
            PrintFormat(">>> Bearish setup TIMED OUT (%d bars without entry). Resetting.", barsAsValid);
         ResetBearCycle();
        }
     }

   if(bull_CrossoverValid)
     {
      int validSince    = bull_FinalCrossBarIndex + MinCrossoverAgeBars;
      int barsAsValid   = g_BarCount - validSince;
      if(barsAsValid > MaxBarsWithoutEntry)
        {
         if(PrintLogs)
            PrintFormat(">>> Bullish setup TIMED OUT (%d bars without entry). Resetting.", barsAsValid);
         ResetBullCycle();
        }
     }
  }

//==========================================================================
// ProcessBearishLogic
// Strict abandon-on-failure: any failed condition resets the entire cycle.
//==========================================================================
void ProcessBearishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   //--- Nothing to do if crossover not yet valid
   if(!bear_CrossoverValid) return;

   //-------------------------------------------------------------------
   // ENTRY ATTEMPT: Conditions were armed on previous bar.
   // bar[1] is now the "first candle after" – check the entry trigger.
   //-------------------------------------------------------------------
   if(bear_ConditionsArmed)
     {
      if(close1 < lips1 && close1 < open1)
        {
         if(PrintLogs) Print(">>> BEARISH ENTRY TRIGGER met. Attempting short...");
         OpenShortTrade(close1, high1, atr1);
        }
      else
        {
         //--- Entry candle failed → strict abandon
         if(PrintLogs)
            Print(">>> Bearish entry candle FAILED (not below Lips / not bearish). Abandoning.");
         ResetBearCycle();
        }
      return;
     }

   //-------------------------------------------------------------------
   // CONDITION EVALUATION (post-valid crossover, pre-arm)
   //-------------------------------------------------------------------

   //--- Condition 2: Price below all three Alligator lines
   if(!(close1 < jaw1 && close1 < teeth1 && close1 < lips1))
     {
      if(PrintLogs)
         PrintFormat(">>> Bear Cond2 FAIL: Price=%.5f not below Jaw=%.5f Teeth=%.5f Lips=%.5f. Abandoning.",
                     close1, jaw1, teeth1, lips1);
      ResetBearCycle();
      return;
     }

   //--- Condition 3 (optional): Price below MA
   if(UseMA_Confluence && close1 >= ma1)
     {
      if(PrintLogs)
         PrintFormat(">>> Bear MA FAIL: close=%.5f >= MA=%.5f. Abandoning.", close1, ma1);
      ResetBearCycle();
      return;
     }

   //--- Condition 4 (optional): CCI not oversold
   if(UseCCI_Confluence && cci1 <= CCI_Oversold)
     {
      if(PrintLogs)
         PrintFormat(">>> Bear CCI FAIL: CCI=%.2f <= oversold=%.2f. Abandoning.", cci1, CCI_Oversold);
      ResetBearCycle();
      return;
     }

   //--- Condition 5 (optional): Alligator diverging
   if(UseDiverging_Confluence && !IsDiverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
     {
      if(PrintLogs) Print(">>> Bear Diverging FAIL. Abandoning.");
      ResetBearCycle();
      return;
     }

   //--- All conditions passed on this bar → ARM for entry next bar
   bear_ConditionsArmed = true;
   bear_SignalBarHigh   = high1;   // Signal bar high for StopDistanceSource=0

   if(PrintLogs)
      PrintFormat(">>> All BEARISH conditions met at bar %d. Armed. SignalBarHigh=%.5f",
                  g_BarCount, bear_SignalBarHigh);
  }

//==========================================================================
// ProcessBullishLogic
//==========================================================================
void ProcessBullishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   if(!bull_CrossoverValid) return;

   //--- ENTRY ATTEMPT
   if(bull_ConditionsArmed)
     {
      if(close1 > lips1 && close1 > open1)
        {
         if(PrintLogs) Print(">>> BULLISH ENTRY TRIGGER met. Attempting long...");
         OpenLongTrade(close1, low1, atr1);
        }
      else
        {
         if(PrintLogs)
            Print(">>> Bullish entry candle FAILED (not above Lips / not bullish). Abandoning.");
         ResetBullCycle();
        }
      return;
     }

   //--- CONDITION EVALUATION

   //--- Condition 2: Price above all three lines
   if(!(close1 > jaw1 && close1 > teeth1 && close1 > lips1))
     {
      if(PrintLogs)
         PrintFormat(">>> Bull Cond2 FAIL: Price=%.5f not above Jaw=%.5f Teeth=%.5f Lips=%.5f. Abandoning.",
                     close1, jaw1, teeth1, lips1);
      ResetBullCycle();
      return;
     }

   //--- Condition 3 (optional): Price above MA
   if(UseMA_Confluence && close1 <= ma1)
     {
      if(PrintLogs)
         PrintFormat(">>> Bull MA FAIL: close=%.5f <= MA=%.5f. Abandoning.", close1, ma1);
      ResetBullCycle();
      return;
     }

   //--- Condition 4 (optional): CCI not overbought
   if(UseCCI_Confluence && cci1 >= CCI_Overbought)
     {
      if(PrintLogs)
         PrintFormat(">>> Bull CCI FAIL: CCI=%.2f >= overbought=%.2f. Abandoning.", cci1, CCI_Overbought);
      ResetBullCycle();
      return;
     }

   //--- Condition 5 (optional): Alligator diverging
   if(UseDiverging_Confluence && !IsDiverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
     {
      if(PrintLogs) Print(">>> Bull Diverging FAIL. Abandoning.");
      ResetBullCycle();
      return;
     }

   //--- Arm for next bar entry
   bull_ConditionsArmed = true;
   bull_SignalBarLow    = low1;

   if(PrintLogs)
      PrintFormat(">>> All BULLISH conditions met at bar %d. Armed. SignalBarLow=%.5f",
                  g_BarCount, bull_SignalBarLow);
  }

//==========================================================================
// OpenShortTrade
//==========================================================================
void OpenShortTrade(double entryPrice, double signalBarHigh, double atr)
  {
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Short skipped: MaxPositions reached.");
      ResetBearCycle();
      return;
     }

   bool isSameDir = (g_LastTradeDirection == -1);

   //--- Skip if multiplier = 0 and same direction
   if(isSameDir && SameDirectionLotMultiplier == 0.0)
     {
      if(PrintLogs) Print("Short skipped: SameDirectionLotMultiplier=0 and last was SHORT.");
      ResetBearCycle();
      return;
     }

   //--- Determine stop level
   double sl = 0.0;
   if(StopDistanceSource == 0)
      sl = bear_SignalBarHigh;             // Signal bar high
   else
      sl = entryPrice + atr * ATR_Stop_Multiplier;  // ATR-based

   double stopDistance = sl - entryPrice;
   if(stopDistance <= 0)
     {
      if(PrintLogs)
         PrintFormat("Short SL invalid: SL=%.5f Entry=%.5f diff=%.5f", sl, entryPrice, stopDistance);
      ResetBearCycle();
      return;
     }

   double tp      = entryPrice - stopDistance * RiskRewardRatio;
   double lotSize = CalculateLotSize(stopDistance, atr, isSameDir);

   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Short skipped: Lot size invalid.");
      ResetBearCycle();
      return;
     }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening SHORT | Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f SameDir=%s",
                  entryPrice, sl, tp, lotSize, stopDistance, isSameDir ? "YES" : "NO");

   if(trade.Sell(lotSize, _Symbol, 0, sl, tp, "Alligator Bear v3"))
     {
      if(PrintLogs) PrintFormat("SHORT opened. Order=%d", trade.ResultOrder());
      g_LastTradeDirection = -1;
      ResetBearCycle();
     }
   else
     {
      if(PrintLogs)
         PrintFormat("SHORT failed. Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
      ResetBearCycle();
     }
  }

//==========================================================================
// OpenLongTrade
//==========================================================================
void OpenLongTrade(double entryPrice, double signalBarLow, double atr)
  {
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Long skipped: MaxPositions reached.");
      ResetBullCycle();
      return;
     }

   bool isSameDir = (g_LastTradeDirection == 1);

   if(isSameDir && SameDirectionLotMultiplier == 0.0)
     {
      if(PrintLogs) Print("Long skipped: SameDirectionLotMultiplier=0 and last was LONG.");
      ResetBullCycle();
      return;
     }

   //--- Determine stop level
   double sl = 0.0;
   if(StopDistanceSource == 0)
      sl = bull_SignalBarLow;              // Signal bar low
   else
      sl = entryPrice - atr * ATR_Stop_Multiplier;

   double stopDistance = entryPrice - sl;
   if(stopDistance <= 0)
     {
      if(PrintLogs)
         PrintFormat("Long SL invalid: SL=%.5f Entry=%.5f diff=%.5f", sl, entryPrice, stopDistance);
      ResetBullCycle();
      return;
     }

   double tp      = entryPrice + stopDistance * RiskRewardRatio;
   double lotSize = CalculateLotSize(stopDistance, atr, isSameDir);

   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Long skipped: Lot size invalid.");
      ResetBullCycle();
      return;
     }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening LONG | Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f SameDir=%s",
                  entryPrice, sl, tp, lotSize, stopDistance, isSameDir ? "YES" : "NO");

   if(trade.Buy(lotSize, _Symbol, 0, sl, tp, "Alligator Bull v3"))
     {
      if(PrintLogs) PrintFormat("LONG opened. Order=%d", trade.ResultOrder());
      g_LastTradeDirection = 1;
      ResetBullCycle();
     }
   else
     {
      if(PrintLogs)
         PrintFormat("LONG failed. Error=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
      ResetBullCycle();
     }
  }

//==========================================================================
// CalculateLotSize
//
// 1. Determine base risk amount (RiskType 0 or 1)
// 2. Convert stop distance to monetary value per lot
// 3. Divide to get lots
// 4. Apply SameDirectionLotMultiplier if applicable
// 5. Floor to lot step, clamp to [minLot, maxLot]
// 6. If result < minLot, use minLot and print warning
//==========================================================================
double CalculateLotSize(double stopDistancePrice, double atr, bool isSameDirection)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = 0.0;

   if(ManualLotSize > 0.0)
     {
      //--- Manual mode: use fixed lot regardless of risk settings
      lots = ManualLotSize;
     }
   else
     {
      //--- Automatic mode
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0)
        {
         if(PrintLogs) Print("ERROR: Tick value/size invalid. Cannot calculate lot.");
         return 0.0;
        }

      //--- Step 1: Determine actual stop distance in price
      //    (already computed by caller; passed in as stopDistancePrice)
      if(stopDistancePrice <= 0)
        {
         if(PrintLogs) Print("ERROR: Stop distance is zero or negative.");
         return 0.0;
        }

      //--- Step 2: Determine risk amount in account currency
      double riskAmount = 0.0;
      if(RiskType == 0)
        {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         riskAmount = balance * (RiskPercent / 100.0);
         if(PrintLogs)
            PrintFormat("Auto lot | RiskType=0 | Balance=%.2f RiskPct=%.2f%% RiskAmt=%.2f",
                        balance, RiskPercent, riskAmount);
        }
      else
        {
         riskAmount = RiskAmountUSD;
         if(PrintLogs)
            PrintFormat("Auto lot | RiskType=1 | FixedRisk=%.2f", riskAmount);
        }

      //--- Step 3: Calculate value per lot for the given stop distance
      //    value_per_lot = (stop_distance / tick_size) × tick_value
      double stopInTicks        = stopDistancePrice / tickSize;
      double valuePerLotPerStop = stopInTicks * tickValue;

      if(valuePerLotPerStop <= 0)
        {
         if(PrintLogs) Print("ERROR: valuePerLotPerStop is zero.");
         return 0.0;
        }

      lots = riskAmount / valuePerLotPerStop;

      if(PrintLogs)
         PrintFormat("Auto lot | StopDist=%.5f StopTicks=%.2f ValPerLot=%.4f Lots(raw)=%.4f",
                     stopDistancePrice, stopInTicks, valuePerLotPerStop, lots);
     }

   //--- Step 4: Apply same-direction multiplier
   if(isSameDirection && SameDirectionLotMultiplier > 0.0)
     {
      lots *= SameDirectionLotMultiplier;
      if(PrintLogs)
         PrintFormat("Same-dir multiplier ×%.2f applied → Lots=%.4f", SameDirectionLotMultiplier, lots);
     }

   //--- Step 5: Round down to lot step
   lots = MathFloor(lots / lotStep) * lotStep;

   //--- Step 6: Clamp to [minLot, maxLot]
   if(lots < minLot)
     {
      if(PrintLogs)
         PrintFormat("WARNING: Calculated lots (%.4f) below minLot (%.4f). Using minLot.", lots, minLot);
      lots = minLot;
     }
   lots = MathMin(lots, maxLot);
   lots = NormalizeDouble(lots, 2);

   return lots;
  }

//==========================================================================
// ManageTrailingStops
// Runs every tick. Activates only after profit >= initial risk × TrailingActivation.
// Trails by ATR(live) × TrailingStep. SL only moves in trade's favour.
//==========================================================================
void ManageTrailingStops()
  {
   double atrBuf[1];
   if(CopyBuffer(h_ATR, 0, 0, 1, atrBuf) < 1) return;
   double liveATR = atrBuf[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Reconstruct initial risk from stored SL distance at open
      double initialRisk = MathAbs(openPrice - currentSL);
      if(initialRisk <= 0) continue;

      double trailDist = liveATR * TrailingStep;

      if(posType == POSITION_TYPE_BUY)
        {
         double profit = bid - openPrice;
         if(profit < initialRisk * TrailingActivation) continue;

         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > currentSL + _Point)
           {
            if(PrintLogs)
               PrintFormat("Trail LONG #%d: %.5f → %.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double profit = openPrice - ask;
         if(profit < initialRisk * TrailingActivation) continue;

         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < currentSL - _Point)
           {
            if(PrintLogs)
               PrintFormat("Trail SHORT #%d: %.5f → %.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
  }

//==========================================================================
// IsDiverging
// True when BOTH inter-line distances are growing (mouth opening).
// bar[1] vs bar[2] comparison.
//==========================================================================
bool IsDiverging(double lips1, double teeth1, double jaw1,
                 double lips2, double teeth2, double jaw2)
  {
   double lt_curr = MathAbs(lips1  - teeth1);
   double tj_curr = MathAbs(teeth1 - jaw1);
   double lt_prev = MathAbs(lips2  - teeth2);
   double tj_prev = MathAbs(teeth2 - jaw2);

   return (lt_curr > lt_prev) && (tj_curr > tj_prev);
  }

//==========================================================================
// CountOpenPositions – positions for this EA on this symbol
//==========================================================================
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
     }
   return count;
  }

//==========================================================================
// GetAlligatorValues
// Buffer map: 0 = Jaw, 1 = Teeth, 2 = Lips
//==========================================================================
bool GetAlligatorValues(int shift, double &jaw, double &teeth, double &lips)
  {
   double jBuf[1], tBuf[1], lBuf[1];

   if(CopyBuffer(h_Alligator, 0, shift, 1, jBuf) < 1 ||
      CopyBuffer(h_Alligator, 1, shift, 1, tBuf) < 1 ||
      CopyBuffer(h_Alligator, 2, shift, 1, lBuf) < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: Alligator CopyBuffer failed at shift=%d. Error=%d", shift, GetLastError());
      return false;
     }

   jaw   = jBuf[0];
   teeth = tBuf[0];
   lips  = lBuf[0];

   if(jaw == EMPTY_VALUE || teeth == EMPTY_VALUE || lips == EMPTY_VALUE)
     {
      if(PrintLogs)
         PrintFormat("WARNING: Alligator EMPTY_VALUE at shift=%d (insufficient history?)", shift);
      return false;
     }

   return true;
  }

//==========================================================================
// GetSingleValue – generic single-buffer helper
//==========================================================================
bool GetSingleValue(int handle, int shift, double &value, string name)
  {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: %s CopyBuffer failed at shift=%d. Error=%d", name, shift, GetLastError());
      return false;
     }
   value = buf[0];
   return true;
  }

//==========================================================================
// ResetBearCycle – full teardown of bearish state
//==========================================================================
void ResetBearCycle()
  {
   bear_LipsCrossedTeeth   = false;
   bear_LipsCrossedJaw     = false;
   bear_TeethCrossedJaw    = false;
   bear_CrossoverComplete  = false;
   bear_FinalCrossBarIndex = -1;
   bear_CrossoverValid     = false;
   bear_ConditionsArmed    = false;
   bear_SignalBarHigh      = 0.0;
  }

//==========================================================================
// ResetBullCycle – full teardown of bullish state
//==========================================================================
void ResetBullCycle()
  {
   bull_LipsCrossedTeeth   = false;
   bull_LipsCrossedJaw     = false;
   bull_TeethCrossedJaw    = false;
   bull_CrossoverComplete  = false;
   bull_FinalCrossBarIndex = -1;
   bull_CrossoverValid     = false;
   bull_ConditionsArmed    = false;
   bull_SignalBarLow       = 0.0;
  }

//+------------------------------------------------------------------+
//| END OF FILE                                                      |
//+------------------------------------------------------------------+
