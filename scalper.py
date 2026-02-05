import MetaTrader5 as mt5
import pandas as pd
import numpy as np
#import time
#import threading
from typing import Dict, List, Tuple, Literal, Optional
from termcolor import colored
import pandas_ta as pta
import account_manager as am #get open positions
import logging
import mplfinance as mpf
from scipy.signal import find_peaks
from scipy.stats import linregress
from strategies.smma_mt5_strategy import smma
#import pattern_recognition as pr
import talib as ta
import colorama
colorama.init()
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)
# ================= CONFIGURATION =================
SYMBOLS          = ["XAUUSDm"]
TIMEFRAME       = mt5.TIMEFRAME_M15
LOT_SIZE        = 0.01
LOOKBACK_BARS   = 500
def peak_detection(close: pd.Series, distance: int = 10, prominence: float = 0.01) -> Tuple[np.ndarray, np.ndarray]:
    """
    Detects peaks and troughs in a Close price series using scipy.signal.find_peaks.
    
    Parameters
    ----------
    close : pd.Series
        Series of closing prices (indexed, preferably with DatetimeIndex).
    distance : int
        Minimum distance between detected peaks/troughs.
    prominence : float
        Minimum prominence required for a peak/trough to be considered significant.
    
    Returns
    -------
    peaks : np.ndarray
        Indices of detected peaks.
    troughs : np.ndarray
        Indices of detected troughs.
    """
    #close.to_numpy()
    high=close["high"]
    low=close["low"]
    close_array =high.to_numpy()
    low_array=low.to_numpy()
    peaks, _ = find_peaks(close_array, distance=distance, prominence=prominence)
    troughs, _ = find_peaks(-low_array, distance=distance, prominence=prominence)
    return peaks, troughs
if not mt5.initialize():
    print("Failed to initialize MT5.")
    mt5.shutdown()
    exit()
class indicators:
    def __init__(self):
        pass
    def smma(self, df: pd.DataFrame) -> pd.DataFrame:
        close = df['close']
        df["long_ma"] =smma(close, length=100)#find sell signals when on top of short_ma
        df["medium_ma"] =smma(close, length=50)
        df["short_ma"] =smma(close, length=10)#find buy signals if on top of both long_ma
        return df
    def RSI(self, df: pd.DataFrame, length: int = 14) -> pd.DataFrame:
        df['RSI'] = pta.rsi(df['close'], length=length)
        return df
    def VWAP(self, df: pd.DataFrame) -> pd.DataFrame:
        df["VWAP"]=pta.vwap(df.high, df.low, df.close, df.volume)
        return df
    def BBANDS(self, df: pd.DataFrame, length: int = 20, std_dev: float = 2.50) -> pd.DataFrame:
        bbandu=smma(df['close'], length=length)+ta.STDDEV(df['close'], timeperiod=length, nbdev=std_dev)
        bbandd=smma(df['close'], length=length)-ta.STDDEV(df['close'], timeperiod=length, nbdev=std_dev)
        df['BB_upper'] = bbandu
        #df['BB_middle'] = ta.SMA(df['close'], timeperiod=length, nbdevup=std_dev, nbdevdn=1.4, matype=0)
        df['BB_lower'] = bbandd
        return df
def reversal_patterns(df: pd.DataFrame) -> pd.DataFrame:
    """Detects candlestick reversal patterns using talib"""
    o = df['open'].values
    h = df['high'].values
    l = df['low'].values
    c = df['close'].values
    
    df['hammer'] = ta.CDLHAMMER(o, h, l, c)
    df['inverted_hammer'] = ta.CDLINVERTEDHAMMER(o, h, l, c)
    df['engulfing'] = ta.CDLENGULFING(o, h, l, c)
    df['morning_star'] = ta.CDLMORNINGSTAR(o, h, l, c)
    df['evening_star'] = ta.CDLEVENINGSTAR(o, h, l, c)
    df['harami'] = ta.CDLHARAMI(o, h, l, c)
    
    return df
def continuation_patterns(df: pd.DataFrame) -> pd.DataFrame:
    pass
def fetch_ohlcv(symbol, timeframe, count=100) -> Optional[pd.DataFrame]:
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None:
        print(colored("Failed to fetch data.", 'red'))
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df[['time', 'open', 'high', 'low', 'close', 'tick_volume']]
    df=df.rename(columns={"tick_volume": "volume"})
    df.set_index('time', inplace=True)
    return df
