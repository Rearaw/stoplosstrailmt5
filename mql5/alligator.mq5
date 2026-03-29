//+------------------------------------------------------------------+
//|                                          AlligatorStrategy.mq5   |
//|                          Alligator Crossover + Stack EA          |
//|                                                                  |
//|  Strategy: Alligator crossover -> stacking -> price position     |
//|            -> optional MA / CCI / converging confluences         |
//|            -> entry on first qualifying candle                   |
//+------------------------------------------------------------------+
#property copyright "AlligatorStrategy EA"
#property version   "1.00"
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
input bool   UseMA_Confluence        = true;         // Enable MA trend filter
input bool   UseCCI_Confluence       = true;         // Enable CCI momentum filter
input bool   UseConverging_Confluence= false;        // Enable converging Alligator filter

//--- MA Settings
input group "=== Moving Average Settings ==="
input int    MA_Period               = 200;          // MA period
input ENUM_MA_METHOD  MA_Method      = MODE_SMA;     // MA method
input ENUM_APPLIED_PRICE MA_AppliedPrice = PRICE_CLOSE; // MA applied price

//--- CCI Settings
input group "=== CCI Settings ==="
input int    CCI_Period              = 14;           // CCI period
input double CCI_Overbought          = 100.0;        // CCI overbought level (long requires CCI < this)
input double CCI_Oversold            = -100.0;       // CCI oversold level (short requires CCI > this)

//--- Position Sizing
input group "=== Position Sizing ==="
input double ManualLotSize           = 0.0;          // Fixed lot size (0 = auto-calculate)
input double RiskPercent             = 2.0;          // Risk % of account balance
input double RiskRewardRatio         = 2.0;          // Take Profit / Stop Loss ratio
input int    StopType                = 0;            // 0 = signal bar H/L, 1 = ATR-based

//--- Trailing Stop
input group "=== Trailing Stop ==="
input bool   UseTrailingStop         = true;         // Enable trailing stop
input double TrailingActivation      = 1.5;          // Activate after profit reaches X * initial risk
input double TrailingStep            = 0.5;          // Trail distance as X * ATR

//--- General
input group "=== General Settings ==="
input int    MaxPositions            = 1;            // Maximum simultaneous positions
input int    MagicNumber             = 20240327;     // EA magic number
input bool   PrintLogs               = true;         // Enable debug logging

//==========================================================================
// GLOBAL VARIABLES
//==========================================================================

//--- Indicator handles
int  h_Alligator = INVALID_HANDLE;
int  h_CCI       = INVALID_HANDLE;
int  h_MA        = INVALID_HANDLE;
int  h_ATR       = INVALID_HANDLE;

//--- Trade object
CTrade trade;

//--- New bar tracking
static datetime lastBarTime = 0;

//--- State machine – Bearish cycle
bool bearCrossoverOccurred   = false;  // Step 1: Lips crossed below Teeth & Jaw
bool bearStackingComplete     = false;  // Step 2: Lips < Teeth < Jaw
bool bearConditionsArmed      = false;  // Steps 1-3 (+optional) all true on prior bar
bool bearTradeTaken           = false;  // Prevents re-entry within same cycle

//--- State machine – Bullish cycle
bool bullCrossoverOccurred   = false;  // Step 1: Lips crossed above Teeth & Jaw
bool bullStackingComplete     = false;  // Step 2: Lips > Teeth > Jaw
bool bullConditionsArmed      = false;  // Steps 1-3 (+optional) all true on prior bar
bool bullTradeTaken           = false;  // Prevents re-entry within same cycle

//--- Previous bar Alligator values (for crossover detection)
double prevLips  = EMPTY_VALUE;
double prevTeeth = EMPTY_VALUE;
double prevJaw   = EMPTY_VALUE;

//--- Signal bar data (saved when conditions arm)
double bearSignalBarHigh = 0.0;  // SL reference for short
double bullSignalBarLow  = 0.0;  // SL reference for long

//--- Last trade direction to avoid consecutive same-direction trades
ENUM_POSITION_TYPE lastTradeDirection = WRONG_VALUE;

