import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime
from typing import Literal, Optional, Dict, List
import os

Signal = Literal["bullish", "bearish", "squeeze", "none"]

# ============================= CONFIG =============================
SYMBOLS: List[str] = ["USDJPYm"]  # Add your symbols here
TIMEFRAME = mt5.TIMEFRAME_M15
SHORT_LEN = 9
LONG_LEN = 45
SHIFT = 0
SQUEEZE_WINDOW = 3
SQUEEZE_SIZE = 0.0005       # Adjust per symbol if needed (e.g., forex pips)
CHECK_INTERVAL = 60         # Check every 60 seconds
LOG_FILE = "signals_log.csv"  # Optional: Log signals to file
# =================================================================


def smma(series: pd.Series, length: int) -> pd.Series:
    """
    Smoothed Moving Average (Wilder's SMMA) - 100% compatible with MT5 iSMMA().
    
    Formula:
        SMMA_i = (SMMA_{i-1} * (length - 1) + price_i) / length
        Initial SMMA = SMA over first 'length' valid points
    """
    if length <= 0:
        raise ValueError("Length must be > 0")
    
    values = series.astype(float).values
    result = np.full_like(values, np.nan)
    
    # Find first index where we have 'length' consecutive non-NaN values
    start_idx = 0
    while start_idx + length <= len(values):
        window = values[start_idx:start_idx + length]
        if not np.any(np.isnan(window)):
            break
        start_idx += 1
    else:
        return pd.Series(result, index=series.index)
    
    # Initial SMA
    sma_val = np.mean(window)
    result[start_idx + length - 1] = sma_val  # Place at end of window
    
    # Apply SMMA forward
    for i in range(start_idx + length, len(values)):
        if np.isnan(values[i]):
            result[i] = np.nan
            continue
        prev = result[i - 1]
        if np.isnan(prev):
            # Find last valid SMMA
            j = i - 1
            while j >= 0 and np.isnan(result[j]):
                j -= 1
            if j < 0:
                result[i] = np.nan
                continue
            prev = result[j]
        result[i] = (prev * (length - 1) + values[i]) / length
    
    return pd.Series(result, index=series.index)


def get_rates(symbol: str, timeframe: int, bars: int) -> Optional[pd.DataFrame]:
    """Fetch latest OHLC data from MT5 for a specific symbol."""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        print(f"[{datetime.now()}] Failed to retrieve rates for {symbol}")
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df


def smma_crossover_strategy(
    df: pd.DataFrame,
    short_len: int,
    long_len: int,
    shift: int,
    squeeze_window: int,
    squeeze_size: float
) -> Dict[str, any]:
    """Core logic: return signal and metadata for one symbol."""
    required = max(long_len, short_len, squeeze_window + shift + 5)
    if len(df) < required:
        return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan}

    close = df['close']

    # Calculate SMMA
    short_smma = smma(close, short_len)
    long_smma = smma(close, long_len)

    # Get recent data points for convergence analysis
    lookback = 10  # Increased lookback for better trend analysis
    if len(short_smma) < lookback + shift + 2:
        return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan}

    # Get recent segments of both SMAs
    recent_short = short_smma.iloc[-(lookback + shift):].values
    recent_long = long_smma.iloc[-(lookback + shift):].values
    x_points = np.arange(len(recent_short))

    # Calculate differences
    differences = np.abs(recent_short - recent_long)
    
    # Fit a line to the differences to determine trend
    try:
        slope, _ = np.polyfit(x_points, differences, 1)
        tolerance = 0.0001
        
        # Determine which line is on top (latest point)
        position = "bullish" if recent_short[-1] > recent_long[-1] else "bearish"
        
        # Classify the trend
        if abs(slope) < tolerance:
            trend = f"parallel_{position}"
        elif slope < -tolerance:
            trend = f"converging_{position}"
        else:
            trend = f"diverging_{position}"
    except:
        trend = "unknown"

    # Current and previous points for crossover detection
    idx_curr = -(1 + shift)
    idx_prev = -(2 + shift)

    if idx_curr >= len(short_smma):
        return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan, "trend": trend}

    # short_curr = short_smma.iloc[idx_curr]
    # long_curr = long_smma.iloc[idx_curr]
    # short_prev = short_smma.iloc[idx_prev]
    # long_prev = long_smma.iloc[idx_prev]

    # if any(pd.isna([short_curr, long_curr, short_prev, long_prev])):
    #     return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan, "trend": trend}

    # # Crossover detection
    # golden_cross = (short_curr > long_curr) and (short_prev <= long_prev)
    # death_cross = (short_curr < long_curr) and (short_prev >= long_prev)

    # # Squeeze detection
    # squeeze_detected = False
    # for i in range(1, squeeze_window + 1):
    #     idx = -(1 + i)
    #     if idx >= len(short_smma):
    #         continue
    #     dist = abs(short_smma.iloc[idx] - long_smma.iloc[idx])
    #     if pd.notna(dist) and dist <= squeeze_size:
    #         squeeze_detected = True
    #         break

    # # Signal determination
    # if squeeze_detected:
    #     signal = "squeeze"
    # elif golden_cross:
    #     signal = "bullish"
    # elif death_cross:
    #     signal = "bearish"
    # else:
    #     signal = "none"

    return {
        "trend": trend
    }


