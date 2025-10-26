import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import talib
import matplotlib.pyplot as plt
from datetime import datetime, timedelta

# Custom function to calculate Ichimoku Cloud components
def ichimoku_cloud(high, low, close, tenkan=9, kijun=26, senkou=52):
    """
    Calculate Ichimoku Cloud components using TA-Lib functions.
    Returns: Tenkan-sen, Kijun-sen, Senkou Span A, Senkou Span B, Chikou Span
    """
    # Tenkan-sen: (9-period high + 9-period low) / 2
    tenkan_high = talib.MAX(high, timeperiod=tenkan)
    tenkan_low = talib.MIN(low, timeperiod=tenkan)
    tenkan_sen = (tenkan_high + tenkan_low) / 2

    # Kijun-sen: (26-period high + 26-period low) / 2
    kijun_high = talib.MAX(high, timeperiod=kijun)
    kijun_low = talib.MIN(low, timeperiod=kijun)
    kijun_sen = (kijun_high + kijun_low) / 2

    # Senkou Span A: (Tenkan-sen + Kijun-sen) / 2, shifted forward 26 periods
    senkou_a = ((tenkan_sen + kijun_sen) / 2).shift(kijun)

    # Senkou Span B: (52-period high + 52-period low) / 2, shifted forward 26 periods
    senkou_b_high = talib.MAX(high, timeperiod=senkou)
    senkou_b_low = talib.MIN(low, timeperiod=senkou)
    senkou_b = ((senkou_b_high + senkou_b_low) / 2).shift(kijun)

    # Chikou Span: Close price shifted backward 26 periods
    chikou = close.shift(-kijun)

    return tenkan_sen, kijun_sen, senkou_a, senkou_b, chikou

# Initialize MT5 connection
if not mt5.initialize():
    print("MT5 initialization failed:", mt5.last_error())
    quit()

# Set symbol and timeframe
symbol = "USDJPYm"
timeframe = mt5.TIMEFRAME_H1  # 1-hour timeframe
days = 90  # 90 days of historical data

# Fetch historical data
end_date = datetime.now()
start_date = end_date - timedelta(days=days)
rates = mt5.copy_rates_range(symbol, timeframe, start_date, end_date)

# Validate data
if rates is None or len(rates) == 0:
    print(f"No data retrieved for {symbol}:", mt5.last_error())
    mt5.shutdown()
    quit()

# Convert to DataFrame
df = pd.DataFrame(rates)
df['time'] = pd.to_datetime(df['time'], unit='s')
df.set_index('time', inplace=True)

# Verify data
print(f"Data fetched: {len(df)} bars for {symbol}")

# Calculate indicators
# Ichimoku Cloud
df['Tenkan_sen'], df['Kijun_sen'], df['Senkou_A'], df['Senkou_B'], df['Chikou'] = ichimoku_cloud(
    df['high'], df['low'], df['close'], tenkan=9, kijun=26, senkou=52)

# ATR
df['ATR'] = talib.ATR(df['high'], df['low'], df['close'], timeperiod=14)

# RSI
df['RSI'] = talib.RSI(df['close'], timeperiod=14)

# Drop rows with NaN values (due to lookback periods)
df.dropna(inplace=True)

# Generate signals
df['Signal'] = 0
df['Position'] = 0

# Detect Tenkan/Kijun crossovers
df['Tenkan_above_Kijun'] = (df['Tenkan_sen'] > df['Kijun_sen']).astype(int)
df['Tenkan_below_Kijun'] = (df['Tenkan_sen'] < df['Kijun_sen']).astype(int)

# Buy: Price above cloud, Tenkan > Kijun, RSI < 40
df.loc[(df['close'] > df['Senkou_A']) & 
       (df['close'] > df['Senkou_B']) & 
       (df['Tenkan_above_Kijun'] == 1) & 
       (df['RSI'] < 40), 'Signal'] = 1

