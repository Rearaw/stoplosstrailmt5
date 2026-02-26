//+------------------------------------------------------------------+
//|                                                smma_straregy.mq5 |
//|                                                           rearaw |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "rearaw"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property indicator_chart_window
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window  // Plots on main chart
#property indicator_buffers 5     // 3 SMMAs + 2 arrows
#property indicator_plots   5

// Plot properties for SMMAs
#property indicator_label1  "SMMA High"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_DASHDOTDOT
#property indicator_width1  1

#property indicator_label2  "SMMA Low"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_DASHDOTDOT
#property indicator_width2  1

#property indicator_label3  "SMMA Close"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrWhiteSmoke
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

// Plot properties for arrows
#property indicator_label4  "Buy Signal"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_style4  STYLE_SOLID
#property indicator_width4  1

#property indicator_label5  "Sell Signal"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_style5  STYLE_SOLID
#property indicator_width5  1

// Inputs (same as EA)
input int    SMMA_Length      = 70;      // SMMA Period
input bool   Use_Retests      = true;    // Enable Retests
input double Retest_Depth     = 0.1;     // Retest Depth (%)

// Buffers
double Buffer_SMMA_High[];
double Buffer_SMMA_Low[];
double Buffer_SMMA_Close[];
double Buffer_Buy_Arrow[];
double Buffer_Sell_Arrow[];

// Indicator handles (for built-in iMA)
int hSMMA_High  = INVALID_HANDLE;
int hSMMA_Low   = INVALID_HANDLE;
int hSMMA_Close = INVALID_HANDLE;

// Persistent bias (stored as a global for statefulness)
double bias = 0;
//+------------------------------------------------------------------+
int OnInit()
{
   // Assign buffers
   SetIndexBuffer(0, Buffer_SMMA_High, INDICATOR_DATA);
   SetIndexBuffer(1, Buffer_SMMA_Low, INDICATOR_DATA);
   SetIndexBuffer(2, Buffer_SMMA_Close, INDICATOR_DATA);
   SetIndexBuffer(3, Buffer_Buy_Arrow, INDICATOR_DATA);
   SetIndexBuffer(4, Buffer_Sell_Arrow, INDICATOR_DATA);
   
   // Set arrow codes using MQL5-compatible function
   PlotIndexSetInteger(3, PLOT_ARROW, 233);  // Buy arrow (e.g., up arrow symbol)
   PlotIndexSetInteger(4, PLOT_ARROW, 234);  // Sell arrow (e.g., down arrow symbol)
   
   // Create SMMA handles
   hSMMA_High = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_HIGH);
   if (hSMMA_High == INVALID_HANDLE) { Print("Failed to create SMMA High"); return(INIT_FAILED); }
   
   hSMMA_Low = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_LOW);
   if (hSMMA_Low == INVALID_HANDLE) { Print("Failed to create SMMA Low"); return(INIT_FAILED); }
   
   hSMMA_Close = iMA(NULL, 0, SMMA_Length, 0, MODE_SMMA, PRICE_CLOSE);
   if (hSMMA_Close == INVALID_HANDLE) { Print("Failed to create SMMA Close"); return(INIT_FAILED); }
   
   // Set empty values for arrows (to hide when no signal)

   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason)
{
   if (hSMMA_High != INVALID_HANDLE) IndicatorRelease(hSMMA_High);
   if (hSMMA_Low != INVALID_HANDLE) IndicatorRelease(hSMMA_Low);
   if (hSMMA_Close != INVALID_HANDLE) IndicatorRelease(hSMMA_Close);
}
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Limit calculation to new bars
   int limit = rates_total - prev_calculated;
   if (limit <= 0) return(rates_total);
   
   // Copy SMMA values (shifted for historical bars)
   if (CopyBuffer(hSMMA_High, 0, 0, rates_total, Buffer_SMMA_High) < rates_total) return(0);
   if (CopyBuffer(hSMMA_Low, 0, 0, rates_total, Buffer_SMMA_Low) < rates_total) return(0);
   if (CopyBuffer(hSMMA_Close, 0, 0, rates_total, Buffer_SMMA_Close) < rates_total) return(0);
   
   // Process from oldest to newest (for statefulness)
   for (int i = MathMax(prev_calculated - 1, 0); i < rates_total; i++)
   {
      // Update bias (persistent)
      if (close[i] > Buffer_SMMA_High[i]) bias = 1;
      else if (close[i] < Buffer_SMMA_Low[i]) bias = -1;
      // Else, bias persists
      
      // Breakouts (compare to previous bar)
      bool long_breakout = (close[i] > Buffer_SMMA_High[i]) && (i > 0 && close[i-1] <= Buffer_SMMA_High[i-1]);
      bool short_breakout = (close[i] < Buffer_SMMA_Low[i]) && (i > 0 && close[i-1] >= Buffer_SMMA_Low[i-1]);
      
      // Retest zone
      double zone_width = Buffer_SMMA_High[i] - Buffer_SMMA_Low[i];
      double retest_zone = zone_width * (Retest_Depth / 100.0);
      
      bool long_retest = Use_Retests && (bias == 1) && 
                         (low[i] <= Buffer_SMMA_Low[i] + retest_zone) && 
                         (close[i] > Buffer_SMMA_High[i]);
      
      bool short_retest = Use_Retests && (bias == -1) && 
                          (high[i] >= Buffer_SMMA_High[i] - retest_zone) && 
                          (close[i] < Buffer_SMMA_Low[i]);
      
      // Entries with candle check
      bool long_entry = (long_breakout || long_retest) && (close[i] > open[i]);
      bool short_entry = (short_breakout || short_retest) && (close[i] < open[i]);
      
      // Set arrows at low/high of bar for visibility
      Buffer_Buy_Arrow[i] = long_entry ? low[i] : EMPTY_VALUE;
      Buffer_Sell_Arrow[i] = short_entry ? high[i] : EMPTY_VALUE;
   }
   
   return(rates_total);
}