def log_signals_to_file(results: pd.DataFrame):
    """Append current signals to CSV log file."""
    timestamp = datetime.now()
    log_df = results.copy()
    log_df['timestamp'] = timestamp
    log_df = log_df[['timestamp', 'symbol', 'signal', 'short_smma', 'long_smma', 'distance']]
    log_df.to_csv(LOG_FILE, mode='a', header=not os.path.exists(LOG_FILE), index=False)
    print(f"[{timestamp}] Signals logged to {LOG_FILE}")


# ============================= MAIN LOOP =============================
def main():
    if not mt5.initialize():
        print("MT5 initialization failed. Check if MT5 is running and logged in.")
        return

    account = mt5.account_info()
    print(f"Connected to MT5 | Account: {account.login} | Server: {account.server}")
    print(f"Monitoring symbols: {', '.join(SYMBOLS)} | Timeframe: {TIMEFRAME} | Check every {CHECK_INTERVAL}s")
    print(f"SMMA({SHORT_LEN}), SMMA({LONG_LEN}) | Squeeze: {SQUEEZE_WINDOW} bars, ≤ {SQUEEZE_SIZE}")

    last_signals: Dict[str, str] = {sym: "none" for sym in SYMBOLS}
    required_bars = (max(LONG_LEN, SHORT_LEN) + SQUEEZE_WINDOW + SHIFT )+24
    print("\nWaiting for signals...\n")

    while True:
        try:
            results_list = []
            for symbol in SYMBOLS:
                df = get_rates(symbol, TIMEFRAME, required_bars)
                if df is None or len(df) < required_bars:
                    continue

                result = smma_crossover_strategy(
                    df, SHORT_LEN, LONG_LEN, SHIFT, SQUEEZE_WINDOW, SQUEEZE_SIZE
                )
                result['symbol'] = symbol
                results_list.append(result)

            if not results_list:
                time.sleep(CHECK_INTERVAL)
                continue

            results_df = pd.DataFrame(results_list)

            # Display table of current signals
            display_cols = ['symbol','trend']
            print(results_df[display_cols].to_string(index=False, float_format='%.5f'))

            # Check for new signals and alert
            for _, row in results_df.iterrows():
                symbol = row['symbol']
                trend = row['trend']


            # Log to file
            #log_signals_to_file(results_df)

            time.sleep(CHECK_INTERVAL)

        except KeyboardInterrupt:
            print("\nStrategy stopped by user.")
            break
        except Exception as e:
            print(f"Error: {e}")
            time.sleep(CHECK_INTERVAL)

    mt5.shutdown()
    print("MT5 connection closed.")


if __name__ == "__main__":
    main()