def plot_candlestick_with_trends(
    df: pd.DataFrame,
    distance: int = 5,
    prominence: float = 0.01,
    fit_peaks: bool = True,
    fit_troughs: bool = True
):
    """
    Plots a candlestick chart from OHLCV data, marks detected peaks and troughs on Close prices,
    and overlays linear best-fit (regression) lines on the peaks and/or troughs.
    
    Parameters
    ----------
    df : pd.DataFrame
        DataFrame with columns ['Open', 'High', 'Low', 'Close'] (Volume optional/ignored).
        Index should preferably be a DatetimeIndex for proper date labeling.
    distance, prominence : parameters passed to peak_detection.
    fit_peaks / fit_troughs : whether to compute and plot regression lines.
    """
    # Extract Close series and detect extrema
    close = df['close']
    peaks, troughs = peak_detection(df, distance=distance, prominence=prominence)
    
    # Prepare numerical x-axis (integer positions for positioning candlesticks)
    x_pos = np.arange(len(df))
    
    # Linear regression for peaks (resistance trend)
    trend_peaks = None
    if fit_peaks and len(peaks) >= 2:
        slope_p, intercept_p, _, _, _ = linregress(x_pos[peaks], close.iloc[peaks].values)
        trend_peaks = slope_p * x_pos + intercept_p
    
    # Linear regression for troughs (support trend)
    trend_troughs = None
    if fit_troughs and len(troughs) >= 2:
        slope_t, intercept_t, _, _, _ = linregress(x_pos[troughs], close.iloc[troughs].values)
        trend_troughs = slope_t * x_pos + intercept_t
    
    # ────────────────────────────────────────────────
    # Plotting
    # ────────────────────────────────────────────────
    fig, ax = plt.subplots(figsize=(14, 7))
    
    # Draw candlesticks
    for i in x_pos:
        o, h, l, c = df['open'].iloc[i], df['high'].iloc[i], df['low'].iloc[i], df['close'].iloc[i]
        color = 'green' if c >= o else 'red'
        
        # High-Low wick
        ax.plot([i, i], [l, h], color='black', linewidth=1)
        
        # Open-Close body
        body_bottom = min(o, c)
        body_height = abs(o - c)
        ax.add_patch(plt.Rectangle(
            (i - 0.3, body_bottom), 0.6, max(body_height, 0.001),  # tiny height if flat
            facecolor=color, edgecolor='black', linewidth=1, alpha=0.8
        ))

    if len(peaks) > 0:
        ax.plot(x_pos[peaks], close.iloc[peaks], 'v', color='red', markersize=10, label='Peaks')
    if len(troughs) > 0:
        ax.plot(x_pos[troughs], close.iloc[troughs], '^', color='blue', markersize=10, label='Troughs')
    
    # Overlay trend lines
    if trend_peaks is not None:
        ax.plot(x_pos, trend_peaks, '--', color='red', linewidth=2, label='Peak Trend Line')
    if trend_troughs is not None:
        ax.plot(x_pos, trend_troughs, '--', color='blue', linewidth=2, label='Trough Trend Line')
    
    # Axes and labels
    ax.set_ylabel('Price')
    ax.set_title('Candlestick Chart with Detected Peaks/Troughs and Linear Trend Lines')
    ax.grid(True, alpha=0.3)
    ax.legend(loc='upper left')
    
    # X-axis: use dates if available
    if isinstance(df.index, pd.DatetimeIndex):
        step = max(1, len(df) // 15)  # ~15 labels max
        ax.set_xticks(x_pos[::step])
        ax.set_xticklabels(df.index[::step].strftime('%Y-%m-%d'), rotation=45, ha='right')
    else:
        ax.set_xlabel('Index')
    
    ax.set_xlim(-0.5, len(df) - 0.5)
    plt.tight_layout()
    plt.show()

def plot_indicator_with_signals(
    df: pd.DataFrame,) -> None:
    pass
def main(symbols: List[str]):
    for symbol in SYMBOLS:
        print(colored(f"Analyzing {symbol}...", 'cyan'))
        df_ohlcv = fetch_ohlcv(symbol, TIMEFRAME, LOOKBACK_BARS)

    #Open,high,low,close,volume =df["open"],df["high"],df["low"],df["close"],df["tick_volume"]
    #t=pr.find_trend_change_points(high, low)
    #peaks, troughs = peak_detection(close, distance=5, prominence=0.01)
#     #plot_candlestick_with_trends(
#                                     df_ohlcv,
#                                     distance=10,          # adjust based on your timeframe (e.g., higher for daily data)
#                                     prominence=0.5,       # adjust to filter only significant swings
#                                     fit_peaks=True,
#                                     fit_troughs=True
# )
#     #t=reversal_patterns( df_ohlcv)
    indicator = indicators()
    df_ohlcv = indicator.smma(df_ohlcv)
    df_ohlcv = indicator.RSI(df_ohlcv)
    df_ohlcv = indicator.VWAP(df_ohlcv)
    df_ohlcv = indicator.BBANDS(df_ohlcv)
    smma_plot = mpf.make_addplot(df_ohlcv['long_ma'], color='red', linestyle='-')
    sma_plot = mpf.make_addplot(df_ohlcv['short_ma'], color='green', linestyle='-')
    vwap_plot = mpf.make_addplot(df_ohlcv['VWAP'], color='magenta', linestyle='-')
    upper_band = mpf.make_addplot(df_ohlcv['BB_upper'], color='red', linestyle='--')
    #middle_band = mpf.make_addplot(df_ohlcv['BB_middle'], color='orange', linestyle='-')
    lower_band = mpf.make_addplot(df_ohlcv['BB_lower'], color='green', linestyle='--')
    
    
    add_plots = [smma_plot,sma_plot,vwap_plot,upper_band,lower_band]
    mpf.plot(
    df_ohlcv,
    type='candle',
    style='charles',          # Alternatives: 'charles', 'binance', 'blueskies', etc.
    addplot=add_plots,
    volume=True,            # Includes volume panel below price
    title='OHLCV Chart with SMMA, VWAP, and RSI',
    ylabel='Price',
    #panel_ratios=(4, 1, 2), # Price panel largest, volume small, RSI medium
    figsize=(14, 10),
    tight_layout=True
)


if __name__ == "__main__":
    positions=am.get_active_trades()
    if positions is None:
        logger.info(colored(f"(no positions currently open)", 'yellow'))
        main(SYMBOLS)
    elif len(positions.index) <= 3:
        logger.info(colored(f"({len(positions.index)} positions currently open)", 'yellow'))
        main(SYMBOLS)

    else:      
        logger.info(colored("Maximum number of open positions reached. No new trades will be initiated.", 'red'))
        main(SYMBOLS)
    mt5.shutdown()