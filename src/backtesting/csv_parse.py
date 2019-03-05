"""
Take a CSV with candlestick data and convert it to a standard format.
Standard format of columns:
    t       pandas datetime?
    ob      Open Bid
    oa      Open Ask
    hb      High Bid
    ha      High Ask
    lb      Low Bid
    la      Low Ask
    cb      Close Bid
    ca      Close Ask
    v       Volume

https://www.epochconverter.com/   microseconds to current date


"""

from   datetime import datetime
import pandas as pd
import os

def pi(path, start, end):
    """ For CSV files from Pi Trading.
    Only one OHLC, so duplicate prices to get bid/ask.
    Spread will always be 0.
    Input:
        path:       string
        start, end: datetime
    Returns: DF with standard columns (see above)
    """
    print('    Reading CSV ({}) from {} to {}'.format(path, start, end))
    # Pull one row every x rows and see if it's after start or end.
    # Read the chunks within those bounds, then trim head and tail exactly.
    cols = ["Date","Time","Open","High","Low","Close","Volume"]
    reader      = pd.read_csv(path, dtype='str', iterator=True)
    chunk_size  = 1000
    i = 0
    start_i = None
    end_i = None
    df_row = reader.get_chunk(chunk_size)
    dt = datetime.strptime( df_row.iat[0,0] + df_row.iat[0,1], '%m/%d/%Y%H%M' )
    while dt < end:
        try: 
            #print('.', end='', flush=True)
            if not start_i and dt > start: # passed start
                start_i = i
            i += 1
            df_row = reader.get_chunk(chunk_size)
            dt = datetime.strptime( df_row.iat[0,0] + df_row.iat[0,1], '%m/%d/%Y%H%M' )
        except StopIteration:
            break
    end_i = i
    if not start_i: #
        start_i = i-1
    elif start_i <= 0: # should never happen
        raise Exception
    skip_rows = start_i * chunk_size
    if start_i == 0: skip_rows += 1 # pidata CSV has header row
    ret = pd.read_csv(path, header=0, names=cols, dtype='str', skiprows=skip_rows,
        nrows=((end_i - start_i) * chunk_size) )
    ret['t']    = pd.to_datetime(ret.Date.str.cat(ret.Time), format='%m/%d/%Y%H%M')
    #ret.set_index(keys='t', drop=False, inplace=True) # use time as index
    ret['ob']   = ret.Open.astype('float')
    ret['oa']   = ret.Open.astype('float')
    ret['hb']   = ret.High.astype('float')
    ret['ha']   = ret.High.astype('float')
    ret['lb']   = ret.Low.astype('float')
    ret['la']   = ret.Low.astype('float')
    ret['cb']   = ret.Close.astype('float')
    ret['ca']   = ret.Close.astype('float')
    ret['v']    = ret.Volume.astype('int')
    ret = ret.drop(cols, axis=1)
    # trim start & end dates - TODO trim during inital load
    ret = ret.loc[ret['t'] > start]
    ret = ret.loc[ret['t'] < end]
    print('    Finished reading CSV')
    if len(ret) < 1:
        print('    ERROR: DF is empty after trimming for path ' + path + '\n' +
            '        from ' + str(start) + '\n' +
            '        to   ' + str(end) + '\n' +
            '\n     Is the date period within the CSV?' )
        raise Exception
    return ret


def five_second(path, start, end):
    """
    Input:
        path:       string
        start, end: datetime
    Returns: DF with standard columns (see above)
    """
    print('    Beginning coarse search in 5s CSV ({}) from {} to {}'.format(path, start, end))
    cols        = ['time_micro', 'open_bid', 'open_ask', 'high_bid', 'high_ask', 'low_bid', 'low_ask', 'close_bid', 'close_ask', 'vol']
    reader      = pd.read_csv(path, dtype='str', iterator=True)
    chunk_size  = 10000
    i           = 0
    start_i     = None
    end_i       = None
    df_row      = reader.get_chunk(chunk_size)
    #dt          = datetime.strptime( df_row.iat[0,0] + df_row.iat[0,1], '%m/%d/%Y%H%M' )
    dt          = pd.Timestamp.utcfromtimestamp( int(int(df_row.iat[0,0])/1000000) )
    while dt < end:
        try: 
            if not start_i and dt > start: # passed start
                start_i = i
            i += 1
            df_row = reader.get_chunk(chunk_size)
            #dt = datetime.strptime( df_row.iat[0,0] + df_row.iat[0,1], '%m/%d/%Y%H%M' )
            dt = pd.Timestamp.utcfromtimestamp( int(int(df_row.iat[0,0]) / 1000000) )
        except StopIteration:
            break
    end_i = i
    if not start_i: #
        start_i = i-1
    elif start_i <= 0: # should never happen
        raise Exception
    skip_rows = start_i * chunk_size
    if start_i == 0: skip_rows += 1 # pidata CSV has header row
    ret = pd.read_csv(path, header=0, names=cols, dtype='str', skiprows=skip_rows,
        nrows=((end_i - start_i) * chunk_size) )
    ret['t']    = pd.to_numeric(ret.time_micro).floordiv(1000000).map(pd.Timestamp.utcfromtimestamp, na_action='ignore')
    ret['ob']   = ret.open_bid.astype('float')
    ret['oa']   = ret.open_ask.astype('float')
    ret['hb']   = ret.high_bid.astype('float')
    ret['ha']   = ret.high_ask.astype('float')
    ret['lb']   = ret.low_bid.astype('float')
    ret['la']   = ret.low_ask.astype('float')
    ret['cb']   = ret.close_bid.astype('float')
    ret['ca']   = ret.close_ask.astype('float')
    ret['v']    = ret.vol.astype('int')
    ret         = ret.drop(cols, axis=1)

    # trim start & end dates
    ret = ret.loc[ret['t'] > start]
    ret = ret.loc[ret['t'] < end]
    print('    Finished reading CSV')
    return ret
