//+------------------------------------------------------------------+
//|                                       AlligatorStrategy_v2.mq5  |
//|              Alligator Crossover + Stack EA – Version 2          |
//|                                                                  |
//|  Key additions over v1:                                          |
//|  - Diverging (mouth-opening) Alligator confluence                |
//|  - MinCrossoverAgeBars: crossover must age before conditions     |
//|  - Strict abandon-on-failure: any failed condition resets cycle  |
//|  - SameDirectionLotMultiplier for consecutive same-dir trades    |
//|  - MaxBarsWithoutEntry timeout to prevent stale setups           |
//+------------------------------------------------------------------+
#property copyright "AlligatorStrategy EA v2"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==========================================================================
// INPUT PARAMETERS
//==========================================================================

//--- Alligator Settings
input group "=== Alligator Settings ==="
input int    Alligator_Jaw_Period    = 13;           // Jaw period
input int    Alligator_Jaw_Shift     = 8;            // Jaw shift
input int    Alligator_Teeth_Period  = 8;            // Teeth period
input int    Alligator_Teeth_Shift   = 5;            // Teeth shift
input int    Alligator_Lips_Period   = 5;            // Lips period
input int    Alligator_Lips_Shift    = 3;            // Lips shift

//--- Confluence Toggles
input group "=== Confluence Toggles ==="
input bool   UseMA_Confluence         = true;        // Enable MA trend filter
input bool   UseCCI_Confluence        = true;        // Enable CCI momentum filter
input bool   UseDiverging_Confluence  = true;        // Enable diverging (mouth-opening) Alligator filter

//--- Crossover Validity
input group "=== Crossover Validity ==="
input int    MinCrossoverAgeBars      = 2;           // Min bars after crossover before activation
input int    MaxBarsWithoutEntry      = 50;          // Abandon setup if no entry after this many bars

//--- MA Settings
input group "=== Moving Average Settings ==="
input int    MA_Period                = 200;         // MA period
input ENUM_MA_METHOD  MA_Method       = MODE_SMA;   // MA smoothing method
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE; // MA price type

//--- CCI Settings
input group "=== CCI Settings ==="
input int    CCI_Period               = 14;          // CCI period
input double CCI_Overbought           = 100.0;       // Long requires CCI < this
input double CCI_Oversold             = -100.0;      // Short requires CCI > this

//--- Position Sizing
input group "=== Position Sizing ==="
input double ManualLotSize            = 0.0;         // Fixed lot size (0 = auto-calculate)
input double RiskPercent              = 2.0;         // Risk % of account balance (auto mode)
input double RiskRewardRatio          = 2.0;         // Take Profit / Stop Loss ratio
input double SameDirectionLotMultiplier = 0.5;       // Lot multiplier for consecutive same-dir trades (0=skip)
input int    StopType                 = 0;           // 0 = signal bar H/L, 1 = ATR-based (1.5×ATR)

//--- Trailing Stop
input group "=== Trailing Stop ==="
input bool   UseTrailingStop          = true;        // Enable trailing stop
input double TrailingActivation       = 1.5;         // Activate after profit >= X × initial risk
input double TrailingStep             = 0.5;         // Trail distance as X × ATR

//--- General
input group "=== General Settings ==="
input int    MaxPositions             = 1;           // Maximum simultaneous positions
input int    MagicNumber              = 20240329;    // EA magic number identifier
input bool   PrintLogs                = true;        // Enable debug log output

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

//--- New-bar time tracking
static datetime lastBarTime = 0;

//--- Current bar count (incremented on each new bar, used for crossover age tracking)
int  g_BarCount = 0;

//--------------------------------------------------------------------------
// BEARISH STATE MACHINE
//--------------------------------------------------------------------------
bool bear_CrossoverOccurred  = false; // Step 1: Lips crossed below Teeth & Jaw
int  bear_CrossoverBarIndex  = -1;    // Bar count when the crossover happened
bool bear_CrossoverValid     = false; // Crossover age >= MinCrossoverAgeBars
bool bear_StackingComplete   = false; // Step 2: Full bearish stack (Lips<Teeth<Jaw)
bool bear_ConditionsArmed    = false; // All conditions true; awaiting entry candle
double bear_SignalBarHigh    = 0.0;   // Signal bar high (SL reference for shorts)