//==========================================================================
// OnInit
//==========================================================================
int OnInit()
  {
   //--- Configure trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   //--- Create Alligator handle
   h_Alligator = iAlligator(_Symbol, PERIOD_CURRENT,
                             Alligator_Jaw_Period,   Alligator_Jaw_Shift,
                             Alligator_Teeth_Period, Alligator_Teeth_Shift,
                             Alligator_Lips_Period,  Alligator_Lips_Shift,
                             MODE_SMMA, PRICE_MEDIAN);
   if(h_Alligator == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create Alligator handle. Error=", GetLastError());
      return INIT_FAILED;
     }

   //--- Create CCI handle
   h_CCI = iCCI(_Symbol, PERIOD_CURRENT, CCI_Period, PRICE_TYPICAL);
   if(h_CCI == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create CCI handle. Error=", GetLastError());
      return INIT_FAILED;
     }

   //--- Create MA handle
   h_MA = iMA(_Symbol, PERIOD_CURRENT, MA_Period, 0, MA_Method, MA_AppliedPrice);
   if(h_MA == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create MA handle. Error=", GetLastError());
      return INIT_FAILED;
     }

   //--- Create ATR handle
   h_ATR = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(h_ATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create ATR handle. Error=", GetLastError());
      return INIT_FAILED;
     }

   if(PrintLogs)
      Print("AlligatorStrategy EA initialized. Symbol=", _Symbol,
            " TF=", EnumToString(PERIOD_CURRENT));

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

   if(PrintLogs)
      Print("AlligatorStrategy EA deinitialized. Reason=", reason);
  }

//==========================================================================
// OnTick
//==========================================================================
void OnTick()
  {
   //--- Only process on new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
     {
      //--- Still process trailing stop management on every tick
      if(UseTrailingStop)
         ManageTrailingStops();
      return;
     }
   lastBarTime = currentBarTime;

   //--- Fetch indicator values from closed bar (shift 1) and shift 2 for convergence
   double jaw1, teeth1, lips1;
   double jaw2, teeth2, lips2;
   double cci1, ma1, atr1;

   if(!GetAlligatorValues(1, jaw1, teeth1, lips1)) return;
   if(!GetAlligatorValues(2, jaw2, teeth2, lips2)) return;
   if(!GetSingleValue(h_CCI, 1, cci1, "CCI"))     return;
   if(!GetSingleValue(h_MA,  1, ma1,  "MA"))       return;
   if(!GetSingleValue(h_ATR, 1, atr1, "ATR"))      return;

   //--- Retrieve closed bar OHLC
   double closeBar1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double openBar1  = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double highBar1  = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double lowBar1   = iLow(_Symbol,   PERIOD_CURRENT, 1);

   if(PrintLogs)
     {
      PrintFormat("Bar[1] O=%.5f H=%.5f L=%.5f C=%.5f | Jaw=%.5f Teeth=%.5f Lips=%.5f | CCI=%.2f MA=%.5f ATR=%.5f",
                  openBar1, highBar1, lowBar1, closeBar1,
                  jaw1, teeth1, lips1, cci1, ma1, atr1);
     }

   //=== STEP 1 – DETECT CROSSOVER EVENTS ===================================

   DetectCrossovers(lips1, teeth1, jaw1, lips2, teeth2, jaw2);

   //=== STEP 2 – DETECT STACKING COMPLETION ================================

   DetectStacking(lips1, teeth1, jaw1);

   //=== STEP 3 – EVALUATE ALL CONDITIONS AND MANAGE ENTRY/ARMING ===========

   ProcessBearishLogic(lips1, teeth1, jaw1,
                       lips2, teeth2, jaw2,
                       closeBar1, openBar1, highBar1, lowBar1,
                       cci1, ma1, atr1);

   ProcessBullishLogic(lips1, teeth1, jaw1,
                       lips2, teeth2, jaw2,
                       closeBar1, openBar1, highBar1, lowBar1,
                       cci1, ma1, atr1);

   //--- Store previous bar values for next tick's crossover detection
   prevLips  = lips1;
   prevTeeth = teeth1;
   prevJaw   = jaw1;
  }