# Sell: Price below cloud, Tenkan < Kijun, RSI > 60
df.loc[(df['close'] < df['Senkou_A']) & 
       (df['close'] < df['Senkou_B']) & 
       (df['Tenkan_below_Kijun'] == 1) & 
       (df['RSI'] > 60), 'Signal'] = -1

# Calculate positions (hold until opposite signal)
position = 0
positions = []
for i in range(len(df)):
    if df['Signal'].iloc[i] == 1 and position == 0:
        position = 1  # Enter long
    elif df['Signal'].iloc[i] == -1 and position == 0:
        position = -1  # Enter short
    elif df['Signal'].iloc[i] == -1 and position == 1:
        position = 0  # Exit long
    elif df['Signal'].iloc[i] == 1 and position == -1:
        position = 0  # Exit short
    positions.append(position)

df['Position'] = positions

# Calculate stop-loss and take-profit (2x ATR)
df['Stop_Loss'] = np.where(df['Position'] == 1, df['close'] - 2 * df['ATR'], 
                           np.where(df['Position'] == -1, df['close'] + 2 * df['ATR'], np.nan))
df['Take_Profit'] = np.where(df['Position'] == 1, df['close'] + 2 * df['ATR'], 
                             np.where(df['Position'] == -1, df['close'] - 2 * df['ATR'], np.nan))

# Backtest: Calculate returns
df['Returns'] = df['close'].pct_change()
df['Strategy_Returns'] = df['Position'].shift(1) * df['Returns']  # Shift to avoid look-ahead bias

# Handle stop-loss/take-profit exits
for i in range(1, len(df)):
    if df['Position'].iloc[i] == 1:  # Long position
        if df['low'].iloc[i] <= df['Stop_Loss'].iloc[i-1]:
            df['Position'].iloc[i] = 0  # Exit on stop-loss
            df['Strategy_Returns'].iloc[i] = (df['Stop_Loss'].iloc[i-1] - df['close'].iloc[i-1]) / df['close'].iloc[i-1]
        elif df['high'].iloc[i] >= df['Take_Profit'].iloc[i-1]:
            df['Position'].iloc[i] = 0  # Exit on take-profit
            df['Strategy_Returns'].iloc[i] = (df['Take_Profit'].iloc[i-1] - df['close'].iloc[i-1]) / df['close'].iloc[i-1]
    elif df['Position'].iloc[i] == -1:  # Short position
        if df['high'].iloc[i] >= df['Stop_Loss'].iloc[i-1]:
            df['Position'].iloc[i] = 0  # Exit on stop-loss
            df['Strategy_Returns'].iloc[i] = (df['close'].iloc[i-1] - df['Stop_Loss'].iloc[i-1]) / df['close'].iloc[i-1]
        elif df['low'].iloc[i] <= df['Take_Profit'].iloc[i-1]:
            df['Position'].iloc[i] = 0  # Exit on take-profit
            df['Strategy_Returns'].iloc[i] = (df['close'].iloc[i-1] - df['Take_Profit'].iloc[i-1]) / df['close'].iloc[i-1]

# Cumulative returns
df['Cumulative_Strategy'] = (1 + df['Strategy_Returns']).cumprod()
df['Cumulative_Market'] = (1 + df['Returns']).cumprod()

# Performance metrics
total_return = df['Cumulative_Strategy'].iloc[-1] - 1
num_trades = len(df[df['Signal'] != 0])
win_rate = len(df[(df['Strategy_Returns'] > 0) & (df['Position'] != 0)]) / num_trades if num_trades > 0 else 0

print(f"Total Strategy Return: {total_return:.2%}")
print(f"Number of Trades: {num_trades}")
print(f"Win Rate: {win_rate:.2%}")

# Plotting
plt.figure(figsize=(14, 10))

