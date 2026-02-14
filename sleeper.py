from datetime import datetime
import time
from colorama import Fore, Style, init
init(autoreset=True)

def sleeper(seconds):
    while seconds:
        mins, secs = divmod(seconds, 60)
        timer = f'{mins:02d}:{secs:02d}'
        
        # Different colors based on time remaining
        if seconds > 5:
            color = Fore.GREEN
        elif seconds > 2:
            color = Fore.YELLOW
        else:
            color = Fore.RED
            
        print(f'\r{color}Time remaining: {timer}{Style.RESET_ALL}', end='')
        time.sleep(1)
        seconds -= 1
    
    print(f'\r{Fore.RED}Time remaining: 00:00{Style.RESET_ALL}')
 