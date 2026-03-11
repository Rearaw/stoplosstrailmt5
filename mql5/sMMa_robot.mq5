//+------------------------------------------------------------------+
//|                                                  sMMa_robot.mq5  |
//|                                              SMMA Trading Bot     |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "rearaw"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict
#property description "Automated trading bot using SMMA strategy with breakouts and retests"

//--- Input parameters
input int    SMMA_Length       = 100;          // SMMA Period
input bool   Use_Retests       = true;         // Enable Retests
input double Retest_Depth      = 0.1;          // Retest Depth (%)
input double Risk_Percentage   = 2.0;          // Risk % per trade
input double Take_Profit_Ratio = 3.0;          // TP/SL ratio
input int    Max_Positions     = 1;            // Max simultaneous positions
input bool   Use_SL            = true;         // Use stop loss
input bool   Use_TP            = true;         // Use take profit
input int    Magic_Number      = 100001;       // Magic number for identification
input bool   Print_Logs        = true;         // Print debug info
input double Manual_Lot_Size   = 0.05;         // Set >0 for manual lot size, 0 for auto
input int Zone_Consolidation_Bars = 3;         // Number of prior bars that must have closed inside zone


input bool   UseTrailingStop    = true;          // Enable trailing stop
input double TrailingStart      = 100.0;          // Points in profit to start trailing
input double TrailingStep       = 30.0;          // Trailing distance in points
input double TrailingMinDistance= 10.0;          // Minimum allowed trailing distance
input int    ATR_Period        = 15;            // ATR Period
input double ATR_Multiplier    = 6;           // ATR Multiplier for trailing distance

input double CCI_Overbought        = 100.0;       // CCI level to block long entries (overbought)
input double CCI_Oversold          = -100.0;      // CCI level to block short entries (oversold)
input bool   UseCCI_Momentum       = true;        // Enable CCI momentum lot size boost
input double CCI_Momentum_Min      = 90.0;        // CCI lower bound for momentum zone (long: 90-100, short: -100--90)
input double CCI_Momentum_Max      = 100.0;       // CCI upper bound for momentum zone
input double CCI_Momentum_Multiplier = 1.5;       // Lot size multiplier when CCI is in momentum zone
input bool   UseDistanceConfirm    = true;        // Enable minimum distance confirmation for signals
//--- Indicator handles
int hSMMA_High  = INVALID_HANDLE;
int hSMMA_Low   = INVALID_HANDLE;
int hSMMA_Close = INVALID_HANDLE;
int hCCI        = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
int hSMMA_MTF = INVALID_HANDLE;
int bars_needed = Zone_Consolidation_Bars + 3;

//--- Buffers for indicator values
double Buffer_SMMA_High[];
double Buffer_SMMA_Low[];
double Buffer_SMMA_Close[];
double Buffer_CCI[];