# Plot 1: Price and Ichimoku Cloud
plt.subplot(3, 1, 1)
plt.plot(df.index, df['close'], label='Close Price', color='blue')
plt.plot(df.index, df['Tenkan_sen'], label='Tenkan-sen', color='orange')
plt.plot(df.index, df['Kijun_sen'], label='Kijun-sen', color='purple')
plt.fill_between(df.index, df['Senkou_A'], df['Senkou_B'], 
                 where=df['Senkou_A'] >= df['Senkou_B'], color='green', alpha=0.3, label='Cloud (Bullish)')
plt.fill_between(df.index, df['Senkou_A'], df['Senkou_B'], 
                 where=df['Senkou_A'] < df['Senkou_B'], color='red', alpha=0.3, label='Cloud (Bearish)')
plt.plot(df.index[df['Signal'] == 1], df['close'][df['Signal'] == 1], '^', markersize=10, color='green', label='Buy Signal')
plt.plot(df.index[df['Signal'] == -1], df['close'][df['Signal'] == -1], 'v', markersize=10, color='red', label='Sell Signal')
plt.title(f'{symbol} Price and Ichimoku Cloud')
plt.legend()

# Plot 2: RSI
plt.subplot(3, 1, 2)
plt.plot(df.index, df['RSI'], label='RSI', color='purple')
plt.axhline(70, color='red', linestyle='--', alpha=0.5)
plt.axhline(30, color='green', linestyle='--', alpha=0.5)
plt.title('RSI')
plt.legend()

# Plot 3: Cumulative Returns
plt.subplot(3, 1, 3)
plt.plot(df.index, df['Cumulative_Strategy'], label='Strategy Returns', color='blue')
plt.plot(df.index, df['Cumulative_Market'], label='Market Returns', color='gray')
plt.title('Cumulative Returns')
plt.legend()

plt.tight_layout()
plt.show()

# Fetch real-time data (latest 100 bars)
rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, 100)
if rates is None or len(rates) == 0:
    print(f"Failed to fetch real-time data: {mt5.last_error()}")
    mt5.shutdown()
    quit()

# Convert to DataFrame
df_live = pd.DataFrame(rates)
df_live['time'] = pd.to_datetime(df_live['time'], unit='s')
df_live.set_index('time', inplace=True)

# Calculate indicators
df_live['Tenkan_sen'], df_live['Kijun_sen'], df_live['Senkou_A'], df_live['Senkou_B'], df_live['Chikou'] = ichimoku_cloud(
    df_live['high'], df_live['low'], df_live['close'], tenkan=9, kijun=26, senkou=52)
df_live['RSI'] = talib.RSI(df_live['close'], timeperiod=14)
df_live['ATR'] = talib.ATR(df_live['high'], df_live['low'], df_live['close'], timeperiod=14)

# Latest signal
latest_data = df_live.iloc[-1]
buy_signal = (latest_data['close'] > latest_data['Senkou_A'] and 
              latest_data['close'] > latest_data['Senkou_B'] and 
              latest_data['Tenkan_sen'] > latest_data['Kijun_sen'] and 
              latest_data['RSI'] < 40)
sell_signal = (latest_data['close'] < latest_data['Senkou_A'] and 
               latest_data['close'] < latest_data['Senkou_B'] and 
               latest_data['Tenkan_sen'] < latest_data['Kijun_sen'] and 
               latest_data['RSI'] > 60)

print(f"Latest Price: {latest_data['close']:.5f}")
print(f"Buy Signal: {buy_signal}, Sell Signal: {sell_signal}")

# Example: Place a buy order (use demo account for testing)
if buy_signal:
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"Symbol {symbol} not found")
        mt5.shutdown()
        quit()

    # Prepare trade request
    lot = 0.1
    price = mt5.symbol_info_tick(symbol).ask
    sl = price - 2 * latest_data['ATR']
    tp = price + 2 * latest_data['ATR']
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": mt5.ORDER_TYPE_BUY,
        "price": price,
        "sl": sl,
        "tp": tp,
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    # Send order
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"Order failed: {result.comment}")
    else:
        print(f"Order placed: {result.order}")

# Shutdown MT5
mt5.shutdown()