//==========================================================================
// DetectCrossovers
// Checks shift-1 vs shift-2 to identify Lips crossing above/below both
// Teeth and Jaw. Sets bearCrossoverOccurred / bullCrossoverOccurred.
//==========================================================================
void DetectCrossovers(double lips1, double teeth1, double jaw1,
                      double lips2, double teeth2, double jaw2)
  {
   //--- Bearish crossover: Lips was above (Teeth or Jaw) on bar 2,
   //    now below BOTH on bar 1
   bool lipsNowBelowBoth = (lips1 < teeth1) && (lips1 < jaw1);
   bool lipsPrevAboveAny = (lips2 >= teeth2) || (lips2 >= jaw2);

   if(lipsNowBelowBoth && lipsPrevAboveAny)
     {
      //--- New bearish crossover – reset bull state and arm bear
      bearCrossoverOccurred = true;
      bearStackingComplete   = false;
      bearConditionsArmed    = false;
      bearTradeTaken         = false;
      bearSignalBarHigh      = 0.0;

      if(PrintLogs)
         Print(">>> BEARISH CROSSOVER detected on bar[1]");
     }

   //--- Bullish crossover: Lips was below (Teeth or Jaw) on bar 2,
   //    now above BOTH on bar 1
   bool lipsNowAboveBoth = (lips1 > teeth1) && (lips1 > jaw1);
   bool lipsPrevBelowAny = (lips2 <= teeth2) || (lips2 <= jaw2);

   if(lipsNowAboveBoth && lipsPrevBelowAny)
     {
      //--- New bullish crossover – reset bear state and arm bull
      bullCrossoverOccurred = true;
      bullStackingComplete   = false;
      bullConditionsArmed    = false;
      bullTradeTaken         = false;
      bullSignalBarLow       = 0.0;

      if(PrintLogs)
         Print(">>> BULLISH CROSSOVER detected on bar[1]");
     }
  }

//==========================================================================
// DetectStacking
// Once a crossover has occurred, watch for complete bearish/bullish stacking.
//==========================================================================
void DetectStacking(double lips1, double teeth1, double jaw1)
  {
   //--- Bearish stacking: Lips < Teeth < Jaw
   if(bearCrossoverOccurred && !bearStackingComplete && !bearTradeTaken)
     {
      if(lips1 < teeth1 && teeth1 < jaw1)
        {
         bearStackingComplete = true;
         if(PrintLogs) Print(">>> BEARISH STACKING complete (Lips<Teeth<Jaw)");
        }
     }

   //--- Bullish stacking: Lips > Teeth > Jaw
   if(bullCrossoverOccurred && !bullStackingComplete && !bullTradeTaken)
     {
      if(lips1 > teeth1 && teeth1 > jaw1)
        {
         bullStackingComplete = true;
         if(PrintLogs) Print(">>> BULLISH STACKING complete (Lips>Teeth>Jaw)");
        }
     }
  }

//==========================================================================
// ProcessBearishLogic
// Manages the full bearish pipeline: arm conditions -> entry candle check
//==========================================================================
void ProcessBearishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   if(!bearCrossoverOccurred || bearTradeTaken) return;

   //--- ENTRY ATTEMPT: If conditions were armed on the PREVIOUS bar,
   //    the CURRENT closed bar (shift 1) is the "first candle after".
   if(bearConditionsArmed)
     {
      //--- Entry trigger: close below Lips AND bearish candle
      if(close1 < lips1 && close1 < open1)
        {
         if(PrintLogs)
            Print(">>> BEARISH ENTRY TRIGGER met. Attempting short...");
         OpenShortTrade(close1, high1, atr1);
        }
      else
        {
         //--- Entry candle failed – reset armed state, no re-entry this cycle
         if(PrintLogs)
            Print(">>> Bearish entry candle FAILED (close>=Lips or bullish candle). Cycle reset.");
         ResetBearCycle();
        }
      return;  // Either entered or reset; done for this bar
     }

   //--- CONDITIONS CHECK: Stacking must be complete first
   if(!bearStackingComplete) return;

   //--- Condition 3: Price below all three lines
   bool priceBelowAll = (close1 < jaw1) && (close1 < teeth1) && (close1 < lips1);
   if(!priceBelowAll) return;

   //--- Condition 4 (optional): Price below MA
   if(UseMA_Confluence)
     {
      if(close1 >= ma1)
        {
         if(PrintLogs)
            PrintFormat("Bearish: MA confluence FAIL (close=%.5f >= MA=%.5f)", close1, ma1);
         return;
        }
     }

   //--- Condition 5 (optional): CCI not oversold
   if(UseCCI_Confluence)
     {
      if(cci1 <= CCI_Oversold)
        {
         if(PrintLogs)
            PrintFormat("Bearish: CCI confluence FAIL (CCI=%.2f <= %.2f)", cci1, CCI_Oversold);
         return;
        }
     }

   //--- Condition 6 (optional): Alligator converging
   if(UseConverging_Confluence)
     {
      if(IsConverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
        {
         if(PrintLogs)
            Print("Bearish: diverging confluence FAIL");
         return;
        }
     }

   //--- All conditions met – ARM the entry for next bar
   bearConditionsArmed = true;
   bearSignalBarHigh   = high1;  // Used for SL if StopType = 0

   if(PrintLogs)
      PrintFormat(">>> All BEARISH conditions met. Armed for entry. SignalBarHigh=%.5f", bearSignalBarHigh);
  }