//--- Persistent bias
double bias = 0;
int last_trade_direction = 0;                    // 1 = last was long, -1 = last was short, 0 = none

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create SMMA handles
   hSMMA_High = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_HIGH);
   if (hSMMA_High == INVALID_HANDLE) 
   { 
      Print("Failed to create SMMA High handle");
      return(INIT_FAILED); 
   }
   
   hSMMA_Low = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_LOW);
   if (hSMMA_Low == INVALID_HANDLE) 
   { 
      Print("Failed to create SMMA Low handle");
      return(INIT_FAILED); 
   }
   
   hSMMA_Close = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_CLOSE);
   if (hSMMA_Close == INVALID_HANDLE) 
   { 
      Print("Failed to create SMMA Close handle");
      return(INIT_FAILED); 
   }
   
   hCCI = iCCI(NULL, 0, 14, PRICE_TYPICAL);
   if (hCCI == INVALID_HANDLE)
   {
      Print("Failed to create CCI handle");
      return(INIT_FAILED);
   }
   hATR = iATR(_Symbol, _Period, ATR_Period);
   if (hATR == INVALID_HANDLE) 
   { 
      Print("Failed to create ATR handle");
      return(INIT_FAILED); 
   }
   
   
   ArraySetAsSeries(Buffer_SMMA_High, true);
   ArraySetAsSeries(Buffer_SMMA_Low, true);
   ArraySetAsSeries(Buffer_SMMA_Close, true);
   ArraySetAsSeries(Buffer_CCI, true);
   
   if(Print_Logs) Print("Bot initialized successfully");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if (hSMMA_High != INVALID_HANDLE) IndicatorRelease(hSMMA_High);
   if (hSMMA_Low != INVALID_HANDLE) IndicatorRelease(hSMMA_Low);
   if (hSMMA_Close != INVALID_HANDLE) IndicatorRelease(hSMMA_Close);
   if (hCCI != INVALID_HANDLE) IndicatorRelease(hCCI);
   if (hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(Print_Logs) Print("Bot deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, _Period, 0);
   if (current_bar_time == last_bar_time) return;
   last_bar_time = current_bar_time;

   // === USE SHIFT 1 = JUST CLOSED BAR ===
   if (CopyBuffer(hSMMA_High,  0, 0, bars_needed, Buffer_SMMA_High)  < bars_needed) return;
   if (CopyBuffer(hSMMA_Low,   0, 0, bars_needed, Buffer_SMMA_Low)   < bars_needed) return;
   if (CopyBuffer(hSMMA_Close, 0, 0, bars_needed, Buffer_SMMA_Close) < bars_needed) return;
   if (CopyBuffer(hCCI,        0, 0, bars_needed, Buffer_CCI)        < bars_needed) return;

   // Closed bar (signal bar)
   double close_price   = iClose(_Symbol, _Period, 1);
   double open_price    = iOpen(_Symbol, _Period, 1);
   double high_price    = iHigh(_Symbol, _Period, 1);
   double low_price     = iLow(_Symbol, _Period, 1);

   double smma_high     = Buffer_SMMA_High[1];
   double smma_low      = Buffer_SMMA_Low[1];

   // Previous closed bar
   double prev_close    = iClose(_Symbol, _Period, 2);
   double prev_smma_high= Buffer_SMMA_High[2];
   double prev_smma_low = Buffer_SMMA_Low[2];

   // Update persistent bias on closed bar
   if (close_price > smma_high)      bias = 1;
   else if (close_price < smma_low)  bias = -1;

   int current_positions = CountPositions();

   if (current_positions < Max_Positions)
   {
      // Breakouts on closed bar
      bool long_breakout  = (close_price > smma_high) && (prev_close <= prev_smma_high);
      bool short_breakout = (close_price < smma_low)  && (prev_close >= prev_smma_low);

      // Retest zone
      double zone_width = smma_high - smma_low;
      double retest_zone = zone_width * (Retest_Depth / 100.0);

      bool long_retest = Use_Retests && (bias == 1) &&
                         (low_price  <= smma_low  + retest_zone) &&
                         (close_price > smma_high);

      bool short_retest = Use_Retests && (bias == -1) &&
                          (high_price >= smma_high - retest_zone) &&
                          (close_price < smma_low);

 
            // Candle direction filter (closed candle)
      bool zone_confirmed = CandlesClosedInsideZone(Zone_Consolidation_Bars);

      bool long_entry  = (long_breakout || long_retest)  && (close_price > open_price) && zone_confirmed;
      bool short_entry = (short_breakout || short_retest) && (close_price < open_price) && zone_confirmed;

      // Get CCI value for overbought/oversold filter
      double cci_value = Buffer_CCI[1];

    
      // === TRADE CONFIRMATION: MINIMUM DISTANCE FROM SMMA ===
      if (UseDistanceConfirm)
      {
         double candle_body = MathAbs(close_price - open_price);
         double min_distance = candle_body / 2.0;

         if (long_entry && (close_price - smma_high) < min_distance)
         long_entry = false;

         if (short_entry && (smma_low - close_price) < min_distance)
         short_entry = false;
      }
      bool AvoidConsecutive= true;
      // === AVOID CONSECUTIVE SAME-DIRECTION TRADES ===
      if (AvoidConsecutive)
      {
         if (long_entry && last_trade_direction == 1)
            long_entry = false;

         if (short_entry && last_trade_direction == -1)
            short_entry = false;
      }
      
      if (long_entry && cci_value < CCI_Overbought)  // Avoid long if overbought
      {
         if(Print_Logs) PrintFormat("Long signal | Price: %.5f | CCI: %.2f | Breakout: %s",
                                     close_price, cci_value, long_breakout ? "YES" : "NO");
         ExecuteLongTrade(cci_value);
      }
      if (short_entry && cci_value > CCI_Oversold)  // Avoid short if oversold
      {
         if(Print_Logs) PrintFormat("Short signal | Price: %.5f | CCI: %.2f | Breakout: %s",
                                     close_price, cci_value, short_breakout ? "YES" : "NO");
         ExecuteShortTrade(cci_value);
      }
   }

   ManagePositions();
}
// === HELPER FUNCTION ===
bool CandlesClosedInsideZone(int required_bars)
{
   for (int i = 2; i <= required_bars + 1; i++)  // Start at shift 2 (bar before signal bar)
   {
      double c = iClose(_Symbol, _Period, i);
      double sh = Buffer_SMMA_High[i];
      double sl = Buffer_SMMA_Low[i];

      if (c > sh || c < sl)  // Closed outside the zone
         return false;
   }
   return true;
}
//+------------------------------------------------------------------+
//| Execute long trade                                               |
//+------------------------------------------------------------------+
void ExecuteLongTrade(double cci_value)
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stop_loss   = 0;
   double take_profit = 0;

   // === TASK 2: SL placed so that the distance = Risk_Percentage of account balance ===
   if (Use_SL)
   {
      double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_amount     = account_balance * (Risk_Percentage / 100.0);  // e.g. 1000 * 10% = 100

      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double lot_size   = CalculateLotSize(cci_value);

      // SL distance in price = risk_amount / (lot_size * tick_value / tick_size)
      double value_per_lot_per_tick = tick_value / tick_size;
      double sl_distance = (lot_size > 0 && value_per_lot_per_tick > 0)
                           ? risk_amount / (lot_size * value_per_lot_per_tick)
                           : 0;

      stop_loss = NormalizeDouble(entry_price - sl_distance, _Digits);

      if (Use_TP)
         take_profit = NormalizeDouble(entry_price + sl_distance * Take_Profit_Ratio, _Digits);

      double final_lot = lot_size;
      if (final_lot <= 0.0) return;

      if (Print_Logs)
         PrintFormat("Long | Entry: %.5f | SL: %.5f | TP: %.5f | SL dist: %.5f | Risk: %.2f | Lots: %.2f",
                     entry_price, stop_loss, take_profit, sl_distance, risk_amount, final_lot);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action    = TRADE_ACTION_DEAL;
      request.symbol    = _Symbol;
      request.volume    = final_lot;
      request.type      = ORDER_TYPE_BUY;
      request.price     = entry_price;
      request.sl        = stop_loss;
      request.tp        = take_profit;
      request.deviation = 10;
      request.magic     = Magic_Number;
      request.comment   = "SMMA Long Trade";

      if (OrderSend(request, result))
      {
         if(Print_Logs) Print("Buy order opened: ", result.order, " Lot: ", final_lot);
         last_trade_direction = 1;
      }
      else
         if(Print_Logs) Print("Buy order failed: ", result.retcode, " ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Execute short trade                                              |
//+------------------------------------------------------------------+
void ExecuteShortTrade(double cci_value)
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stop_loss   = 0;
   double take_profit = 0;

   // === TASK 2: SL placed so that the distance = Risk_Percentage of account balance ===
   if (Use_SL)
   {
      double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_amount     = account_balance * (Risk_Percentage / 100.0);

      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double lot_size   = CalculateLotSize(cci_value);

      double value_per_lot_per_tick = tick_value / tick_size;
      double sl_distance = (lot_size > 0 && value_per_lot_per_tick > 0)
                           ? risk_amount / (lot_size * value_per_lot_per_tick)
                           : 0;

      stop_loss = NormalizeDouble(entry_price + sl_distance, _Digits);

      if (Use_TP)
         take_profit = NormalizeDouble(entry_price - sl_distance * Take_Profit_Ratio, _Digits);

      double final_lot = lot_size;
      if (final_lot <= 0.0) return;

      if (Print_Logs)
         PrintFormat("Short | Entry: %.5f | SL: %.5f | TP: %.5f | SL dist: %.5f | Risk: %.2f | Lots: %.2f",
                     entry_price, stop_loss, take_profit, sl_distance, risk_amount, final_lot);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action    = TRADE_ACTION_DEAL;
      request.symbol    = _Symbol;
      request.volume    = final_lot;
      request.type      = ORDER_TYPE_SELL;
      request.price     = entry_price;
      request.sl        = stop_loss;
      request.tp        = take_profit;
      request.deviation = 10;
      request.magic     = Magic_Number;
      request.comment   = "SMMA Short Trade";

      if (OrderSend(request, result))
      {
         if(Print_Logs) Print("Sell order opened: ", result.order, " Lot: ", final_lot);
         last_trade_direction = -1;
      }
      else
         if(Print_Logs) Print("Sell order failed: ", result.retcode, " ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size with optional CCI momentum boost             |
//| cci_value: current CCI reading on signal bar                    |
//|                                                                  |
//| TASK 1: If CCI is in momentum zone (e.g. 90–100 for long,       |
//|         -100–-90 for short) multiply lot by CCI_Momentum_Multiplier |
//+------------------------------------------------------------------+
double CalculateLotSize(double cci_value)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Base lot: manual if set, else minimum
   double base_lot = (Manual_Lot_Size > 0.0) ? Manual_Lot_Size : min_lot;

   // === TASK 1: CCI momentum zone check ===
   // Long momentum:  CCI between +CCI_Momentum_Min and +CCI_Momentum_Max
   // Short momentum: CCI between -CCI_Momentum_Max and -CCI_Momentum_Min
   bool in_momentum_zone = false;
   if (UseCCI_Momentum)
   {
      bool long_momentum  = (cci_value >= CCI_Momentum_Min  && cci_value <= CCI_Momentum_Max);
      bool short_momentum = (cci_value <= -CCI_Momentum_Min && cci_value >= -CCI_Momentum_Max);
      in_momentum_zone    = (long_momentum || short_momentum);
   }

   double lots = base_lot;
   if (in_momentum_zone)
      lots = base_lot * CCI_Momentum_Multiplier;

   // Normalize to lot step and clamp
   lots = MathFloor(lots / lot_step) * lot_step;
   lots = MathMax(min_lot, MathMin(lots, max_lot));

   if (Print_Logs)
      PrintFormat("LotSize | Base: %.2f | CCI: %.2f | Momentum: %s | Final: %.2f",
                  base_lot, cci_value, in_momentum_zone ? "YES" : "NO", lots);

   return lots;
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (PositionSelectByTicket(PositionGetTicket(i)))
      {
         if (PositionGetInteger(POSITION_MAGIC) == Magic_Number &&
             PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Manage open positions (trailing stop, breakeven, etc.)           |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if (!UseTrailingStop) return;

   double atr_buffer[1];
   if (CopyBuffer(hATR, 0, 1, 1, atr_buffer) != 1)  // Get latest closed bar ATR
   {
      if (Print_Logs) Print("Failed to copy ATR buffer");
      return;
   }
   double atr_value = atr_buffer[0];
   if (atr_value == 0.0) return;  // Invalid ATR

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;

      if(PositionGetInteger(POSITION_MAGIC)     != Magic_Number)   continue;
      if(PositionGetString(POSITION_SYMBOL)     != _Symbol)        continue;

      ulong  ticket     = PositionGetInteger(POSITION_TICKET);
      int    type       = (int)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);

      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      // Normalize trailing values to symbol digits
      double trail_start = TrailingStart   * point;
      double trail_step  = NormalizeDouble(atr_value * ATR_Multiplier, _Digits);
      double min_dist    = TrailingMinDistance * point;

      double new_sl = 0.0;

      if(type == POSITION_TYPE_BUY)
      {
         double profit = bid - open_price;

         if(profit < trail_start) continue;  // not yet in profit enough

         double desired_sl = NormalizeDouble(bid - trail_step, _Digits);

         // Only move SL if it improves position and respects minimum distance
         if((current_sl == 0.0 || desired_sl > current_sl + point) &&
            (bid - desired_sl >= min_dist))
         {
            new_sl = desired_sl;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit = open_price - ask;

         if(profit < trail_start) continue;

         double desired_sl = NormalizeDouble(ask + trail_step, _Digits);

         if((current_sl == 0.0 || desired_sl < current_sl - point) &&
            (desired_sl - ask >= min_dist))
         {
            new_sl = desired_sl;
         }
      }

      if(new_sl > 0.0 && MathAbs(new_sl - current_sl) > point)
      {
         MqlTradeRequest request = {};
         MqlTradeResult  result  = {};

         request.action   = TRADE_ACTION_SLTP;
         request.position = ticket;
         request.symbol   = _Symbol;
         request.sl       = new_sl;
         request.tp       = current_tp;           // keep existing TP
         request.magic    = Magic_Number;

         if(!OrderSend(request, result))
         {
            if(Print_Logs)
               PrintFormat("Trailing SL failed | Ticket: %I64u | Retcode: %u | %s",
                           ticket, result.retcode, result.comment);
         }
         else
         {
            if(Print_Logs)
               PrintFormat("Trailing SL updated | Ticket: %I64u | New SL: %.5f (ATR: %.5f)",
                           ticket, new_sl, atr_value);
         }
      }
   }
}