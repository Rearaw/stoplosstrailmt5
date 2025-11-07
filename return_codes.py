import json

def retcodedes(code: int) -> str:
    """
    Get the description of a return code from trade_retcodes.json
    
    Args:
        code (int): The return code to look up
        
    Returns:
        str: The description of the return code, or 'Unknown return code' if not found
    """
    try:
        with open('trade_retcodes.json', 'r') as file:
            return_codes = json.load(file)
            
        code_str = str(code)
        return return_codes.get(code_str, {}).get('description', 'Unknown return code')
        
    except FileNotFoundError:
        return "Error: trade_retcodes.json file not found"
    except json.JSONDecodeError:
        return "Error: Invalid JSON format in trade_retcodes.json"