//==========================================================================
// ProcessBullishLogic
// Manages the full bullish pipeline: arm conditions -> entry candle check
//==========================================================================
void ProcessBullishLogic(double lips1, double teeth1, double jaw1,
                         double lips2, double teeth2, double jaw2,
                         double close1, double open1, double high1, double low1,
                         double cci1, double ma1, double atr1)
  {
   if(!bullCrossoverOccurred || bullTradeTaken) return;

   //--- ENTRY ATTEMPT: Conditions were armed on the previous bar
   if(bullConditionsArmed)
     {
      //--- Entry trigger: close above Lips AND bullish candle
      if(close1 > lips1 && close1 > open1)
        {
         if(PrintLogs)
            Print(">>> BULLISH ENTRY TRIGGER met. Attempting long...");
         OpenLongTrade(close1, low1, atr1);
        }
      else
        {
         if(PrintLogs)
            Print(">>> Bullish entry candle FAILED (close<=Lips or bearish candle). Cycle reset.");
         ResetBullCycle();
        }
      return;
     }

   //--- Stacking must be complete first
   if(!bullStackingComplete) return;

   //--- Condition 3: Price above all three lines
   bool priceAboveAll = (close1 > jaw1) && (close1 > teeth1) && (close1 > lips1);
   if(!priceAboveAll) return;

   //--- Condition 4 (optional): Price above MA
   if(UseMA_Confluence)
     {
      if(close1 <= ma1)
        {
         if(PrintLogs)
            PrintFormat("Bullish: MA confluence FAIL (close=%.5f <= MA=%.5f)", close1, ma1);
         return;
        }
     }

   //--- Condition 5 (optional): CCI not overbought
   if(UseCCI_Confluence)
     {
      if(cci1 >= CCI_Overbought)
        {
         if(PrintLogs)
            PrintFormat("Bullish: CCI confluence FAIL (CCI=%.2f >= %.2f)", cci1, CCI_Overbought);
         return;
        }
     }

   //--- Condition 6 (optional): Alligator converging
   if(UseConverging_Confluence)
     {
      if(IsConverging(lips1, teeth1, jaw1, lips2, teeth2, jaw2))
        {
         if(PrintLogs)
            Print("Bullish: diverging confluence FAIL");
         return;
        }
     }

   //--- All conditions met – ARM the entry for next bar
   bullConditionsArmed = true;
   bullSignalBarLow    = low1;  // Used for SL if StopType = 0

   if(PrintLogs)
      PrintFormat(">>> All BULLISH conditions met. Armed for entry. SignalBarLow=%.5f", bullSignalBarLow);
  }

