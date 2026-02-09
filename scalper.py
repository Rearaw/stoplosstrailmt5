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
LOOKBACK_BARS   = 50
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
def detect_candlestick_patterns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Detect candlestick patterns using TA-Lib and group them by complexity.
    
    Parameters:
    df (pd.DataFrame): DataFrame with 'open', 'high', 'low', 'close' columns (case-insensitive)
    
    Returns:
    pd.DataFrame: Original DataFrame with three new columns:
        - 'single_candle_patterns': comma-separated bullish/bearish single patterns
        - 'two_candle_patterns': comma-separated bullish/bearish two-candle patterns
        - 'three_plus_candle_patterns': comma-separated bullish/bearish three+ patterns
    """
    df = df.copy()
    
    # Normalize column names to lowercase
    df.columns = df.columns.str.lower()
    
    # Validate required columns
    required_cols = {'open', 'high', 'low', 'close'}
    if not required_cols.issubset(df.columns):
        raise ValueError(f"DataFrame must contain columns: {required_cols}")
    
    # Extract OHLC data
    open_prices = df['open'].values.astype(float)
    high_prices = df['high'].values.astype(float)
    low_prices = df['low'].values.astype(float)
    close_prices = df['close'].values.astype(float)
    
    # Pattern groupings
    single_candle = {
        'CDLBELTHOLD': 'Belt Hold',
        'CDLCLOSINGMARUBOZU': 'Closing Marubozu',
        'CDLDOJI': 'Doji',
        'CDLDRAGONFLYDOJI': 'Dragonfly Doji',
        'CDLGRAVESTONEDOJI': 'Gravestone Doji',
        'CDLHAMMER': 'Hammer',
        'CDLHANGINGMAN': 'Hanging Man',
        'CDLINVERTEDHAMMER': 'Inverted Hammer',
        'CDLLONGLEGGEDDOJI': 'Long Legged Doji',
        'CDLLONGLINE': 'Long Line',
        'CDLMARUBOZU': 'Marubozu',
        'CDLRICKSHAWMAN': 'Rickshaw Man',
        'CDLSHOOTINGSTAR': 'Shooting Star',
        'CDLSPINNINGTOP': 'Spinning Top',
        'CDLTAKURI': 'Takuri',
        'CDLHIGHWAVE': 'High Wave',
        'CDLSHORTLINE': 'Short Line',
        'CDLSTALLEDPATTERN': 'Stalled Pattern',
    }
    
    two_candle = {
        'CDLCOUNTERATTACK': 'Counterattack',
        'CDLDARKCLOUDCOVER': 'Dark Cloud Cover',
        'CDLENGULFING': 'Engulfing',
        'CDLGAPSIDESIDEWHITE': 'Gap Side-by-Side White',
        'CDLHARAMI': 'Harami',
        'CDLHARAMICROSS': 'Harami Cross',
        'CDLHOMINGPIGEON': 'Homing Pigeon',
        'CDLINNECK': 'In Neck',
        'CDLONNECK': 'On Neck',
        'CDLPIERCING': 'Piercing',
        'CDLSEPARATINGLINES': 'Separating Lines',
        'CDLTASUKIGAP': 'Tasuki Gap',
        'CDLMATCHINGLOW': 'Matching Low',
        'CDLKICKING': 'Kicking',
    }
    
    three_plus_candle = {
        'CDL2CROWS': '2 Crows',
        'CDL3BLACKCROWS': '3 Black Crows',
        'CDL3INSIDE': '3 Inside',
        'CDL3LINESTRIKE': '3 Line Strike',
        'CDL3OUTSIDE': '3 Outside',
        'CDL3STARSINSOUTH': '3 Stars in South',
        'CDL3WHITESOLDIERS': '3 White Soldiers',
        'CDLABANDONEDBABY': 'Abandoned Baby',
        'CDLADVANCEBLOCK': 'Advance Block',
        'CDLBREAKAWAY': 'Breakaway',
        'CDLCONCEALBABYSWALL': 'Concealing Baby Swallow',
        'CDLDOJISTAR': 'Doji Star',
        'CDLEVENINGDOJISTAR': 'Evening Doji Star',
        'CDLEVENINGSTAR': 'Evening Star',
        'CDLHIKKAKE': 'Hikkake',
        'CDLHIKKAKEMOD': 'Hikkake Modified',
        'CDLIDENTICAL3CROWS': 'Identical 3 Crows',
        'CDLLADDERBOTTOM': 'Ladder Bottom',
        'CDLMATHOLD': 'Mat Hold',
        'CDLMORNINGDOJISTAR': 'Morning Doji Star',
        'CDLMORNINGSTAR': 'Morning Star',
        'CDLRISEFALL3METHODS': 'Rise/Fall 3 Methods',
        'CDLSTICKSANDWICH': 'Stick Sandwich',
        'CDLTRISTAR': 'Tristar',
        'CDLTHRUSTING': 'Thrusting',
        'CDLUNIQUE3RIVER': 'Unique 3 River',
        'CDLUPSIDEGAP2CROWS': 'Upside Gap 2 Crows',
        'CDLXSIDEGAP3METHODS': 'Side Gap 3 Methods',
    }
    
# Initialize collection lists (one list per row)
    single_lists = [[] for _ in range(len(df))]
    two_lists = [[] for _ in range(len(df))]
    three_plus_lists = [[] for _ in range(len(df))]
    
    
    # Process single-candle patterns
    for func_name, display_name in single_candle.items():
        func = getattr(ta, func_name)
        results = func(open_prices, high_prices, low_prices, close_prices)
        for idx, value in enumerate(results):
            if value != 0:
                direction = 'Bullish ' if value > 0 else 'Bearish '
                if display_name in ['Doji', 'Dragonfly Doji', 'Gravestone Doji', 
                                    'Long Legged Doji', 'Spinning Top', 'Rickshaw Man', 
                                    'High Wave', 'Takuri', 'Short Line']:
                    pattern_str = display_name
                else:
                    pattern_str = direction + display_name
                single_lists[idx].append(pattern_str)
    
    # Process two-candle patterns (similar structure)
    for func_name, display_name in two_candle.items():
        func = getattr(ta, func_name)
        results = func(open_prices, high_prices, low_prices, close_prices)
        for idx, value in enumerate(results):
            if value != 0:
                direction = 'Bullish ' if value > 0 else 'Bearish '
                pattern_str = direction + display_name
                two_lists[idx].append(pattern_str)
    
    # Process three-plus-candle patterns (with confirmation handling)
    for func_name, display_name in three_plus_candle.items():
        func = getattr(ta, func_name)
        results = func(open_prices, high_prices, low_prices, close_prices)
        for idx, value in enumerate(results):
            if value != 0:
                confirmation = ' (confirmed)' if abs(value) == 200 else ''
                direction = 'Bullish ' if value > 0 else 'Bearish '
                pattern_str = direction + display_name + confirmation
                three_plus_lists[idx].append(pattern_str)
    
    # Assign joined strings to columns (aligns with original index automatically)
    df['single_candle_patterns'] = [', '.join(patterns) if patterns else '' for patterns in single_lists]
    df['two_candle_patterns'] = [', '.join(patterns) if patterns else '' for patterns in two_lists]
    df['three_plus_candle_patterns'] = [', '.join(patterns) if patterns else '' for patterns in three_plus_lists]
    
    return df


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
    results=detect_candlestick_patterns(df_ohlcv)
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