//--------------------------------------------------------------------------
// BULLISH STATE MACHINE
//--------------------------------------------------------------------------
bool bull_CrossoverOccurred  = false;
int  bull_CrossoverBarIndex  = -1;
bool bull_CrossoverValid     = false;
bool bull_StackingComplete   = false;
bool bull_ConditionsArmed    = false;
double bull_SignalBarLow     = 0.0;   // Signal bar low (SL reference for longs)

//--- Track last trade direction to apply SameDirectionLotMultiplier
//    1 = last trade was long, -1 = last trade was short, 0 = none yet
int  g_LastTradeDirection    = 0;

//==========================================================================
// OnInit
//==========================================================================
int OnInit()
  {
   //--- Configure trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   //--- Alligator handle (SMMA, PRICE_MEDIAN per spec)
   h_Alligator = iAlligator(_Symbol, PERIOD_CURRENT,
                             Alligator_Jaw_Period,   Alligator_Jaw_Shift,
                             Alligator_Teeth_Period, Alligator_Teeth_Shift,
                             Alligator_Lips_Period,  Alligator_Lips_Shift,
                             MODE_SMMA, PRICE_MEDIAN);
   if(h_Alligator == INVALID_HANDLE)
     { Print("ERROR: Alligator handle creation failed. Error=", GetLastError()); return INIT_FAILED; }

   //--- CCI handle (PRICE_TYPICAL is standard for CCI)
   h_CCI = iCCI(_Symbol, PERIOD_CURRENT, CCI_Period, PRICE_TYPICAL);
   if(h_CCI == INVALID_HANDLE)
     { Print("ERROR: CCI handle creation failed. Error=", GetLastError()); return INIT_FAILED; }

   //--- MA handle
   h_MA = iMA(_Symbol, PERIOD_CURRENT, MA_Period, 0, MA_Method, MA_AppliedPrice);
   if(h_MA == INVALID_HANDLE)
     { Print("ERROR: MA handle creation failed. Error=", GetLastError()); return INIT_FAILED; }

   //--- ATR handle
   h_ATR = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(h_ATR == INVALID_HANDLE)
     { Print("ERROR: ATR handle creation failed. Error=", GetLastError()); return INIT_FAILED; }

   if(PrintLogs)
      PrintFormat("AlligatorStrategy v2 initialized. Symbol=%s  TF=%s",
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
   //--- Trailing stop management runs on every tick for responsiveness
   if(UseTrailingStop) ManageTrailingStops();

   //--- All other logic runs once per new closed bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   //--- Increment global bar counter (used for crossover age)
   g_BarCount++;

   //--- Fetch indicator values from closed bar (shift 1) and prior bar (shift 2)
   double jaw1, teeth1, lips1;
   double jaw2, teeth2, lips2;
   double cci1, ma1, atr1;

   if(!GetAlligatorValues(1, jaw1, teeth1, lips1)) return;
   if(!GetAlligatorValues(2, jaw2, teeth2, lips2)) return;
   if(!GetSingleValue(h_CCI, 1, cci1, "CCI"))     return;
   if(!GetSingleValue(h_MA,  1, ma1,  "MA"))       return;
   if(!GetSingleValue(h_ATR, 1, atr1, "ATR"))      return;

   //--- Closed bar OHLC
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open1  = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double high1  = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double low1   = iLow  (_Symbol, PERIOD_CURRENT, 1);

   if(PrintLogs)
      PrintFormat("[Bar %d] O=%.5f H=%.5f L=%.5f C=%.5f | Jaw=%.5f Teeth=%.5f Lips=%.5f | CCI=%.2f MA=%.5f ATR=%.5f",
                  g_BarCount, open1, high1, low1, close1,
                  jaw1, teeth1, lips1, cci1, ma1, atr1);

   //=== 1. DETECT NEW CROSSOVER EVENTS =====================================
   DetectCrossovers(lips1, teeth1, jaw1, lips2, teeth2, jaw2);

   //=== 2. PROMOTE CROSSOVERS TO VALID BASED ON AGE ========================
   PromoteCrossoverValidity();

   //=== 3. CHECK TIMEOUT – abandon if no entry in MaxBarsWithoutEntry ======
   CheckTimeouts();

   //=== 4. DETECT STACKING (only after crossover is valid) =================
   DetectStacking(lips1, teeth1, jaw1);

   //=== 5. EVALUATE CONDITIONS AND MANAGE ENTRY ============================
   ProcessBearishLogic(lips1, teeth1, jaw1, lips2, teeth2, jaw2,
                       close1, open1, high1, low1, cci1, ma1, atr1);

   ProcessBullishLogic(lips1, teeth1, jaw1, lips2, teeth2, jaw2,
                       close1, open1, high1, low1, cci1, ma1, atr1);
  }

//==========================================================================
// DetectCrossovers
// Compare bar[1] vs bar[2] to identify Lips crossing above/below both
// Teeth and Jaw simultaneously. Records bar count at event time.
//==========================================================================
void DetectCrossovers(double lips1, double teeth1, double jaw1,
                      double lips2, double teeth2, double jaw2)
  {
   //--- Bearish crossover: Lips now below BOTH Teeth & Jaw,
   //    but on the prior bar was above at least one of them.
   bool bearNow  = (lips1 < teeth1) && (lips1 < jaw1);
   bool bearPrev = (lips2 >= teeth2) || (lips2 >= jaw2);

   if(bearNow && bearPrev && !bear_CrossoverOccurred)
     {
      //--- Fresh bearish crossover detected; reset full bearish state
      ResetBearCycle();
      bear_CrossoverOccurred = true;
      bear_CrossoverBarIndex = g_BarCount;  // Record when it happened
      if(PrintLogs)
         PrintFormat(">>> BEARISH CROSSOVER at bar %d", g_BarCount);
     }

   //--- Bullish crossover: Lips now above BOTH Teeth & Jaw,
   //    but on prior bar was below at least one of them.
   bool bullNow  = (lips1 > teeth1) && (lips1 > jaw1);
   bool bullPrev = (lips2 <= teeth2) || (lips2 <= jaw2);

   if(bullNow && bullPrev && !bull_CrossoverOccurred)
     {
      ResetBullCycle();
      bull_CrossoverOccurred = true;
      bull_CrossoverBarIndex = g_BarCount;
      if(PrintLogs)
         PrintFormat(">>> BULLISH CROSSOVER at bar %d", g_BarCount);
     }
  }

//==========================================================================
// PromoteCrossoverValidity
// A crossover becomes "valid" once MinCrossoverAgeBars bars have elapsed.
//==========================================================================
void PromoteCrossoverValidity()
  {
   if(bear_CrossoverOccurred && !bear_CrossoverValid)
     {
      int age = g_BarCount - bear_CrossoverBarIndex;
      if(age >= MinCrossoverAgeBars)
        {
         bear_CrossoverValid = true;
         if(PrintLogs)
            PrintFormat(">>> Bearish crossover now VALID (age=%d bars)", age);
        }
     }

   if(bull_CrossoverOccurred && !bull_CrossoverValid)
     {
      int age = g_BarCount - bull_CrossoverBarIndex;
      if(age >= MinCrossoverAgeBars)
        {
         bull_CrossoverValid = true;
         if(PrintLogs)
            PrintFormat(">>> Bullish crossover now VALID (age=%d bars)", age);
        }
     }
  }

//==========================================================================
// CheckTimeouts
// If MaxBarsWithoutEntry bars have passed since the crossover became valid
// and no entry has been taken, abandon the setup.
//==========================================================================
void CheckTimeouts()
  {
   if(bear_CrossoverValid)
     {
      int barsActive = g_BarCount - (bear_CrossoverBarIndex + MinCrossoverAgeBars);
      if(barsActive > MaxBarsWithoutEntry)
        {
         if(PrintLogs)
            PrintFormat(">>> Bearish setup TIMED OUT after %d bars. Resetting.", barsActive);
         ResetBearCycle();
        }
     }

   if(bull_CrossoverValid)
     {
      int barsActive = g_BarCount - (bull_CrossoverBarIndex + MinCrossoverAgeBars);
      if(barsActive > MaxBarsWithoutEntry)
        {
         if(PrintLogs)
            PrintFormat(">>> Bullish setup TIMED OUT after %d bars. Resetting.", barsActive);
         ResetBullCycle();
        }
     }
  }

//==========================================================================
// DetectStacking
// Only evaluated once the crossover is valid. Checks for complete stacking.
//==========================================================================
void DetectStacking(double lips1, double teeth1, double jaw1)
  {
   //--- Bearish stacking: Lips < Teeth < Jaw
   if(bear_CrossoverValid && !bear_StackingComplete)
     {
      if(lips1 < teeth1 && teeth1 < jaw1)
        {
         bear_StackingComplete = true;
         if(PrintLogs) Print(">>> BEARISH STACKING complete (Lips < Teeth < Jaw)");
        }
     }

   //--- Bullish stacking: Lips > Teeth > Jaw
   if(bull_CrossoverValid && !bull_StackingComplete)
     {
      if(lips1 > teeth1 && teeth1 > jaw1)
        {
         bull_StackingComplete = true;
         if(PrintLogs) Print(">>> BULLISH STACKING complete (Lips > Teeth > Jaw)");
        }
     }
  }

//==========================================================================
// ProcessBearishLogic
// Full bearish pipeline with strict abandon-on-failure.
//==========================================================================
void ProcessBearishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   //--- Nothing to do if crossover not valid or stacking not achieved
   if(!bear_CrossoverValid || !bear_StackingComplete) return;

   //=== ENTRY ATTEMPT: bear_ConditionsArmed was set on the previous bar.
   //    bar[1] is now the "first candle after" – check entry trigger.
   if(bear_ConditionsArmed)
     {
      if(close1 < lips1 && close1 < open1)
        {
         //--- All criteria met – attempt short trade
         if(PrintLogs) Print(">>> BEARISH ENTRY TRIGGER met. Attempting short...");
         OpenShortTrade(close1, high1, atr1);
        }
      else
        {
         //--- Entry candle failed → ABANDON ENTIRE SETUP
         if(PrintLogs) Print(">>> Bearish entry candle FAILED. Abandoning setup.");
         ResetBearCycle();
        }
      return;  // Whether trade was placed or cycle reset, stop processing here
     }

   //=== CONDITIONS CHECK (evaluated bar-by-bar after stacking is complete)

   //--- Condition 3: Price below all three Alligator lines
   if(!(close1 < jaw1 && close1 < teeth1 && close1 < lips1))
     {
      if(PrintLogs)
         PrintFormat(">>> Bearish Cond3 FAIL: Price not below all lines. Abandoning.");
      ResetBearCycle();
      return;
     }

   //--- Condition 4 (optional): Price below MA
   if(UseMA_Confluence)
     {
      if(close1 >= ma1)
        {
         if(PrintLogs)
            PrintFormat(">>> Bearish MA Confluence FAIL (close=%.5f >= MA=%.5f). Abandoning.", close1, ma1);
         ResetBearCycle();
         return;
        }
     }

   //--- Condition 5 (optional): CCI not oversold
   if(UseCCI_Confluence)
     {
      if(cci1 <= CCI_Oversold)
        {
         if(PrintLogs)
            PrintFormat(">>> Bearish CCI Confluence FAIL (CCI=%.2f <= %.2f). Abandoning.", cci1, CCI_Oversold);
         ResetBearCycle();
         return;
        }
     }

   //--- Condition 6 (optional): Alligator diverging (mouth opening)
   if(UseDiverging_Confluence)
     {
      if(!IsDiverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
        {
         if(PrintLogs) Print(">>> Bearish Diverging Confluence FAIL. Abandoning.");
         ResetBearCycle();
         return;
        }
     }

   //--- All conditions satisfied on this bar → ARM for entry on next bar
   bear_ConditionsArmed = true;
   bear_SignalBarHigh   = high1;  // Capture signal bar high for SL (StopType = 0)

   if(PrintLogs)
      PrintFormat(">>> All BEARISH conditions met. Armed for entry next bar. SignalBarHigh=%.5f",
                  bear_SignalBarHigh);
  }

//==========================================================================
// ProcessBullishLogic
// Full bullish pipeline with strict abandon-on-failure.
//==========================================================================
void ProcessBullishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   if(!bull_CrossoverValid || !bull_StackingComplete) return;

   //=== ENTRY ATTEMPT
   if(bull_ConditionsArmed)
     {
      if(close1 > lips1 && close1 > open1)
        {
         if(PrintLogs) Print(">>> BULLISH ENTRY TRIGGER met. Attempting long...");
         OpenLongTrade(close1, low1, atr1);
        }
      else
        {
         if(PrintLogs) Print(">>> Bullish entry candle FAILED. Abandoning setup.");
         ResetBullCycle();
        }
      return;
     }

   //=== CONDITIONS CHECK

   //--- Condition 3: Price above all three lines
   if(!(close1 > jaw1 && close1 > teeth1 && close1 > lips1))
     {
      if(PrintLogs)
         PrintFormat(">>> Bullish Cond3 FAIL: Price not above all lines. Abandoning.");
      ResetBullCycle();
      return;
     }

   //--- Condition 4 (optional): Price above MA
   if(UseMA_Confluence)
     {
      if(close1 <= ma1)
        {
         if(PrintLogs)
            PrintFormat(">>> Bullish MA Confluence FAIL (close=%.5f <= MA=%.5f). Abandoning.", close1, ma1);
         ResetBullCycle();
         return;
        }
     }

   //--- Condition 5 (optional): CCI not overbought
   if(UseCCI_Confluence)
     {
      if(cci1 >= CCI_Overbought)
        {
         if(PrintLogs)
            PrintFormat(">>> Bullish CCI Confluence FAIL (CCI=%.2f >= %.2f). Abandoning.", cci1, CCI_Overbought);
         ResetBullCycle();
         return;
        }
     }

   //--- Condition 6 (optional): Alligator diverging
   if(UseDiverging_Confluence)
     {
      if(!IsDiverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
        {
         if(PrintLogs) Print(">>> Bullish Diverging Confluence FAIL. Abandoning.");
         ResetBullCycle();
         return;
        }
     }

   //--- All conditions satisfied – ARM for entry next bar
   bull_ConditionsArmed = true;
   bull_SignalBarLow    = low1;

   if(PrintLogs)
      PrintFormat(">>> All BULLISH conditions met. Armed for entry next bar. SignalBarLow=%.5f",
                  bull_SignalBarLow);
  }

//==========================================================================
// OpenShortTrade
//==========================================================================
void OpenShortTrade(double entryPrice, double signalBarHigh, double atr)
  {
   //--- Enforce max positions
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Short skipped: MaxPositions reached.");
      ResetBearCycle();
      return;
     }

   //--- Determine lot size (apply same-direction multiplier if applicable)
   bool isSameDirection = (g_LastTradeDirection == -1);

   //--- If SameDirectionLotMultiplier = 0 and same direction, skip trade
   if(isSameDirection && SameDirectionLotMultiplier == 0.0)
     {
      if(PrintLogs) Print("Short skipped: SameDirectionLotMultiplier=0 and last trade was SHORT.");
      ResetBearCycle();
      return;
     }

   //--- Calculate stop loss
   double sl = 0.0;
   if(StopType == 0)
      sl = bear_SignalBarHigh;         // Signal bar high
   else
      sl = entryPrice + atr * 1.5;    // ATR-based

   double stopDistance = sl - entryPrice;
   if(stopDistance <= 0)
     {
      if(PrintLogs) PrintFormat("Short SL invalid: SL=%.5f Entry=%.5f", sl, entryPrice);
      ResetBearCycle();
      return;
     }

   //--- Take profit
   double tp = entryPrice - stopDistance * RiskRewardRatio;

   //--- Lot size calculation with same-direction multiplier
   double lotSize = CalculateLotSize(stopDistance, isSameDirection);
   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Short skipped: Invalid lot size calculation.");
      ResetBearCycle();
      return;
     }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening SHORT: Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f SameDir=%s",
                  entryPrice, sl, tp, lotSize, stopDistance, isSameDirection ? "YES" : "NO");

   if(trade.Sell(lotSize, _Symbol, 0, sl, tp, "Alligator Bear v2"))
     {
      if(PrintLogs)
         PrintFormat("SHORT opened. Order=%d", trade.ResultOrder());
      g_LastTradeDirection = -1;  // Record direction
      ResetBearCycle();
     }
   else
     {
      if(PrintLogs)
         PrintFormat("SHORT failed. LastError=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
      ResetBearCycle();
     }
  }

