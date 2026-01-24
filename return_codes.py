import json
return_codes = {
  "10006": {
    "constant": "TRADE_RETCODE_REJECT",
    "description": "Request rejected"
  },
  "10007": {
    "constant": "TRADE_RETCODE_CANCEL",
    "description": "Request canceled by trader"
  },
  "10008": {
    "constant": "TRADE_RETCODE_PLACED",
    "description": "Order placed"
  },
  "10009": {
    "constant": "TRADE_RETCODE_DONE",
    "description": "Request completed"
  },
  "10010": {
    "constant": "TRADE_RETCODE_DONE_PARTIAL",
    "description": "Only part of the request was completed"
  },
  "10011": {
    "constant": "TRADE_RETCODE_ERROR",
    "description": "Request processing error"
  },
  "10012": {
    "constant": "TRADE_RETCODE_TIMEOUT",
    "description": "Request canceled by timeout"
  },
  "10013": {
    "constant": "TRADE_RETCODE_INVALID",
    "description": "Invalid request"
  },
  "10014": {
    "constant": "TRADE_RETCODE_INVALID_VOLUME",
    "description": "Invalid volume in the request"
  },
  "10015": {
    "constant": "TRADE_RETCODE_INVALID_PRICE",
    "description": "Invalid price in the request"
  },
  "10016": {
    "constant": "TRADE_RETCODE_INVALID_STOPS",
    "description": "Invalid stops in the request"
  },
  "10017": {
    "constant": "TRADE_RETCODE_TRADE_DISABLED",
    "description": "Trade is disabled"
  },
  "10018": {
    "constant": "TRADE_RETCODE_MARKET_CLOSED",
    "description": "Market is closed"
  },
  "10019": {
    "constant": "TRADE_RETCODE_NO_MONEY",
    "description": "There is not enough money to complete the request"
  },
  "10020": {
    "constant": "TRADE_RETCODE_PRICE_CHANGED",
    "description": "Prices changed"
  },
  "10021": {
    "constant": "TRADE_RETCODE_PRICE_OFF",
    "description": "There are no quotes to process the request"
  },
  "10022": {
    "constant": "TRADE_RETCODE_INVALID_EXPIRATION",
    "description": "Invalid order expiration date in the request"
  },
  "10023": {
    "constant": "TRADE_RETCODE_ORDER_CHANGED",
    "description": "Order state changed"
  },
  "10024": {
    "constant": "TRADE_RETCODE_TOO_MANY_REQUESTS",
    "description": "Too frequent requests"
  },
  "10025": {
    "constant": "TRADE_RETCODE_NO_CHANGES",
    "description": "No changes in request"
  },
  "10026": {
    "constant": "TRADE_RETCODE_SERVER_DISABLES_AT",
    "description": "Autotrading disabled by server"
  },
  "10027": {
    "constant": "TRADE_RETCODE_CLIENT_DISABLES_AT",
    "description": "Autotrading disabled by client terminal"
  },
  "10028": {
    "constant": "TRADE_RETCODE_LOCKED",
    "description": "Request locked for processing"
  },
  "10029": {
    "constant": "TRADE_RETCODE_FROZEN",
    "description": "Order or position frozen"
  },
  "10030": {
    "constant": "TRADE_RETCODE_INVALID_FILL",
    "description": "Invalid order filling type"
  },
  "10031": {
    "constant": "TRADE_RETCODE_CONNECTION",
    "description": "No connection with the trade server"
  },
  "10032": {
    "constant": "TRADE_RETCODE_ONLY_REAL",
    "description": "Operation is allowed only for live accounts"
  },
  "10033": {
    "constant": "TRADE_RETCODE_LIMIT_ORDERS",
    "description": "The number of pending orders has reached the limit"
  },
  "10034": {
    "constant": "TRADE_RETCODE_LIMIT_VOLUME",
    "description": "The volume of orders and positions for the symbol has reached the limit"
  },
  "10035": {
    "constant": "TRADE_RETCODE_INVALID_ORDER",
    "description": "Incorrect or prohibited order type"
  },
  "10036": {
    "constant": "TRADE_RETCODE_POSITION_CLOSED",
    "description": "Position with the specified POSITION_IDENTIFIER has already been closed"
  },
  "10038": {
    "constant": "TRADE_RETCODE_INVALID_CLOSE_VOLUME",
    "description": "A close volume exceeds the current position volume"
  },
  "10039": {
    "constant": "TRADE_RETCODE_CLOSE_ORDER_EXIST",
    "description": "A close order already exists for a specified position. This may happen when working in the hedging system:\nwhen attempting to close a position with an opposite one, while close orders for the position already exist\r\nwhen attempting to fully or partially close a position if the total volume of the already present close orders and the newly placed one exceeds the current position volume"
  },
  "10040": {
    "constant": "TRADE_RETCODE_LIMIT_POSITIONS",
    "description": "The number of open positions simultaneously present on an account can be limited by the server settings. After a limit is reached, the server returns the TRADE_RETCODE_LIMIT_POSITIONS error when attempting to place an order. The limitation operates differently depending on the position accounting type:\nNetting — number of open positions is considered. When a limit is reached, the platform does not let placing new orders whose execution may increase the number of open positions. In fact, the platform allows placing orders only for the symbols that already have open positions. The current pending orders are not considered since their execution may lead to changes in the current positions but it cannot increase their number.\r\nHedging — pending orders are considered together with open positions, since a pending order activation always leads to opening a new position. When a limit is reached, the platform does not allow placing both new market orders for opening positions and pending orders."
  },
  "10041": {
    "constant": "TRADE_RETCODE_REJECT_CANCEL",
    "description": "The pending order activation request is rejected, the order is canceled"
  },
  "10042": {
    "constant": "TRADE_RETCODE_LONG_ONLY",
    "description": "The request is rejected, because the \"Only long positions are allowed\" rule is set for the symbol (POSITION_TYPE_BUY)"
  },
  "10043": {
    "constant": "TRADE_RETCODE_SHORT_ONLY",
    "description": "The request is rejected, because the \"Only short positions are allowed\" rule is set for the symbol (POSITION_TYPE_SELL)"
  },
  "10044": {
    "constant": "TRADE_RETCODE_CLOSE_ONLY",
    "description": "The request is rejected, because the \"Only position closing is allowed\" rule is set for the symbol"
  },
  "10045": {
    "constant": "TRADE_RETCODE_FIFO_CLOSE",
    "description": "The request is rejected, because \"Position closing is allowed only by FIFO rule\" flag is set for the trading account (ACCOUNT_FIFO_CLOSE=true)"
  },
  "10046": {
    "constant": "TRADE_RETCODE_HEDGE_PROHIBITED",
    "description": "The request is rejected, because the \"Opposite positions on a single symbol are disabled\" rule is set for the trading account. For example, if the account has a Buy position, then a user cannot open a Sell position or place a pending sell order. The rule is only applied to accounts with hedging accounting system (ACCOUNT_MARGIN_MODE=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)."
  }
}

def retcodedes(code: int) -> str:
    """
    Get the description of a return code from trade_retcodes.json
    
    Args:
        code (int): The return code to look up
        
    Returns:
        str: The description of the return code, or 'Unknown return code' if not found
    """
    try:
        # with open('trade_retcodes.json', 'r') as file:
        #     return_codes = json.load(file)
            
        code_str = str(code)
        return return_codes.get(code_str, {}).get('description', 'Unknown return code')
        
    except FileNotFoundError:
        return "Error: trade_retcodes.json file not found"
    except json.JSONDecodeError:
        return "Error: Invalid JSON format in trade_retcodes.json"