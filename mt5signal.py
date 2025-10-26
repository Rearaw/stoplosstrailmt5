import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import talib
from datetime import datetime, timedelta

# Initialize MetaTrader5
if not mt5.initialize():
    print("MetaTrader5 initialization failed")
    mt5.shutdown()
    exit()

# Configuration
symbol = "XAUUSDm"
timeframe = mt5.TIMEFRAME_H1
start_date = datetime(2025, 1, 1)
end_date = datetime(2025, 10, 25)
rsi_period = 14
macd_fast = 12
macd_slow = 26
macd_signal = 9
lot_size = 0.1
sl_pips = 20
tp_pips = 40

# Fetch historical data
def get_price_data(symbol, timeframe, start_date, end_date):
    rates = mt5.copy_rates_range(symbol, timeframe, start_date, end_date)
    if rates is None or len(rates) == 0:
        print("Error fetching data")
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

# Calculate indicators
def calculate_indicators(df):
    df['rsi'] = talib.RSI(df['close'], timeperiod=rsi_period)
    df['macd'], df['macd_signal'], df['macd_hist'] = talib.MACD(
        df['close'], fastperiod=macd_fast, slowperiod=macd_slow, signalperiod=macd_signal
    )
    df['volume'] = df['tick_volume']
    return df.dropna()  # Drop NaN rows to avoid comparison issues

# Detect divergence
def detect_divergence(df, indicator='rsi', lookback=5):
    signals = [None] * len(df)  # Initialize with None for all rows
    for i in range(lookback, len(df)):
        price = df['close'].iloc[i-lookback:i+1]
        ind = df[indicator].iloc[i-lookback:i+1]
        
        # Ensure no NaN in slice
        if price.isna().any() or ind.isna().any():
            continue
        
        # Find peaks and troughs
        price_highs = (price.iloc[1:-1] > price.iloc[:-2]) & (price.iloc[1:-1] > price.iloc[2:])
        price_lows = (price.iloc[1:-1] < price.iloc[:-2]) & (price.iloc[1:-1] < price.iloc[2:])
        ind_highs = (ind.iloc[1:-1] > ind.iloc[:-2]) & (ind.iloc[1:-1] > ind.iloc[2:])
        ind_lows = (ind.iloc[1:-1] < ind.iloc[:-2]) & (ind.iloc[1:-1] < ind.iloc[2:])
        
        curr_idx = lookback - 1
        price_highs_idx = price_highs.index[price_highs]
        price_lows_idx = price_lows.index[price_lows]
        ind_highs_idx = ind_highs.index[ind_highs]
        ind_lows_idx = ind_lows.index[ind_lows]
        
        # Bullish Divergence
        if price_lows.iloc[curr_idx]:
            price_low = price.iloc[curr_idx]
            ind_low = ind.iloc[curr_idx]
            prev_price_lows = price.iloc[:curr_idx][price_lows.iloc[:curr_idx]]
            prev_ind_lows = ind.iloc[:curr_idx][ind_lows.iloc[:curr_idx]]
            if len(prev_price_lows) > 0 and len(prev_ind_lows) > 0:
                if price_low < prev_price_lows.min() and ind_low > prev_ind_lows.min():
                    signals[i] = 'BULLISH_DIVERGENCE'
        
        # Bearish Divergence
        elif price_highs.iloc[curr_idx]:
            price_high = price.iloc[curr_idx]
            ind_high = ind.iloc[curr_idx]
            prev_price_highs = price.iloc[:curr_idx][price_highs.iloc[:curr_idx]]
            prev_ind_highs = ind.iloc[:curr_idx][ind_highs.iloc[:curr_idx]]
            if len(prev_price_highs) > 0 and len(prev_ind_highs) > 0:
                if price_high > prev_price_highs.max() and ind_high < prev_ind_highs.max():
                    signals[i] = 'BEARISH_DIVERGENCE'
    
    return pd.Series(signals, index=df.index)

