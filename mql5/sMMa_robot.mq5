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
input int    SMMA_Length       = 100;           // SMMA Period
input bool   Use_Retests       = true;         // Enable Retests
input double Retest_Depth      = 0.1;          // Retest Depth (%)
input double Risk_Percentage   = 2.0;          // Risk % per trade
input double Take_Profit_Ratio = 3.0;          // TP/SL ratio
input int    Max_Positions     = 1;            // Max simultaneous positions
input bool   Use_SL            = true;         // Use stop loss
input bool   Use_TP            = true;         // Use take profit
input int    Magic_Number      = 100001;       // Magic number for identification
input bool   Print_Logs        = true;         // Print debug info
input double Manual_Lot_Size   = 0.05;          // Set >0 for manual lot size, 0 for auto

input bool   UseTrailingStop    = true;          // Enable trailing stop
input double TrailingStart      = 100.0;          // Points in profit to start trailing
input double TrailingStep       = 30.0;          // Trailing distance in points
input double TrailingMinDistance= 10.0;          // Minimum allowed trailing distance
input int    ATR_Period        = 15;            // ATR Period
input double ATR_Multiplier    = 6;           // ATR Multiplier for trailing distance
input bool   UseCCI_Confluence   = true;         // Enable CCI-based lot size reduction on overbought/oversold
input double CCI_Overbought      = 90.0;         // CCI level that starts reducing long lot size
input double CCI_Oversold        = -90.0;        // CCI level that starts reducing short lot size
input double CCI_Max_Penalty     = 0.65;         // Maximum reduction factor (0.65 = -35% lot size)

//--- Indicator handles
int hSMMA_High  = INVALID_HANDLE;
int hSMMA_Low   = INVALID_HANDLE;
int hSMMA_Close = INVALID_HANDLE;
int hCCI        = INVALID_HANDLE;
int hATR = INVALID_HANDLE;

//--- Buffers for indicator values
double Buffer_SMMA_High[];
double Buffer_SMMA_Low[];
double Buffer_SMMA_Close[];
double Buffer_CCI[];

//--- Persistent bias
double bias = 0;

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
   if (CopyBuffer(hSMMA_High,  0, 0, 5, Buffer_SMMA_High)  < 5) return;
   if (CopyBuffer(hSMMA_Low,   0, 0, 5, Buffer_SMMA_Low)   < 5) return;
   if (CopyBuffer(hSMMA_Close, 0, 0, 5, Buffer_SMMA_Close) < 5) return;
   if (CopyBuffer(hCCI,        0, 0, 5, Buffer_CCI)        < 5) return;

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
      bool long_entry  = (long_breakout || long_retest)  && (close_price > open_price);
      bool short_entry = (short_breakout || short_retest) && (close_price < open_price);

      // Get CCI value for overbought/oversold filter
      double cci_value = Buffer_CCI[1];
      // === CCI CONFLUENCE FOR DYNAMIC LOT SIZING (only affects lots) ===
      double cci_multiplier = 1.0;
      if (UseCCI_Confluence)
      {
         if (long_entry && cci_value >= CCI_Overbought)  cci_multiplier = CCI_Max_Penalty;
         if (short_entry && cci_value <= CCI_Oversold)   cci_multiplier = CCI_Max_Penalty;
      }
      
      if (long_entry && cci_value < CCI_Overbought)  // Avoid long if overbought
      {
         if(Print_Logs) Print("Long signal detected on closed bar | Price: ", close_price, " | CCI: ", cci_value);
         ExecuteLongTrade(close_price, low_price, cci_multiplier);
      }
      if (short_entry && cci_value > CCI_Oversold)  // Avoid short if oversold
      {
         if(Print_Logs) Print("Short signal detected on closed bar | Price: ", close_price, " | CCI: ", cci_value);
         ExecuteShortTrade(close_price, high_price, cci_multiplier);
      }
   }

   ManagePositions();
}

//+------------------------------------------------------------------+
//| Execute long trade                                               |
//+------------------------------------------------------------------+
void ExecuteLongTrade(double signal_price, double entry_low, double cci_multiplier = 1.0)
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stop_loss = 0;
   double take_profit = 0;
   
   if (Use_SL)
   {
      stop_loss = entry_low;
   }
   
   if (Use_TP)
   {
      double risk = entry_price - stop_loss;
      take_profit = entry_price + (risk * Take_Profit_Ratio);
   }
   
   // Calculate lot size based on risk
   double lot_size = CalculateLotSize(entry_price, stop_loss, cci_multiplier);
   
   // Open buy order using CTrade
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = lot_size;
   request.type     = ORDER_TYPE_BUY;
   request.price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.sl       = stop_loss;
   request.tp       = take_profit;
   request.deviation= 10;
   request.magic    = Magic_Number;
   request.comment  = "SMMA Long Trade";

   if (OrderSend(request, result))
   {
      if(Print_Logs) Print("Buy order opened: ", result.order, " Lot: ", lot_size);
   }
   else
   {
      if(Print_Logs) Print("Buy order failed: ", result.retcode, " ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Execute short trade                                              |
//+------------------------------------------------------------------+
void ExecuteShortTrade(double signal_price, double entry_high, double cci_multiplier = 1.0)
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stop_loss = 0;
   double take_profit = 0;
   
   if (Use_SL)
   {
      stop_loss = entry_high;
   }
   
   if (Use_TP)
   {
      double risk = stop_loss - entry_price;
      take_profit = entry_price - (risk * Take_Profit_Ratio);
   }
   
   // Calculate lot size based on risk
   double lot_size = CalculateLotSize(entry_price, stop_loss, cci_multiplier);
   
   // Open sell order using CTrade
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = lot_size;
   request.type     = ORDER_TYPE_SELL;
   request.price    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.sl       = stop_loss;
   request.tp       = take_profit;
   request.deviation= 10;
   request.magic    = Magic_Number;
   request.comment  = "SMMA Short Trade";

   if (OrderSend(request, result))
   {
      if(Print_Logs) Print("Sell order opened: ", result.order, " Lot: ", lot_size);
   }
   else
   {
      if(Print_Logs) Print("Sell order failed: ", result.retcode, " ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry_price, double stop_loss, double cci_multiplier = 1.0)
{
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Use manual lot size if set (>0)
   if (Manual_Lot_Size > 0.0)
   {
      double lots = Manual_Lot_Size;
      lots = MathFloor(lots / lot_step) * lot_step;
      lots = MathMax(min_lot, MathMin(lots, max_lot));
      return lots;
   }

   if (stop_loss == 0 || entry_price == 0)
      return min_lot;

   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (Risk_Percentage / 100.0);

   double price_difference = MathAbs(entry_price - stop_loss);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   if (tick_size == 0 || tick_value == 0 || contract_size == 0 || price_difference == 0)
      return min_lot;

   double value_per_lot = (price_difference / tick_size) * tick_value;
   double lots = risk_amount / value_per_lot;

   // Apply CCI confluence penalty (only change for dynamic sizing)
   lots *= cci_multiplier;

   // Round down to nearest lot step and clamp
   lots = MathFloor(lots / lot_step) * lot_step;
   lots = MathMax(min_lot, MathMin(lots, max_lot));

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