//==========================================================================
// OpenLongTrade
//==========================================================================
void OpenLongTrade(double entryPrice, double signalBarLow, double atr)
  {
   //--- Enforce max positions
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Long skipped: MaxPositions reached.");
      ResetBullCycle();
      return;
     }

   //--- Determine if this is a same-direction trade
   bool isSameDirection = (g_LastTradeDirection == 1);

   //--- If multiplier = 0 and same direction, skip
   if(isSameDirection && SameDirectionLotMultiplier == 0.0)
     {
      if(PrintLogs) Print("Long skipped: SameDirectionLotMultiplier=0 and last trade was LONG.");
      ResetBullCycle();
      return;
     }

   //--- Calculate stop loss
   double sl = 0.0;
   if(StopType == 0)
      sl = bull_SignalBarLow;          // Signal bar low
   else
      sl = entryPrice - atr * 1.5;    // ATR-based

   double stopDistance = entryPrice - sl;
   if(stopDistance <= 0)
     {
      if(PrintLogs) PrintFormat("Long SL invalid: SL=%.5f Entry=%.5f", sl, entryPrice);
      ResetBullCycle();
      return;
     }

   //--- Take profit
   double tp = entryPrice + stopDistance * RiskRewardRatio;

   //--- Lot size with same-direction multiplier
   double lotSize = CalculateLotSize(stopDistance, isSameDirection);
   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Long skipped: Invalid lot size calculation.");
      ResetBullCycle();
      return;
     }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening LONG: Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f SameDir=%s",
                  entryPrice, sl, tp, lotSize, stopDistance, isSameDirection ? "YES" : "NO");

   if(trade.Buy(lotSize, _Symbol, 0, sl, tp, "Alligator Bull v2"))
     {
      if(PrintLogs)
         PrintFormat("LONG opened. Order=%d", trade.ResultOrder());
      g_LastTradeDirection = 1;
      ResetBullCycle();
     }
   else
     {
      if(PrintLogs)
         PrintFormat("LONG failed. LastError=%d RetCode=%d", GetLastError(), trade.ResultRetcode());
      ResetBullCycle();
     }
  }