//==========================================================================
// OpenShortTrade
//==========================================================================
void OpenShortTrade(double entryPrice, double signalBarHigh, double atr)
  {
   //--- Enforce MaxPositions
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Short skipped: MaxPositions reached.");
      ResetBearCycle();
      return;
     }

   //--- Avoid consecutive same-direction trades
   if(lastTradeDirection == POSITION_TYPE_SELL)
     {
      if(PrintLogs) Print("Short skipped: Last trade was also SHORT.");
      ResetBearCycle();
      return;
     }

   //--- Calculate Stop Loss
   double sl = 0.0;
   if(StopType == 0)
      sl = bearSignalBarHigh;   // Signal bar high
   else
      sl = entryPrice + atr * 1.5;  // ATR-based

   double stopDistance = sl - entryPrice;
   if(stopDistance <= 0)
     {
      if(PrintLogs) PrintFormat("Short SL invalid: SL=%.5f Entry=%.5f", sl, entryPrice);
      ResetBearCycle();
      return;
     }

   //--- Calculate Take Profit
   double tp = entryPrice - stopDistance * RiskRewardRatio;

   //--- Calculate lot size
   double lotSize = CalculateLotSize(stopDistance);
   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Short skipped: Lot size calculation failed.");
      ResetBearCycle();
      return;
     }

   //--- Normalize SL/TP to symbol digits
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening SHORT: Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f",
                  entryPrice, sl, tp, lotSize, stopDistance);

   if(trade.Sell(lotSize, _Symbol, 0, sl, tp, "Alligator Bear"))
     {
      if(PrintLogs)
         PrintFormat("SHORT opened successfully. Ticket=%d", trade.ResultOrder());
      lastTradeDirection = POSITION_TYPE_SELL;
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
   //--- Enforce MaxPositions
   if(CountOpenPositions() >= MaxPositions)
     {
      if(PrintLogs) Print("Long skipped: MaxPositions reached.");
      ResetBullCycle();
      return;
     }

   //--- Avoid consecutive same-direction trades
   if(lastTradeDirection == POSITION_TYPE_BUY)
     {
      if(PrintLogs) Print("Long skipped: Last trade was also LONG.");
      ResetBullCycle();
      return;
     }

   //--- Calculate Stop Loss
   double sl = 0.0;
   if(StopType == 0)
      sl = bullSignalBarLow;         // Signal bar low
   else
      sl = entryPrice - atr * 1.5;  // ATR-based

   double stopDistance = entryPrice - sl;
   if(stopDistance <= 0)
     {
      if(PrintLogs) PrintFormat("Long SL invalid: SL=%.5f Entry=%.5f", sl, entryPrice);
      ResetBullCycle();
      return;
     }

   //--- Calculate Take Profit
   double tp = entryPrice + stopDistance * RiskRewardRatio;

   //--- Calculate lot size
   double lotSize = CalculateLotSize(stopDistance);
   if(lotSize <= 0)
     {
      if(PrintLogs) Print("Long skipped: Lot size calculation failed.");
      ResetBullCycle();
      return;
     }

   //--- Normalize
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(PrintLogs)
      PrintFormat("Opening LONG: Entry=%.5f SL=%.5f TP=%.5f Lots=%.2f StopDist=%.5f",
                  entryPrice, sl, tp, lotSize, stopDistance);

   if(trade.Buy(lotSize, _Symbol, 0, sl, tp, "Alligator Bull"))
     {
      if(PrintLogs)
         PrintFormat("LONG opened successfully. Ticket=%d", trade.ResultOrder());
      lastTradeDirection = POSITION_TYPE_BUY;
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
// ManageTrailingStops
// Called on every tick for open positions with magic number.
// Activates only after profit exceeds TrailingActivation * initial risk.
//==========================================================================
void ManageTrailingStops()
  {
   if(!UseTrailingStop) return;

   double atrBuf[1];
   if(CopyBuffer(h_ATR, 0, 0, 1, atrBuf) < 1) return;
   double currentATR = atrBuf[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Reconstruct initial risk from SL distance at open
      double initialRisk = MathAbs(openPrice - currentSL);
      if(initialRisk <= 0) continue;

      double trailDist = currentATR * TrailingStep;

      if(posType == POSITION_TYPE_BUY)
        {
         double profit = currentBid - openPrice;
         double activationLevel = initialRisk * TrailingActivation;

         if(profit < activationLevel) continue;  // Not activated yet

         double newSL = NormalizeDouble(currentBid - trailDist, _Digits);

         //--- Only move SL if it improves (higher for longs)
         if(newSL > currentSL + _Point)
           {
            if(PrintLogs)
               PrintFormat("Trail LONG #%d: OldSL=%.5f NewSL=%.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double profit = openPrice - currentAsk;
         double activationLevel = initialRisk * TrailingActivation;

         if(profit < activationLevel) continue;  // Not activated yet

         double newSL = NormalizeDouble(currentAsk + trailDist, _Digits);

         //--- Only move SL if it improves (lower for shorts)
         if(newSL < currentSL - _Point)
           {
            if(PrintLogs)
               PrintFormat("Trail SHORT #%d: OldSL=%.5f NewSL=%.5f", ticket, currentSL, newSL);
            trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
  }

//==========================================================================
// CalculateLotSize
//==========================================================================
double CalculateLotSize(double stopDistancePrice)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = 0.0;

   if(ManualLotSize > 0.0)
     {
      //--- Use fixed manual lot size
      lots = ManualLotSize;
     }
   else
     {
      //--- Auto-calculate based on risk percentage
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0 || stopDistancePrice <= 0)
        {
         if(PrintLogs) Print("ERROR: Cannot calculate lot size – invalid tick/stop values.");
         return 0.0;
        }

      double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount     = accountBalance * RiskPercent / 100.0;

      //--- Convert price distance to ticks, then to money per lot
      double stopDistanceTicks   = stopDistancePrice / tickSize;
      double valuePerLotPerTick  = tickValue;
      double valuePerLotPerStop  = stopDistanceTicks * valuePerLotPerTick;

      if(valuePerLotPerStop <= 0)
        {
         if(PrintLogs) Print("ERROR: valuePerLotPerStop is zero.");
         return 0.0;
        }

      lots = riskAmount / valuePerLotPerStop;
     }

   //--- Round to lot step and clamp to broker limits
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = NormalizeDouble(lots, 2);

   return lots;
  }

//==========================================================================
// IsConverging
// Returns true if Alligator lines are converging (mouth closing)
// Compares bar[1] (current) vs bar[2] (previous)
//==========================================================================
bool IsConverging(double lips1, double teeth1, double jaw1,
                  double lips2, double teeth2, double jaw2)
  {
   double dist_LT_current  = MathAbs(lips1  - teeth1);
   double dist_TJ_current  = MathAbs(teeth1 - jaw1);

   double dist_LT_previous = MathAbs(lips2  - teeth2);
   double dist_TJ_previous = MathAbs(teeth2 - jaw2);

   return (dist_LT_current < dist_LT_previous) && (dist_TJ_current < dist_TJ_previous);
  }

//==========================================================================
// CountOpenPositions
// Returns number of open positions with this EA's magic number on this symbol
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
// CopyBuffer: Buffer 0 = Jaw, Buffer 1 = Teeth, Buffer 2 = Lips
//==========================================================================
bool GetAlligatorValues(int shift, double &jaw, double &teeth, double &lips)
  {
   double jawBuf[1], teethBuf[1], lipsBuf[1];

   if(CopyBuffer(h_Alligator, 0, shift, 1, jawBuf)   < 1 ||
      CopyBuffer(h_Alligator, 1, shift, 1, teethBuf) < 1 ||
      CopyBuffer(h_Alligator, 2, shift, 1, lipsBuf)  < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: Failed to copy Alligator buffer at shift %d. Error=%d", shift, GetLastError());
      return false;
     }

   jaw   = jawBuf[0];
   teeth = teethBuf[0];
   lips  = lipsBuf[0];

   if(jaw == EMPTY_VALUE || teeth == EMPTY_VALUE || lips == EMPTY_VALUE)
     {
      if(PrintLogs)
         PrintFormat("WARNING: Alligator returned EMPTY_VALUE at shift %d", shift);
      return false;
     }

   return true;
  }

//==========================================================================
// GetSingleValue – generic helper for single-buffer indicators
//==========================================================================
bool GetSingleValue(int handle, int shift, double &value, string indicatorName)
  {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
     {
      if(PrintLogs)
         PrintFormat("ERROR: Failed to copy %s buffer at shift %d. Error=%d",
                     indicatorName, shift, GetLastError());
      return false;
     }
   value = buf[0];
   return true;
  }

//==========================================================================
// ResetBearCycle – clears bearish state machine
//==========================================================================
void ResetBearCycle()
  {
   bearCrossoverOccurred = false;
   bearStackingComplete   = false;
   bearConditionsArmed    = false;
   bearTradeTaken         = false;
   bearSignalBarHigh      = 0.0;
  }

//==========================================================================
// ResetBullCycle – clears bullish state machine
//==========================================================================
void ResetBullCycle()
  {
   bullCrossoverOccurred = false;
   bullStackingComplete   = false;
   bullConditionsArmed    = false;
   bullTradeTaken         = false;
   bullSignalBarLow       = 0.0;
  }

//+------------------------------------------------------------------+
//| END OF FILE                                                      |
//+------------------------------------------------------------------+