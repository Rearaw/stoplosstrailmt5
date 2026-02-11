import numpy as np
import pandas as pd
from typing import Literal, Optional, Dict, List
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

def smma_crossover_strategy(
    df: pd.DataFrame,
    short_len: int,
    long_len: int,
    squeeze_window: int,
    squeeze_size: float
) -> Dict[str, any]:
    """Core logic: return signal and metadata for one symbol."""
    required = max(long_len, short_len, squeeze_window + 5)
    if len(df) < required:
        return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan}

    close = df['close']

    # Calculate SMMA
    short_smma = smma(close, short_len)
    long_smma = smma(close, long_len)

    # Get recent data points for convergence analysis
    lookback = 10  # Increased lookback for better trend analysis
    if len(short_smma) < lookback+ 2:
        return {"signal": "none", "short_smma": np.nan, "long_smma": np.nan, "distance": np.nan}

    # Get recent segments of both SMAs
    recent_short = short_smma.iloc[-(lookback):].values
    recent_long = long_smma.iloc[-(lookback):].values
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

    return {
        "trend": trend
    }
def triple_smma_stateful_strategy(
    df: pd.DataFrame,
    length: int = 70,
    use_retests: bool = True,
    retest_depth: float = 0.1
) -> pd.DataFrame:
    """
    Stateful adaptation of the Pine Script SMMA zone strategy.
    Adds columns for SMMA values, bias, entries, and simulated position.
    Returns the enhanced DataFrame for backtesting/analysis.
    """
    df = df.copy()#.reset_index(drop=True)  # Ensure contiguous integer index
    
    # Calculate SMMAs
    df['smma_high']  = smma(df['high'], length)
    df['smma_low']   = smma(df['low'], length)
    df['smma_close'] = smma(df['close'], length)

    df["is_bullish"] = df['close']>df["open"]
    df['is_bearish'] = df['close']<df["open"]
    # Bias: persistent directional state
    above_zone = df['close'] > df['smma_high']
    below_zone = df['close'] < df['smma_low']
    
    bias = np.zeros(len(df))
    for i in range(1, len(df)):
        if above_zone.iloc[i]:
            bias[i] = 1 # bullish bias
        elif below_zone.iloc[i]:
            bias[i] = -1 # bearish bias
        else:
            bias[i] = bias[i - 1]
    df['bias'] = bias
    
    # Breakout detection (crossover/crossunder)
    long_breakout  = (df['close'] > df['smma_high']) & (df['close'].shift(1) <= df['smma_high'].shift(1))
    short_breakout = (df['close'] < df['smma_low'])  & (df['close'].shift(1) >= df['smma_low'].shift(1))
    
    # Retest zone depth (absolute price units)
    zone_width = df['smma_high'] - df['smma_low']
    retest_zone = zone_width * (retest_depth / 100)
    
    # Retest entries (gated by bias)
    long_retest = use_retests & (
        (df['bias'] == 1) &
        (df['low'] <= df['smma_low'] + retest_zone) &
        (df['close'] > df['smma_high'])
    )

    short_retest = use_retests & (
        (df['bias'] == -1) &
        (df['high'] >= df['smma_high'] - retest_zone) &
        (df['close'] < df['smma_low'])
    )
    
    
    # Combined entry signals
    long_entry  = long_breakout | (long_retest & use_retests)
    short_entry = short_breakout | (short_retest & use_retests)
    df['long_entry']  = long_entry & df["is_bullish"]
    df['short_entry'] = short_entry & df["is_bearish"]
    
    #df['long_entry']  = long_entry
    #df['short_entry'] = short_entry
    
    # Position simulation (1 = long, -1 = short, 0 = flat)
    # Reverses on opposite entry; ignores repeated same-direction entry
    position = np.zeros(len(df))
    current_pos = 0
    for i in range(len(df)):
        if long_entry.iloc[i]:
            current_pos = 1
        elif short_entry.iloc[i]:
            current_pos = -1
        position[i] = current_pos
    df['position'] = position
    
    # Optional: trade direction change for signaling
   # df['trade_signal'] = df['position'].diff()  # +2 = flat→long, -2 = flat→short, etc.
    
    return df