# Generate signals
def generate_signals(df):
    signals = []
    positions = []
    position = None
    entry_price = 0
    trades = []
    
    df['rsi_div'] = detect_divergence(df, 'rsi', lookback=5)
    df['macd_div'] = detect_divergence(df, 'macd', lookback=5)
    
    for i in range(2, len(df)):
        rsi_current = df['rsi'].iloc[i]
        rsi_prev = df['rsi'].iloc[i-1]
        macd_current = df['macd'].iloc[i]
        macd_signal_current = df['macd_signal'].iloc[i]
        macd_hist_current = df['macd_hist'].iloc[i]
        macd_prev = df['macd'].iloc[i-1]
        macd_signal_prev = df['macd_signal'].iloc[i-1]
        volume_current = df['volume'].iloc[i]
        volume_prev = df['volume'].iloc[i-1]
        rsi_div = df['rsi_div'].iloc[i]
        macd_div = df['macd_div'].iloc[i]
        price = df['close'].iloc[i]
        signal = None

        # Buy Signal
        if ((rsi_prev <= 30 and rsi_current > 30 and
             macd_prev <= macd_signal_prev and macd_current > macd_signal_current and
             macd_hist_current > 0 and volume_current > volume_prev) or
            rsi_div == 'BULLISH_DIVERGENCE' or macd_div == 'BULLISH_DIVERGENCE'):
            if position != 'buy':
                signal = 'BUY'
                if position == 'sell':
                    profit = (entry_price - price) * lot_size * 100000
                    trades.append({'type': 'SELL', 'entry': entry_price, 'exit': price, 'profit': profit})
                position = 'buy'
                entry_price = price

        # Sell Signal
        elif ((rsi_prev >= 70 and rsi_current < 70 and
               macd_prev >= macd_signal_prev and macd_current < macd_signal_current and
               macd_hist_current < 0 and volume_current > volume_prev) or
              rsi_div == 'BEARISH_DIVERGENCE' or macd_div == 'BEARISH_DIVERGENCE'):
            if position != 'sell':
                signal = 'SELL'
                if position == 'buy':
                    profit = (price - entry_price) * lot_size * 100000
                    trades.append({'type': 'BUY', 'entry': entry_price, 'exit': price, 'profit': profit})
                position = 'sell'
                entry_price = price

        # Stop-loss/Take-profit
        if position == 'buy':
            sl = entry_price - sl_pips * mt5.symbol_info(symbol).point
            tp = entry_price + tp_pips * mt5.symbol_info(symbol).point
            if price <= sl:
                signal = 'CLOSE BUY (SL)'
                profit = (sl - entry_price) * lot_size * 100000
                trades.append({'type': 'BUY', 'entry': entry_price, 'exit': sl, 'profit': profit})
                position = None
            elif price >= tp:
                signal = 'CLOSE BUY (TP)'
                profit = (tp - entry_price) * lot_size * 100000
                trades.append({'type': 'BUY', 'entry': entry_price, 'exit': tp, 'profit': profit})
                position = None
        elif position == 'sell':
            sl = entry_price + sl_pips * mt5.symbol_info(symbol).point
            tp = entry_price - tp_pips * mt5.symbol_info(symbol).point
            if price >= sl:
                signal = 'CLOSE SELL (SL)'
                profit = (entry_price - sl) * lot_size * 100000
                trades.append({'type': 'SELL', 'entry': entry_price, 'exit': sl, 'profit': profit})
                position = None
            elif price <= tp:
                signal = 'CLOSE SELL (TP)'
                profit = (entry_price - tp) * lot_size * 100000
                trades.append({'type': 'SELL', 'entry': entry_price, 'exit': tp, 'profit': profit})
                position = None

        signals.append(signal)
        positions.append(position)

    signals = [None] * 2 + signals
    positions = [None] * 2 + positions
    df['signal'] = pd.Series(signals, index=df.index)
    df['position'] = pd.Series(positions, index=df.index)
    return df, trades

# Calculate backtest performance
def backtest_performance(trades):
    total_trades = len(trades)
    if total_trades == 0:
        return None
    wins = sum(1 for trade in trades if trade['profit'] > 0)
    total_profit = sum(trade['profit'] for trade in trades)
    win_rate = wins / total_trades * 100 if total_trades > 0 else 0
    return {
        'total_trades': total_trades,
        'win_rate': win_rate,
        'total_profit': total_profit,
        'avg_profit_per_trade': total_profit / total_trades if total_trades > 0 else 0
    }

# Main execution
try:
    if not mt5.symbol_select(symbol, True):
        print(f"Failed to select {symbol}")
        mt5.shutdown()
        exit()

    df = get_price_data(symbol, timeframe, start_date, end_date)
    if df is None:
        mt5.shutdown()
        exit()

    df = calculate_indicators(df)
    df, trades = generate_signals(df)

    print(f"\nRecent {symbol} Signals (Last 10 Candles):")
    print(df[['close', 'rsi', 'macd', 'macd_signal', 'macd_hist', 'rsi_div', 'macd_div', 'signal']].tail(10))

    df.to_csv(f"{symbol}_backtest_signals.csv")

    performance = backtest_performance(trades)
    if performance:
        print("\nBacktest Performance:")
        print(f"Total Trades: {performance['total_trades']}")
        print(f"Win Rate: {performance['win_rate']:.2f}%")
        print(f"Total Profit: ${performance['total_profit']:.2f}")
        print(f"Average Profit per Trade: ${performance['avg_profit_per_trade']:.2f}")

except Exception as e:
    print(f"Error: {e}")
finally:
    mt5.shutdown()