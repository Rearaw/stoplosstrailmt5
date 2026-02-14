import pandas as pd
from typing import Dict, List, Tuple, Literal, Optional
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
    import pandas as pd
    import talib as ta
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