//==========================================================================
// ManageTrailingStops
// Runs on every tick. Activates only after profit >= initial risk × TrailingActivation.
// Trails by ATR × TrailingStep; never moves SL against the trade.
//==========================================================================
void ManageTrailingStops()
  {
   //--- Fetch current ATR value from live bar (shift 0) for tick-level trailing
   double atrBuf[1];
   if(CopyBuffer(h_ATR, 0, 0, 1, atrBuf) < 1) return;
   double currentATR = atrBuf[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;

      ENUM_POSITION_TYPE posType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice            = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL            = PositionGetDouble(POSITION_SL);
      double currentTP            = PositionGetDouble(POSITION_TP);
      double bid                  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask                  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Reconstruct initial risk from stored SL at open price
      double initialRisk = MathAbs(openPrice - currentSL);
      if(initialRisk <= 0) continue;

      double trailDist = currentATR * TrailingStep;

      if(posType == POSITION_TYPE_BUY)
        {
         double profit = bid - openPrice;
         if(profit < initialRisk * TrailingActivation) continue;  // Not activated

         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > currentSL + _Point)  // Only move SL upward (never against trade)
           {
            if(PrintLogs)
               PrintFormat("Trail LONG #%d: SL %.5f → %.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double profit = openPrice - ask;
         if(profit < initialRisk * TrailingActivation) continue;  // Not activated

         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < currentSL - _Point)  // Only move SL downward (never against trade)
           {
            if(PrintLogs)
               PrintFormat("Trail SHORT #%d: SL %.5f → %.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
  }

//==========================================================================
// CalculateLotSize
// Calculates base lot from ManualLotSize or risk %, then applies
// SameDirectionLotMultiplier if isSameDirection = true.
//==========================================================================
double CalculateLotSize(double stopDistancePrice, bool isSameDirection)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = 0.0;

   if(ManualLotSize > 0.0)
     {
      //--- Fixed manual lot
      lots = ManualLotSize;
     }
   else
     {
      //--- Auto risk-based lot calculation
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0 || stopDistancePrice <= 0)
        {
         if(PrintLogs) Print("ERROR: Cannot calculate lot – bad tick or stop values.");
         return 0.0;
        }

      double balance            = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount         = balance * RiskPercent / 100.0;
      double stopInTicks        = stopDistancePrice / tickSize;
      double valuePerLotPerStop = stopInTicks * tickValue;

      if(valuePerLotPerStop <= 0)
        {
         if(PrintLogs) Print("ERROR: valuePerLotPerStop is zero.");
         return 0.0;
        }

      lots = riskAmount / valuePerLotPerStop;
     }

   //--- Apply same-direction multiplier if needed
   if(isSameDirection && SameDirectionLotMultiplier > 0.0)
     {
      lots *= SameDirectionLotMultiplier;
      if(PrintLogs)
         PrintFormat("Same-direction lot multiplier applied (×%.2f). Adjusted lots=%.4f",
                     SameDirectionLotMultiplier, lots);
     }

   //--- Round down to lot step, clamp to min/max
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = NormalizeDouble(lots, 2);

   return lots;
  }

//==========================================================================
// IsDiverging
// Returns true when Alligator lines are moving APART (mouth opening).
// Compares bar[1] (current) distances vs bar[2] (previous) distances.
//==========================================================================
bool IsDiverging(double lips1, double teeth1, double jaw1,
                 double lips2, double teeth2, double jaw2)
  {
   double dist_LT_curr = MathAbs(lips1  - teeth1);
   double dist_TJ_curr = MathAbs(teeth1 - jaw1);

   double dist_LT_prev = MathAbs(lips2  - teeth2);
   double dist_TJ_prev = MathAbs(teeth2 - jaw2);

   // Both inter-line distances must be growing
   return (dist_LT_curr > dist_LT_prev) && (dist_TJ_curr > dist_TJ_prev);
  }

//==========================================================================
// CountOpenPositions
// Returns count of open positions for this EA's magic number on this symbol.
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
// Buffers: 0 = Jaw, 1 = Teeth, 2 = Lips
//==========================================================================
bool GetAlligatorValues(int shift, double &jaw, double &teeth, double &lips)
  {
   double jawBuf[1], teethBuf[1], lipsBuf[1];

   if(CopyBuffer(h_Alligator, 0, shift, 1, jawBuf)   < 1 ||
      CopyBuffer(h_Alligator, 1, shift, 1, teethBuf) < 1 ||
      CopyBuffer(h_Alligator, 2, shift, 1, lipsBuf)  < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: Alligator CopyBuffer failed at shift=%d. Error=%d",
                     shift, GetLastError());
      return false;
     }

   jaw   = jawBuf[0];
   teeth = teethBuf[0];
   lips  = lipsBuf[0];

   if(jaw == EMPTY_VALUE || teeth == EMPTY_VALUE || lips == EMPTY_VALUE)
     {
      if(PrintLogs)
         PrintFormat("WARNING: Alligator EMPTY_VALUE at shift=%d. Insufficient history?", shift);
      return false;
     }

   return true;
  }

//==========================================================================
// GetSingleValue – generic helper for single-buffer indicators
//==========================================================================
bool GetSingleValue(int handle, int shift, double &value, string name)
  {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: %s CopyBuffer failed at shift=%d. Error=%d",
                     name, shift, GetLastError());
      return false;
     }
   value = buf[0];
   return true;
  }

//==========================================================================
// ResetBearCycle – complete teardown of bearish state machine
//==========================================================================
void ResetBearCycle()
  {
   bear_CrossoverOccurred = false;
   bear_CrossoverBarIndex = -1;
   bear_CrossoverValid    = false;
   bear_StackingComplete  = false;
   bear_ConditionsArmed   = false;
   bear_SignalBarHigh     = 0.0;
  }

//==========================================================================
// ResetBullCycle – complete teardown of bullish state machine
//==========================================================================
void ResetBullCycle()
  {
   bull_CrossoverOccurred = false;
   bull_CrossoverBarIndex = -1;
   bull_CrossoverValid    = false;
   bull_StackingComplete  = false;
   bull_ConditionsArmed   = false;
   bull_SignalBarLow      = 0.0;
  }

//+------------------------------------------------------------------+
//| END OF FILE         
//Rectify the crossover event. a valid crossover is when lips has crossed both teeth and jaw. a false signal is when lips has crossed only the teeth and the stacking says completed meaning price was just consolidating.                                             |
//+------------------------------------------------------------------+