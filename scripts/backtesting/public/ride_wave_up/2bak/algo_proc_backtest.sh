#!/usr/bin/bash

# This prints out instances of a certain pattern

# validate input arguments
if [[ $# -ne 3 ]]; then
    printf "%s\n" "bash $0 <mysql username> <mysql pw> <table name>"
    exit 1
fi

u=$1
pw=$2
table_name=$3 

query="
delimiter //
DROP PROCEDURE IF EXISTS algo.backtest;
CREATE PROCEDURE algo.backtest
(
    IN in_start_date            DATE,
    IN in_num_trades            INT,                            
    IN in_commission            DECIMAL(12,10),                 -- no @
    IN in_tax_factor            DECIMAL(3,2),                   -- e.g. 0.75
    IN in_principal             DECIMAL(10,2),
    IN in_stop_amt              DECIMAL(10,2),
    IN in_wave_threshold_open_to_low    DECIMAL(3,2),           -- e.g. 0.1 
    IN in_wave_threshold_open_to_close  DECIMAL(3,2)            -- e.g. 0.05 
)
main_proc: BEGIN
    -- field variables for fetching
    DECLARE cur_date            DATE;
    DECLARE cur_time            TIME;
    DECLARE cur_open            DECIMAL(11,4);
    DECLARE cur_high            DECIMAL(11,4);
    DECLARE cur_low             DECIMAL(11,4);
    DECLARE cur_close           DECIMAL(11,4);
    -- other variables
    DECLARE balance             DECIMAL(11,4)   DEFAULT 0;
    DECLARE open_1              DECIMAL(11,4)   DEFAULT 0;
    DECLARE open_2              DECIMAL(11,4)   DEFAULT 0;
    DECLARE open_3              DECIMAL(11,4)   DEFAULT 0;
    DECLARE cur_n               INT             DEFAULT 1;
    DECLARE yesterday           DATE            DEFAULT NULL;   --
    DECLARE num_trades_done     INT             DEFAULT 0;      -- no @
    DECLARE buy_price           DECIMAL(11,4)   DEFAULT -1;
    DECLARE first_buy_date      DATE            DEFAULT NULL;
    DECLARE first_buy_time      TIME            DEFAULT NULL;
    DECLARE buy_date            DATE            DEFAULT NULL;
    DECLARE buy_time            TIME            DEFAULT NULL;
    DECLARE sell_price          DECIMAL(11,4)   DEFAULT -1;
    DECLARE num_shares          INT             DEFAULT 0;
    DECLARE max_price_so_far    DECIMAL(11,4)   DEFAULT -1;
    DECLARE fetch_done          BOOL            DEFAULT FALSE;
    DECLARE gross_profit        DECIMAL(10,2)   DEFAULT 0;
    DECLARE commission_total    DECIMAL(20,10)  DEFAULT 0;
    -- cursor
    DECLARE curs CURSOR FOR SELECT date, time, open, high, low, close
        FROM $table_name
        WHERE date >= in_start_date
        ORDER BY date ASC, time ASC;
    -- handler
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET fetch_done = TRUE;

    OPEN curs;

    SET balance = in_principal;

    -- fetch first row
    FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
    IF fetch_done THEN
        SELECT 'WARNING: No first row';
        LEAVE main_proc;
    END IF;
    SET first_buy_date = cur_date;
    SET first_buy_time = cur_time;

    loop_a: LOOP
        -- find entry point
        loop_d: LOOP
            -- Keep track of last n open prices
            -- If they are rising, buy in
            IF cur_n = 1 THEN
                IF (cur_open - cur_low) < in_wave_threshold_open_to_low
                    AND (cur_high - cur_close) <= 0.01
                    AND (cur_close - cur_open) >= 0
                THEN
                    SET open_1 = cur_open;
                    SET cur_n = 2;
                END IF;
            ELSEIF cur_n = 2 THEN
                IF (cur_open - cur_low) < in_wave_threshold_open_to_low
                    AND (cur_high - cur_close) <= 0.01 -- zero is borderline for decreasing entry points
                    -- changing open-->close from 0 to 0.10 goes from daily enter to never entering
                    AND (cur_close - cur_open) >= in_wave_threshold_open_to_close
                    AND (cur_open - open_1) > 0
                THEN
                    -- position can be entered
                    LEAVE loop_d;
                ELSE
                    SET cur_n = 1;
                END IF;
            END IF;
            -- don't buy too late in the day
            IF cur_time > '15:30:00' THEN
                -- Wait until next day
                loop_e: LOOP
                    FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
                    IF fetch_done THEN
                        SELECT 'No more data (4)';
                        LEAVE loop_a;
                    END IF;
                    IF DATEDIFF(cur_date, yesterday) >= 1 THEN
                        LEAVE loop_e;
                    END IF;
                END LOOP;
            END IF;
            -- fetch next row
            FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
            IF fetch_done THEN
                SELECT 'No more data (3)';
                LEAVE loop_a;
            END IF;
        END LOOP;

        -- fetch next row, which will be entered
        FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
        IF fetch_done THEN
            SELECT 'No more data (3)';
            LEAVE loop_a;
        END IF;

        -- enter position
        SET buy_price = cur_open;
        SET buy_date = cur_date;
        SET buy_time = cur_time;
        SET max_price_so_far = buy_price;
        SET num_shares = (balance / buy_price) - 1; -- TODO: improve this approximation
        IF num_shares < 0 THEN
            SET num_shares = 0;
        END IF;
        SET gross_profit = gross_profit - (buy_price * num_shares);
        SET balance = balance - (buy_price * num_shares);
        SET balance = balance - in_commission;
        -- SELECT CONCAT('BUY  ', num_shares, ' ${table_name} @ ', buy_price, ' on ', cur_date, ' ', cur_time);

        -- loop until position exited
        loop_b: LOOP
            -- trailing stop
            IF  (max_price_so_far - cur_open) >= in_stop_amt THEN
                SET sell_price = cur_open;
                -- SELECT CONCAT('SELL ', num_shares, ' ${table_name} @ ', sell_price, ' on ', cur_date, ' ', cur_time);
                -- SELECT CONCAT('    $', ((sell_price - buy_price) * num_shares), ' over ',
                --    DATEDIFF(cur_date, buy_date), ' day(s) and ', TIMEDIFF(cur_time, buy_time));
                SET gross_profit = gross_profit + (sell_price * num_shares);
                SET balance = balance + (num_shares * sell_price);
                SET balance = balance - in_commission;
                SET yesterday = cur_date;
                LEAVE loop_b;
            END IF;
            IF (max_price_so_far - cur_low) >= in_stop_amt THEN
                SET sell_price = cur_low;
                -- SELECT CONCAT('SELL ', num_shares, ' ${table_name} @ ', sell_price, ' on ', cur_date, ' ', cur_time);
                -- SELECT CONCAT('    $', ((sell_price - buy_price) * num_shares), ' over ',
                --    DATEDIFF(cur_date, buy_date), ' day(s) and ', TIMEDIFF(cur_time, buy_time));
                SET gross_profit = gross_profit + (sell_price * num_shares);
                SET balance = balance + (num_shares * sell_price);
                SET balance = balance - in_commission;
                SET yesterday = cur_date;
                LEAVE loop_b;
            END IF;
            -- Don't know if the high happens before the low,
            -- but we do know that the high happens before (or on) the close.
            -- So record the max after the open and low, but before the close.
            SET max_price_so_far = cur_high;
            IF (max_price_so_far - cur_close) >= in_stop_amt THEN
                SET sell_price = cur_close;
                -- SELECT CONCAT('SELL ', num_shares, ' ${table_name} @ ', sell_price, ' on ', cur_date, ' ', cur_time);
                -- SELECT CONCAT('    $', ((sell_price - buy_price) * num_shares), ' over ',
                --    DATEDIFF(cur_date, buy_date), ' day(s) and ', TIMEDIFF(cur_time, buy_time));
                SET gross_profit = gross_profit + (sell_price * num_shares);
                SET balance = balance + (num_shares * sell_price);
                SET balance = balance - in_commission;
                SET yesterday = cur_date;
                -- IF ABS((sell_price - buy_price)*num_shares) = 0 THEN
                --     SELECT cur_date, ' ', cur_time, ' ', cur_open, ' ', cur_high, ' ', cur_low, ' ', cur_close;
                -- END IF;
                LEAVE loop_b;
            END IF;
            -- Fetch next row
            FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
            IF fetch_done THEN
                SELECT 'No more data (1)';
                SELECT CONCAT('Ended (while seeking exit) at ', cur_date);
                LEAVE loop_a;
            END IF;
        END LOOP;

        -- Any money left?
        IF balance <= in_commission THEN
            SELECT 'ABORT: Principal used up.';
            LEAVE loop_a;
        END IF;

        -- tally trades
        SET num_trades_done = num_trades_done + 1;
        IF num_trades_done >= in_num_trades THEN
            LEAVE loop_a;
        END IF;

        -- Wait until next day
        loop_c: LOOP
            FETCH curs INTO cur_date, cur_time, cur_open, cur_high, cur_low, cur_close;
            IF fetch_done THEN
                SELECT 'No more data (2)';
                LEAVE loop_a;
            END IF;
            IF DATEDIFF(cur_date, yesterday) >= 1 THEN
                LEAVE loop_c;
            END IF;
        END LOOP;

    END LOOP;

    -- Report
    SELECT '';
    SELECT CONCAT('Traded from ', first_buy_date, ' ', first_buy_time, ' to ', cur_date, ' ', cur_time);
    SELECT CONCAT('Trading period: ', DATEDIFF(cur_date, first_buy_date), ' days, ', TIMEDIFF(cur_time, first_buy_time) );
    SELECT CONCAT('Completed ', num_trades_done, ' round trips.');
    SELECT CONCAT('Principal: $', ROUND(in_principal, 2) );
    SELECT CONCAT('Wave threshold - open to low: ', in_wave_threshold_open_to_low);
    SELECT CONCAT('Trailing stop amount: ', in_stop_amt);
    SELECT CONCAT('Each Commission: $', ROUND(in_commission, 2) );
    SET commission_total = (in_commission * num_trades_done * 2);
    -- total commission
    SELECT CONCAT('Total Commission: $', ROUND(commission_total, 2) );
    -- gross profit
    SELECT CONCAT('Gross Profit: $', ROUND(gross_profit, 2) );
    -- take out income tax
    SELECT CONCAT('tax factor = ', in_tax_factor);
    SET balance = balance - ( gross_profit * (1 -in_tax_factor) );
    -- final balance
    SELECT CONCAT('Final Balance (Principal & P/L & Commission & Tax): $', ROUND(balance, 2) );
END
"
mysql -u$u -p$pw algo -e "${query}"